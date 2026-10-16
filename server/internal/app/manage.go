package app

import (
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
)

// targetUser resolves the ?user= query parameter: own user by default, any user for admins.
func (a *App) targetUser(w http.ResponseWriter, r *http.Request, p *principal) (string, bool) {
	uid := strings.TrimSpace(r.URL.Query().Get("user"))
	if uid == "" || uid == p.user.ID {
		return p.user.ID, true
	}
	if p.user.Role != "admin" {
		writeErr(w, http.StatusForbidden, "admin_required", "only admins can view other users")
		return "", false
	}
	if _, err := a.getUser(uid); err != nil {
		if errors.Is(err, errNotFound) {
			writeErr(w, http.StatusNotFound, "not_found", "user not found")
		} else {
			writeInternal(w, a, "target user", err)
		}
		return "", false
	}
	return uid, true
}

// ---- devices ----------------------------------------------------------------------------

func (a *App) handleListDevices(w http.ResponseWriter, r *http.Request, p *principal) {
	uid, ok := a.targetUser(w, r, p)
	if !ok {
		return
	}
	devs, err := a.listDevices(uid)
	if err != nil {
		writeInternal(w, a, "list devices", err)
		return
	}
	for i := range devs {
		devs[i].Current = devs[i].ID == p.device.ID
		_ = a.db.QueryRow(`SELECT last_sync_at FROM device_health WHERE device_id=?`, devs[i].ID).Scan(&devs[i].LastSyncAt)
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": devs})
}

// loadManagedDevice loads a device the caller may manage (own user's, or any for admins).
func (a *App) loadManagedDevice(w http.ResponseWriter, r *http.Request, p *principal) (Device, bool) {
	d, err := a.getDevice(r.PathValue("id"))
	if err == nil && d.userID != p.user.ID && p.user.Role != "admin" {
		err = errNotFound // don't reveal other users' devices
	}
	if err != nil {
		if errors.Is(err, errNotFound) {
			writeErr(w, http.StatusNotFound, "not_found", "device not found")
		} else {
			writeInternal(w, a, "load device", err)
		}
		return Device{}, false
	}
	d.Current = d.ID == p.device.ID
	return d, true
}

func (a *App) handlePatchDevice(w http.ResponseWriter, r *http.Request, p *principal) {
	d, ok := a.loadManagedDevice(w, r, p)
	if !ok {
		return
	}
	var req struct {
		Name   *string   `json:"name"`
		Scopes *[]string `json:"scopes"`
	}
	if !decodeJSON(w, r, maxSmallBody, &req) {
		return
	}
	changes := []string{}
	if req.Name != nil {
		name := cleanText(*req.Name, 64)
		if name == "" {
			writeErr(w, http.StatusBadRequest, "invalid_name", "name must not be empty")
			return
		}
		if name != d.Name {
			changes = append(changes, fmt.Sprintf("renamed %q → %q", d.Name, name))
			d.Name = name
		}
	}
	scopesChanged := false
	if req.Scopes != nil {
		s, ok := normalizeScopes(*req.Scopes)
		if !ok {
			writeErr(w, http.StatusBadRequest, "invalid_scopes", "scopes must be read, write and/or secrets")
			return
		}
		if len(s) == 0 {
			writeErr(w, http.StatusBadRequest, "invalid_scopes", "keep at least one scope (revoke the device instead)")
			return
		}
		// A device may only add scopes it holds itself (no self-escalation from a restricted TV).
		for _, sc := range s {
			if !d.has(sc) && !p.device.has(sc) {
				writeErr(w, http.StatusForbidden, "scope_escalation", "you can only grant scopes this device has itself")
				return
			}
		}
		if joinScopes(s) != joinScopes(d.Scopes) {
			changes = append(changes, fmt.Sprintf("scopes %s → %s", joinScopes(d.Scopes), joinScopes(s)))
			d.Scopes = s
			scopesChanged = true
		}
	}
	if len(changes) > 0 {
		if _, err := a.db.Exec(`UPDATE devices SET name = ?, scopes = ? WHERE id = ?`, d.Name, joinScopes(d.Scopes), d.ID); err != nil {
			writeInternal(w, a, "patch device", err)
			return
		}
		if scopesChanged {
			a.hub.notify(d.userID) // long polls re-check their scopes
		}
		a.audit(p.user.ID, p.user.Username, d.ID, "device.update", d.Name+": "+strings.Join(changes, ", "), p.ip)
	}
	writeJSON(w, http.StatusOK, d)
}

func (a *App) handleDeleteDevice(w http.ResponseWriter, r *http.Request, p *principal) {
	d, ok := a.loadManagedDevice(w, r, p)
	if !ok {
		return
	}
	if err := a.deleteDevice(d.ID); err != nil {
		writeInternal(w, a, "delete device", err)
		return
	}
	a.hub.notify(d.userID) // held long polls of the revoked device return 401 right away
	a.audit(p.user.ID, p.user.Username, d.ID, "device.revoke", fmt.Sprintf("revoked %s (%s)", d.Name, d.Platform), p.ip)
	w.WriteHeader(http.StatusNoContent)
}

// ---- users (admin) ---------------------------------------------------------------------

func (a *App) handleListUsers(w http.ResponseWriter, r *http.Request, p *principal) {
	users, err := a.listUsers()
	if err != nil {
		writeInternal(w, a, "list users", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"users": users})
}

func (a *App) handleCreateUser(w http.ResponseWriter, r *http.Request, p *principal) {
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
		Role     string `json:"role"`
		// Optional admin-managed configuration to assign right away (PROTOCOL.md §5).
		Dispatcharr []newUserServer `json:"dispatcharr"`
		Addons      []string        `json:"addons"`
	}
	if !decodeJSON(w, r, maxSmallBody, &req) {
		return
	}
	req.Username = strings.TrimSpace(req.Username)
	if req.Role == "" {
		req.Role = "member"
	}
	if msg := validateUsername(req.Username); msg != "" {
		writeErr(w, http.StatusBadRequest, "invalid_username", msg)
		return
	}
	if msg := validatePassword(req.Password); msg != "" {
		writeErr(w, http.StatusBadRequest, "invalid_password", msg)
		return
	}
	if !validRole(req.Role) {
		writeErr(w, http.StatusBadRequest, "invalid_role", "role must be admin or member")
		return
	}
	if msg, err := a.validateNewUserAssignments(req.Dispatcharr, req.Addons); err != nil {
		writeInternal(w, a, "create user assignments", err)
		return
	} else if msg != "" {
		writeErr(w, http.StatusBadRequest, "invalid_assignment", msg)
		return
	}
	u, err := a.createUser(req.Username, req.Password, req.Role)
	if errors.Is(err, errUsernameTaken) {
		writeErr(w, http.StatusConflict, "username_taken", "that username is taken")
		return
	}
	if err != nil {
		writeInternal(w, a, "create user", err)
		return
	}
	a.audit(p.user.ID, p.user.Username, p.device.ID, "user.create", fmt.Sprintf("created %s (%s)", u.Username, u.Role), p.ip)
	if err := a.applyNewUserAssignments(u.ID, req.Dispatcharr, req.Addons); err != nil {
		writeInternal(w, a, "create user assignments", err)
		return
	}
	if n := len(req.Dispatcharr) + len(req.Addons); n > 0 {
		a.audit(p.user.ID, p.user.Username, p.device.ID, "admin.assign",
			fmt.Sprintf("assigned %d Dispatcharr connection(s) and %d addon(s) to %s", len(req.Dispatcharr), len(req.Addons), u.Username), p.ip)
	}
	writeJSON(w, http.StatusOK, u)
}

func (a *App) handlePatchUser(w http.ResponseWriter, r *http.Request, p *principal) {
	u, err := a.getUser(r.PathValue("id"))
	if errors.Is(err, errNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "user not found")
		return
	}
	if err != nil {
		writeInternal(w, a, "patch user", err)
		return
	}
	var req struct {
		Password *string `json:"password"`
		Role     *string `json:"role"`
		Disabled *bool   `json:"disabled"`
	}
	if !decodeJSON(w, r, maxSmallBody, &req) {
		return
	}
	newRole, newDisabled := u.Role, u.Disabled
	if req.Role != nil {
		if !validRole(*req.Role) {
			writeErr(w, http.StatusBadRequest, "invalid_role", "role must be admin or member")
			return
		}
		newRole = *req.Role
	}
	if req.Disabled != nil {
		newDisabled = *req.Disabled
	}
	if req.Password != nil {
		if msg := validatePassword(*req.Password); msg != "" {
			writeErr(w, http.StatusBadRequest, "invalid_password", msg)
			return
		}
	}
	if u.ID == p.user.ID && newDisabled && !u.Disabled {
		writeErr(w, http.StatusBadRequest, "cannot_disable_self", "you can't disable your own account")
		return
	}
	wasActiveAdmin := u.Role == "admin" && !u.Disabled
	staysActiveAdmin := newRole == "admin" && !newDisabled
	if wasActiveAdmin && !staysActiveAdmin {
		n, err := a.enabledAdminsExcluding(u.ID)
		if err != nil {
			writeInternal(w, a, "admin count", err)
			return
		}
		if n == 0 {
			writeErr(w, http.StatusConflict, "last_admin", "this is the last active admin; promote someone else first")
			return
		}
	}
	if req.Password != nil {
		if err := a.setPassword(u.ID, *req.Password); err != nil {
			writeInternal(w, a, "reset password", err)
			return
		}
		a.audit(p.user.ID, p.user.Username, p.device.ID, "password.reset", "reset password of "+u.Username, p.ip)
	}
	if newRole != u.Role || newDisabled != u.Disabled {
		dis := 0
		if newDisabled {
			dis = 1
		}
		if _, err := a.db.Exec(`UPDATE users SET role = ?, disabled = ? WHERE id = ?`, newRole, dis, u.ID); err != nil {
			writeInternal(w, a, "update user", err)
			return
		}
		if newRole != u.Role {
			a.audit(p.user.ID, p.user.Username, p.device.ID, "user.role", fmt.Sprintf("%s is now %s", u.Username, newRole), p.ip)
		}
		if newDisabled && !u.Disabled {
			n, err := a.deleteUserDevices(u.ID)
			if err != nil {
				writeInternal(w, a, "revoke devices", err)
				return
			}
			a.hub.notify(u.ID)
			a.audit(p.user.ID, p.user.Username, p.device.ID, "user.disable", fmt.Sprintf("disabled %s and revoked %d device(s)", u.Username, n), p.ip)
		} else if !newDisabled && u.Disabled {
			a.audit(p.user.ID, p.user.Username, p.device.ID, "user.enable", "enabled "+u.Username, p.ip)
		}
		u.Role, u.Disabled = newRole, newDisabled
	}
	writeJSON(w, http.StatusOK, u)
}

func (a *App) handleDeleteUser(w http.ResponseWriter, r *http.Request, p *principal) {
	u, err := a.getUser(r.PathValue("id"))
	if errors.Is(err, errNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "user not found")
		return
	}
	if err != nil {
		writeInternal(w, a, "delete user", err)
		return
	}
	if u.ID == p.user.ID {
		writeErr(w, http.StatusBadRequest, "cannot_delete_self", "you can't delete your own account")
		return
	}
	if u.Role == "admin" && !u.Disabled {
		n, err := a.enabledAdminsExcluding(u.ID)
		if err != nil {
			writeInternal(w, a, "admin count", err)
			return
		}
		if n == 0 {
			writeErr(w, http.StatusConflict, "last_admin", "this is the last active admin")
			return
		}
	}
	tx, err := a.db.Begin()
	if err != nil {
		writeInternal(w, a, "delete user", err)
		return
	}
	defer tx.Rollback()
	for _, q := range []string{
		`DELETE FROM records WHERE user_id = ?`,
		`DELETE FROM devices WHERE user_id = ?`,
		`DELETE FROM users WHERE id = ?`,
	} {
		if _, err := tx.Exec(q, u.ID); err != nil {
			writeInternal(w, a, "delete user", err)
			return
		}
	}
	if err := tx.Commit(); err != nil {
		writeInternal(w, a, "delete user", err)
		return
	}
	a.hub.notify(u.ID)
	a.audit(p.user.ID, p.user.Username, p.device.ID, "user.delete", "deleted "+u.Username+" and all their data", p.ip)
	w.WriteHeader(http.StatusNoContent)
}

// ---- overview & activity (web admin) ------------------------------------------------------

type collectionStat struct {
	Collection string `json:"collection"`
	Count      int64  `json:"count"`
	Deleted    int64  `json:"deleted"`
}

func (a *App) handleStats(w http.ResponseWriter, r *http.Request, p *principal) {
	uid, ok := a.targetUser(w, r, p)
	if !ok {
		return
	}
	st, err := a.userStats(uid)
	if err != nil {
		writeInternal(w, a, "stats", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"user":        uid,
		"rev":         st.Rev,
		"lastSyncAt":  st.LastSyncAt,
		"devices":     st.Devices,
		"records":     st.Records,
		"collections": st.Collections,
	})
}

func (a *App) handleAudit(w http.ResponseWriter, r *http.Request, p *principal) {
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	if limit <= 0 || limit > 500 {
		limit = 200
	}
	before, _ := strconv.ParseInt(q.Get("before"), 10, 64)
	if before <= 0 {
		before = 1<<62 - 1
	}
	where := `id < ?`
	args := []any{before}
	uid := q.Get("user")
	if p.user.Role != "admin" {
		uid = p.user.ID // members only see their own account's activity
	}
	if uid != "" {
		where += ` AND user_id = ?`
		args = append(args, uid)
	}
	args = append(args, limit)
	rows, err := a.db.Query(`SELECT id, ts, user_id, username, device_id, event, detail, ip FROM audit WHERE `+where+` ORDER BY id DESC LIMIT ?`, args...)
	if err != nil {
		writeInternal(w, a, "audit", err)
		return
	}
	defer rows.Close()
	events := []AuditEvent{}
	for rows.Next() {
		var e AuditEvent
		if err := rows.Scan(&e.ID, &e.TS, &e.UserID, &e.Username, &e.DeviceID, &e.Event, &e.Detail, &e.IP); err != nil {
			writeInternal(w, a, "audit", err)
			return
		}
		events = append(events, e)
	}
	if err := rows.Err(); err != nil {
		writeInternal(w, a, "audit", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"events": events})
}
