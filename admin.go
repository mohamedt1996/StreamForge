package app

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strings"
)

// Admin-managed configuration endpoints (/api/admin/..., admin only, audit-logged).

func (a *App) auditAdmin(p *principal, event, detail string) {
	a.audit(p.user.ID, p.user.Username, p.device.ID, event, detail, p.ip)
}

// pathUser loads the user named by a path value, writing 404 when missing.
func (a *App) pathUser(w http.ResponseWriter, r *http.Request, name string) (User, bool) {
	u, err := a.getUser(r.PathValue(name))
	if errors.Is(err, errNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "user not found")
		return u, false
	}
	if err != nil {
		writeInternal(w, a, "load user", err)
		return u, false
	}
	return u, true
}

const maxSecretLen = 1024

func checkSecret(field string, s *string) string {
	if s != nil && len(*s) > maxSecretLen {
		return field + " is too long"
	}
	return ""
}

// ---- Dispatcharr connections ----------------------------------------------------------------

type dispatcharrServerView struct {
	ID          string           `json:"id"`
	Name        string           `json:"name"`
	URL         string           `json:"url"`
	Order       int              `json:"order"`
	CreatedAt   int64            `json:"createdAt"`
	UpdatedAt   int64            `json:"updatedAt"`
	Assignments []assignmentView `json:"assignments"`
}

// assignmentView never contains credentials, only whether each one is set.
type assignmentView struct {
	ServerID              string `json:"serverId"`
	ServerName            string `json:"serverName"`
	ServerURL             string `json:"serverUrl"`
	UserID                string `json:"userId"`
	User                  string `json:"user"`
	AuthMode              string `json:"authMode"`
	Username              string `json:"username"`
	HasXcPassword         bool   `json:"hasXcPassword"`
	HasWebPassword        bool   `json:"hasWebPassword"`
	HasAPIKey             bool   `json:"hasApiKey"`
	CredentialsUnreadable bool   `json:"credentialsUnreadable,omitempty"`
	UpdatedAt             int64  `json:"updatedAt"`
}

func (a *App) loadAssignments(where string, args ...any) ([]assignmentView, error) {
	rows, err := a.db.Query(`SELECT x.server_id, s.name, s.url, x.user_id, u.username, x.auth_mode, x.username, x.secret, x.updated_at
		FROM dispatcharr_assignments x
		JOIN dispatcharr_servers s ON s.id = x.server_id
		JOIN users u ON u.id = x.user_id
		WHERE `+where+` ORDER BY s.sort_order, s.name, u.username`, args...)
	if err != nil {
		return nil, err
	}
	type row struct {
		v      assignmentView
		secret string
	}
	var raw []row
	for rows.Next() {
		var r row
		if err := rows.Scan(&r.v.ServerID, &r.v.ServerName, &r.v.ServerURL, &r.v.UserID, &r.v.User, &r.v.AuthMode, &r.v.Username, &r.secret, &r.v.UpdatedAt); err != nil {
			rows.Close()
			return nil, err
		}
		raw = append(raw, r)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	out := make([]assignmentView, 0, len(raw))
	for _, r := range raw {
		sec, err := a.openAssignment(r.v.UserID, r.v.ServerID, r.secret)
		if err != nil {
			r.v.CredentialsUnreadable = true
		}
		r.v.HasXcPassword, r.v.HasWebPassword, r.v.HasAPIKey = sec.XcPassword != "", sec.WebPassword != "", sec.APIKey != ""
		out = append(out, r.v)
	}
	return out, nil
}

func (a *App) loadServers(where string, args ...any) ([]dispatcharrServerView, error) {
	q := `SELECT id, name, url, sort_order, created_at, updated_at FROM dispatcharr_servers`
	if where != "" {
		q += ` WHERE ` + where
	}
	rows, err := a.db.Query(q+` ORDER BY sort_order, name`, args...)
	if err != nil {
		return nil, err
	}
	out := []dispatcharrServerView{}
	for rows.Next() {
		var s dispatcharrServerView
		if err := rows.Scan(&s.ID, &s.Name, &s.URL, &s.Order, &s.CreatedAt, &s.UpdatedAt); err != nil {
			rows.Close()
			return nil, err
		}
		s.Assignments = []assignmentView{}
		out = append(out, s)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(out) == 0 {
		return out, nil
	}
	as, err := a.loadAssignments(`1 = 1`)
	if err != nil {
		return nil, err
	}
	idx := map[string]int{}
	for i, s := range out {
		idx[s.ID] = i
	}
	for _, x := range as {
		if i, ok := idx[x.ServerID]; ok {
			out[i].Assignments = append(out[i].Assignments, x)
		}
	}
	return out, nil
}

func (a *App) loadServer(w http.ResponseWriter, id string) (dispatcharrServerView, bool) {
	list, err := a.loadServers(`id = ?`, strings.ToLower(id))
	if err != nil {
		writeInternal(w, a, "load dispatcharr", err)
		return dispatcharrServerView{}, false
	}
	if len(list) == 0 {
		writeErr(w, http.StatusNotFound, "not_found", "Dispatcharr connection not found")
		return dispatcharrServerView{}, false
	}
	return list[0], true
}

func assignedUserIDs(s dispatcharrServerView) []string {
	ids := make([]string, 0, len(s.Assignments))
	for _, x := range s.Assignments {
		ids = append(ids, x.UserID)
	}
	return ids
}

func (a *App) handleListDispatcharr(w http.ResponseWriter, r *http.Request, p *principal) {
	list, err := a.loadServers("")
	if err != nil {
		writeInternal(w, a, "list dispatcharr", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"servers": list})
}

type serverInput struct {
	ID    *string `json:"id"`
	Name  *string `json:"name"`
	URL   *string `json:"url"`
	Order *int    `json:"order"`
}

func (a *App) nextOrder(table string) int {
	var n sql.NullInt64
	_ = a.db.QueryRow(`SELECT MAX(sort_order) FROM ` + table).Scan(&n)
	if !n.Valid {
		return 0
	}
	return int(n.Int64) + 1
}

// createServer inserts a Dispatcharr connection (id "" = new random UUID).
func (a *App) createServer(id, name, rawURL string, order *int) (string, string) {
	u, ok := normalizeServerURL(rawURL)
	if !ok {
		return "", "url must be an http(s) URL, e.g. http://192.168.1.10:9191"
	}
	name = cleanText(name, 100)
	if name == "" {
		name = "Dispatcharr"
	}
	if id == "" {
		id = newUUID()
	}
	o := a.nextOrder("dispatcharr_servers")
	if order != nil {
		o = *order
	}
	now := a.nowMs()
	if _, err := a.db.Exec(`INSERT INTO dispatcharr_servers(id, name, url, sort_order, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)`,
		id, name, u, o, now, now); err != nil {
		if isUniqueErr(err) {
			return "", "a connection with this id already exists"
		}
		return "", "internal: " + err.Error()
	}
	return id, ""
}

func (a *App) handleCreateDispatcharr(w http.ResponseWriter, r *http.Request, p *principal) {
	var req serverInput
	if !decodeJSON(w, r, maxSmallBody, &req) {
		return
	}
	id := ""
	if req.ID != nil && strings.TrimSpace(*req.ID) != "" {
		id = strings.ToLower(strings.TrimSpace(*req.ID))
		if !uuidRe.MatchString(id) {
			writeErr(w, http.StatusBadRequest, "invalid_id", "id must be a UUID")
			return
		}
	}
	var name, u string
	if req.Name != nil {
		name = *req.Name
	}
	if req.URL != nil {
		u = *req.URL
	}
	id, msg := a.createServer(id, name, u, req.Order)
	switch {
	case strings.HasPrefix(msg, "internal: "):
		writeInternal(w, a, "create dispatcharr", errors.New(msg))
		return
	case strings.Contains(msg, "already exists"):
		writeErr(w, http.StatusConflict, "exists", msg)
		return
	case msg != "":
		writeErr(w, http.StatusBadRequest, "invalid_url", msg)
		return
	}
	s, ok := a.loadServer(w, id)
	if !ok {
		return
	}
	a.auditAdmin(p, "admin.dispatcharr.create", fmt.Sprintf("added Dispatcharr %q (%s)", s.Name, s.URL))
	writeJSON(w, http.StatusOK, s)
}

func (a *App) handlePatchDispatcharr(w http.ResponseWriter, r *http.Request, p *principal) {
	s, ok := a.loadServer(w, r.PathValue("id"))
	if !ok {
		return
	}
	var req serverInput
	if !decodeJSON(w, r, maxSmallBody, &req) {
		return
	}
	name, u, order := s.Name, s.URL, s.Order
	if req.Name != nil {
		if name = cleanText(*req.Name, 100); name == "" {
			writeErr(w, http.StatusBadRequest, "invalid_name", "name must not be empty")
			return
		}
	}
	if req.URL != nil {
		var ok bool
		if u, ok = normalizeServerURL(*req.URL); !ok {
			writeErr(w, http.StatusBadRequest, "invalid_url", "url must be an http(s) URL, e.g. http://192.168.1.10:9191")
			return
		}
	}
	if req.Order != nil {
		order = *req.Order
	}
	if _, err := a.db.Exec(`UPDATE dispatcharr_servers SET name = ?, url = ?, sort_order = ?, updated_at = ? WHERE id = ?`,
		name, u, order, a.nowMs(), s.ID); err != nil {
		writeInternal(w, a, "patch dispatcharr", err)
		return
	}
	if err := a.reconcileUsers(assignedUserIDs(s)); err != nil {
		writeInternal(w, a, "patch dispatcharr reconcile", err)
		return
	}
	a.auditAdmin(p, "admin.dispatcharr.update", fmt.Sprintf("updated Dispatcharr %q (%s), %d user(s) refreshed", name, u, len(s.Assignments)))
	s, ok = a.loadServer(w, s.ID)
	if ok {
		writeJSON(w, http.StatusOK, s)
	}
}

func (a *App) handleDeleteDispatcharr(w http.ResponseWriter, r *http.Request, p *principal) {
	s, ok := a.loadServer(w, r.PathValue("id"))
	if !ok {
		return
	}
	if _, err := a.db.Exec(`DELETE FROM dispatcharr_servers WHERE id = ?`, s.ID); err != nil {
		writeInternal(w, a, "delete dispatcharr", err)
		return
	}
	if err := a.reconcileUsers(assignedUserIDs(s)); err != nil {
		writeInternal(w, a, "delete dispatcharr reconcile", err)
		return
	}
	a.auditAdmin(p, "admin.dispatcharr.delete", fmt.Sprintf("deleted Dispatcharr %q, removed from %d user(s)", s.Name, len(s.Assignments)))
	w.WriteHeader(http.StatusNoContent)
}

type assignmentInput struct {
	AuthMode    *string `json:"authMode"`
	Username    *string `json:"username"`
	XcPassword  *string `json:"xcPassword"`
	WebPassword *string `json:"webPassword"`
	APIKey      *string `json:"apiKey"`
}

func (in assignmentInput) validate() string {
	if in.AuthMode != nil && !validAuthMode(*in.AuthMode) {
		return "authMode must be xc, web or apiKey"
	}
	if in.Username != nil && len(*in.Username) > 256 {
		return "username is too long"
	}
	for _, m := range []string{checkSecret("xcPassword", in.XcPassword), checkSecret("webPassword", in.WebPassword), checkSecret("apiKey", in.APIKey)} {
		if m != "" {
			return m
		}
	}
	return ""
}

// upsertAssignment merges the input into the user's assignment (nil fields keep their value)
// and stores it. created reports whether the assignment is new.
func (a *App) upsertAssignment(serverID, userID string, in assignmentInput) (created bool, err error) {
	var mode, username, secret string
	err = a.db.QueryRow(`SELECT auth_mode, username, secret FROM dispatcharr_assignments WHERE server_id = ? AND user_id = ?`,
		serverID, userID).Scan(&mode, &username, &secret)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		created, mode = true, "xc"
	case err != nil:
		return false, err
	}
	sec, derr := a.openAssignment(userID, serverID, secret)
	if derr != nil {
		a.log.Printf("dispatcharr credentials %s/%s unreadable, replacing: %v", serverID, userID, derr)
		sec = serverSecret{}
	}
	if in.AuthMode != nil {
		mode = *in.AuthMode
	}
	if in.Username != nil {
		username = cleanText(*in.Username, 256)
	}
	if in.XcPassword != nil {
		sec.XcPassword = *in.XcPassword
	}
	if in.WebPassword != nil {
		sec.WebPassword = *in.WebPassword
	}
	if in.APIKey != nil {
		sec.APIKey = *in.APIKey
	}
	now := a.nowMs()
	_, err = a.db.Exec(`INSERT INTO dispatcharr_assignments(server_id, user_id, auth_mode, username, secret, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(server_id, user_id) DO UPDATE SET auth_mode = excluded.auth_mode, username = excluded.username,
			secret = excluded.secret, updated_at = excluded.updated_at`,
		serverID, userID, mode, username, a.sealAssignment(userID, serverID, sec), now, now)
	return created, err
}

func (a *App) handlePutAssignment(w http.ResponseWriter, r *http.Request, p *principal) {
	s, ok := a.loadServer(w, r.PathValue("id"))
	if !ok {
		return
	}
	u, ok := a.pathUser(w, r, "userId")
	if !ok {
		return
	}
	var in assignmentInput
	if !decodeJSON(w, r, maxSmallBody, &in) {
		return
	}
	if msg := in.validate(); msg != "" {
		writeErr(w, http.StatusBadRequest, "invalid_assignment", msg)
		return
	}
	created, err := a.upsertAssignment(s.ID, u.ID, in)
	if err != nil {
		writeInternal(w, a, "assign dispatcharr", err)
		return
	}
	var clear []string
	if created { // a new assignment overrides an earlier "removed by user"
		clear = []string{"servers|" + s.ID}
	}
	if _, err := a.reconcileUserClearing(u.ID, clear); err != nil {
		writeInternal(w, a, "assign dispatcharr reconcile", err)
		return
	}
	verb := "updated credentials of"
	if created {
		verb = "assigned"
	}
	a.auditAdmin(p, "admin.dispatcharr.assign", fmt.Sprintf("%s Dispatcharr %q for %s", verb, s.Name, u.Username))
	list, err := a.loadAssignments(`x.server_id = ? AND x.user_id = ?`, s.ID, u.ID)
	if err != nil || len(list) == 0 {
		writeInternal(w, a, "load assignment", err)
		return
	}
	writeJSON(w, http.StatusOK, list[0])
}

func (a *App) handleDeleteAssignment(w http.ResponseWriter, r *http.Request, p *principal) {
	s, ok := a.loadServer(w, r.PathValue("id"))
	if !ok {
		return
	}
	u, ok := a.pathUser(w, r, "userId")
	if !ok {
		return
	}
	res, err := a.db.Exec(`DELETE FROM dispatcharr_assignments WHERE server_id = ? AND user_id = ?`, s.ID, u.ID)
	if err != nil {
		writeInternal(w, a, "unassign dispatcharr", err)
		return
	}
	if _, err := a.reconcileUser(u.ID); err != nil {
		writeInternal(w, a, "unassign dispatcharr reconcile", err)
		return
	}
	if n, _ := res.RowsAffected(); n > 0 {
		a.auditAdmin(p, "admin.dispatcharr.unassign", fmt.Sprintf("removed Dispatcharr %q from %s", s.Name, u.Username))
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---- addon library ----------------------------------------------------------------------------

type userRef struct {
	ID       string `json:"id"`
	Username string `json:"username"`
}

type addonView struct {
	ID           string    `json:"id"`
	TransportURL string    `json:"transportUrl"`
	Name         string    `json:"name"`       // effective name written to records
	CustomName   string    `json:"customName"` // admin override ("" = manifest name)
	ManifestName string    `json:"manifestName"`
	ManifestID   string    `json:"manifestId"`
	Version      string    `json:"version"`
	Description  string    `json:"description"`
	Logo         string    `json:"logo"` // data: URI or ""
	AllUsers     bool      `json:"allUsers"`
	Order        int       `json:"order"`
	FetchedAt    int64     `json:"fetchedAt"`
	FetchError   string    `json:"fetchError"`
	CreatedAt    int64     `json:"createdAt"`
	UpdatedAt    int64     `json:"updatedAt"`
	Users        []userRef `json:"users"`
}

func (a *App) loadAddons(where string, args ...any) ([]addonView, error) {
	q := `SELECT id, transport_url, name, manifest_name, manifest_id, version, description, logo, all_users,
		sort_order, fetched_at, fetch_error, created_at, updated_at FROM addon_library`
	if where != "" {
		q += ` WHERE ` + where
	}
	rows, err := a.db.Query(q+` ORDER BY sort_order, created_at`, args...)
	if err != nil {
		return nil, err
	}
	out := []addonView{}
	for rows.Next() {
		var v addonView
		var all int
		if err := rows.Scan(&v.ID, &v.TransportURL, &v.CustomName, &v.ManifestName, &v.ManifestID, &v.Version, &v.Description,
			&v.Logo, &all, &v.Order, &v.FetchedAt, &v.FetchError, &v.CreatedAt, &v.UpdatedAt); err != nil {
			rows.Close()
			return nil, err
		}
		v.AllUsers = all != 0
		v.Name = addonDisplayName(v.CustomName, v.ManifestName, v.TransportURL)
		v.Users = []userRef{}
		out = append(out, v)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(out) == 0 {
		return out, nil
	}
	idx := map[string]int{}
	for i, v := range out {
		idx[v.ID] = i
	}
	rows, err = a.db.Query(`SELECT x.addon_id, u.id, u.username FROM addon_assignments x JOIN users u ON u.id = x.user_id ORDER BY u.username`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var aid string
		var u userRef
		if err := rows.Scan(&aid, &u.ID, &u.Username); err != nil {
			return nil, err
		}
		if i, ok := idx[aid]; ok {
			out[i].Users = append(out[i].Users, u)
		}
	}
	return out, rows.Err()
}

func (a *App) loadAddon(w http.ResponseWriter, id string) (addonView, bool) {
	list, err := a.loadAddons(`id = ?`, id)
	if err != nil {
		writeInternal(w, a, "load addon", err)
		return addonView{}, false
	}
	if len(list) == 0 {
		writeErr(w, http.StatusNotFound, "not_found", "addon not found")
		return addonView{}, false
	}
	return list[0], true
}

// addonAffected lists the users whose records depend on the addon.
func (a *App) addonAffected(v addonView, allUsers bool) ([]string, error) {
	if allUsers || v.AllUsers {
		return a.allUserIDs()
	}
	ids := make([]string, 0, len(v.Users))
	for _, u := range v.Users {
		ids = append(ids, u.ID)
	}
	return ids, nil
}

func (a *App) handleListAddons(w http.ResponseWriter, r *http.Request, p *principal) {
	list, err := a.loadAddons("")
	if err != nil {
		writeInternal(w, a, "list addons", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"addons": list})
}

// addLibraryAddon inserts an addon (manifest fetched when fetch is true) and returns its id.
// existing=true when the transport URL is already in the library.
func (a *App) addLibraryAddon(r *http.Request, transportURL, name string, allUsers bool, order *int, fetch bool) (id string, existing bool, err error) {
	if err := a.db.QueryRow(`SELECT id FROM addon_library WHERE transport_url = ?`, transportURL).Scan(&id); err == nil {
		return id, true, nil
	} else if !errors.Is(err, sql.ErrNoRows) {
		return "", false, err
	}
	var m addonManifest
	var logo, fetchErr string
	var fetchedAt int64
	if fetch {
		var ferr error
		m, logo, ferr = a.fetchManifest(r.Context(), transportURL)
		if ferr != nil {
			fetchErr = ferr.Error()
		} else {
			fetchedAt = a.nowMs()
			if m.BehaviorHints.ConfigurationRequired {
				fetchErr = "this addon must be configured on its website first; use the configured manifest link"
			}
		}
	}
	o := a.nextOrder("addon_library")
	if order != nil {
		o = *order
	}
	now := a.nowMs()
	id = newID("a_")
	all := 0
	if allUsers {
		all = 1
	}
	_, err = a.db.Exec(`INSERT INTO addon_library(id, transport_url, name, manifest_name, manifest_id, version, description, logo,
		all_users, sort_order, fetched_at, fetch_error, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		id, transportURL, cleanText(name, 100), m.Name, m.ID, m.Version, m.Description, logo, all, o, fetchedAt, fetchErr, now, now)
	return id, false, err
}

func (a *App) handleCreateAddon(w http.ResponseWriter, r *http.Request, p *principal) {
	var req struct {
		URL      string   `json:"url"`
		Name     string   `json:"name"`
		AllUsers bool     `json:"allUsers"`
		Order    *int     `json:"order"`
		Users    []string `json:"users"`
	}
	if !decodeJSON(w, r, maxSmallBody, &req) {
		return
	}
	tu, err := normalizeAddonURL(req.URL)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid_url", err.Error())
		return
	}
	for _, uid := range req.Users {
		if _, err := a.getUser(uid); err != nil {
			writeErr(w, http.StatusBadRequest, "invalid_user", "unknown user "+uid)
			return
		}
	}
	id, existing, err := a.addLibraryAddon(r, tu, req.Name, req.AllUsers, req.Order, true)
	if err != nil {
		writeInternal(w, a, "create addon", err)
		return
	}
	if existing {
		writeJSON(w, http.StatusConflict, map[string]any{"error": "this addon is already in the library", "code": "addon_exists", "id": id})
		return
	}
	now := a.nowMs()
	for _, uid := range req.Users {
		if _, err := a.db.Exec(`INSERT OR IGNORE INTO addon_assignments(addon_id, user_id, created_at) VALUES (?, ?, ?)`, id, uid, now); err != nil {
			writeInternal(w, a, "assign addon", err)
			return
		}
	}
	v, ok := a.loadAddon(w, id)
	if !ok {
		return
	}
	affected, err := a.addonAffected(v, false)
	if err == nil {
		err = a.reconcileUsers(affected)
	}
	if err != nil {
		writeInternal(w, a, "create addon reconcile", err)
		return
	}
	who := fmt.Sprintf("%d user(s)", len(v.Users))
	if v.AllUsers {
		who = "all users"
	}
	a.auditAdmin(p, "admin.addon.create", fmt.Sprintf("added addon %q (%s) for %s", v.Name, v.TransportURL, who))
	writeJSON(w, http.StatusOK, v)
}

func (a *App) handlePatchAddon(w http.ResponseWriter, r *http.Request, p *principal) {
	v, ok := a.loadAddon(w, r.PathValue("id"))
	if !ok {
		return
	}
	var req struct {
		Name     *string `json:"name"`
		AllUsers *bool   `json:"allUsers"`
		Order    *int    `json:"order"`
	}
	if !decodeJSON(w, r, maxSmallBody, &req) {
		return
	}
	name, all, order := v.CustomName, v.AllUsers, v.Order
	if req.Name != nil {
		name = cleanText(*req.Name, 100)
	}
	if req.AllUsers != nil {
		all = *req.AllUsers
	}
	if req.Order != nil {
		order = *req.Order
	}
	allInt := 0
	if all {
		allInt = 1
	}
	if _, err := a.db.Exec(`UPDATE addon_library SET name = ?, all_users = ?, sort_order = ?, updated_at = ? WHERE id = ?`,
		name, allInt, order, a.nowMs(), v.ID); err != nil {
		writeInternal(w, a, "patch addon", err)
		return
	}
	affected, err := a.addonAffected(v, all)
	if err == nil {
		err = a.reconcileUsers(affected)
	}
	if err != nil {
		writeInternal(w, a, "patch addon reconcile", err)
		return
	}
	changes := []string{}
	if all != v.AllUsers {
		changes = append(changes, fmt.Sprintf("all users: %v", all))
	}
	if name != v.CustomName {
		changes = append(changes, "renamed")
	}
	if order != v.Order {
		changes = append(changes, fmt.Sprintf("order %d", order))
	}
	if len(changes) > 0 {
		a.auditAdmin(p, "admin.addon.update", fmt.Sprintf("addon %q: %s", v.Name, strings.Join(changes, ", ")))
	}
	if v, ok = a.loadAddon(w, v.ID); ok {
		writeJSON(w, http.StatusOK, v)
	}
}

func (a *App) handleRefreshAddon(w http.ResponseWriter, r *http.Request, p *principal) {
	v, ok := a.loadAddon(w, r.PathValue("id"))
	if !ok {
		return
	}
	m, logo, ferr := a.fetchManifest(r.Context(), v.TransportURL)
	now := a.nowMs()
	if ferr != nil {
		if _, err := a.db.Exec(`UPDATE addon_library SET fetch_error = ?, updated_at = ? WHERE id = ?`, ferr.Error(), now, v.ID); err != nil {
			writeInternal(w, a, "refresh addon", err)
			return
		}
	} else {
		fe := ""
		if m.BehaviorHints.ConfigurationRequired {
			fe = "this addon must be configured on its website first; use the configured manifest link"
		}
		if _, err := a.db.Exec(`UPDATE addon_library SET manifest_name = ?, manifest_id = ?, version = ?, description = ?, logo = ?,
			fetched_at = ?, fetch_error = ?, updated_at = ? WHERE id = ?`,
			m.Name, m.ID, m.Version, m.Description, logo, now, fe, now, v.ID); err != nil {
			writeInternal(w, a, "refresh addon", err)
			return
		}
		affected, err := a.addonAffected(v, false)
		if err == nil {
			err = a.reconcileUsers(affected) // the display name may have changed
		}
		if err != nil {
			writeInternal(w, a, "refresh addon reconcile", err)
			return
		}
	}
	if v, ok = a.loadAddon(w, v.ID); ok {
		writeJSON(w, http.StatusOK, v)
	}
}

func (a *App) handleDeleteAddon(w http.ResponseWriter, r *http.Request, p *principal) {
	v, ok := a.loadAddon(w, r.PathValue("id"))
	if !ok {
		return
	}
	affected, err := a.addonAffected(v, false)
	if err != nil {
		writeInternal(w, a, "delete addon", err)
		return
	}
	if _, err := a.db.Exec(`DELETE FROM addon_library WHERE id = ?`, v.ID); err != nil {
		writeInternal(w, a, "delete addon", err)
		return
	}
	if err := a.reconcileUsers(affected); err != nil {
		writeInternal(w, a, "delete addon reconcile", err)
		return
	}
	a.auditAdmin(p, "admin.addon.delete", fmt.Sprintf("deleted addon %q, removed from %d user(s)", v.Name, len(affected)))
	w.WriteHeader(http.StatusNoContent)
}

func (a *App) handlePutAddonUser(w http.ResponseWriter, r *http.Request, p *principal) {
	v, ok := a.loadAddon(w, r.PathValue("id"))
	if !ok {
		return
	}
	u, ok := a.pathUser(w, r, "userId")
	if !ok {
		return
	}
	res, err := a.db.Exec(`INSERT OR IGNORE INTO addon_assignments(addon_id, user_id, created_at) VALUES (?, ?, ?)`, v.ID, u.ID, a.nowMs())
	if err != nil {
		writeInternal(w, a, "assign addon", err)
		return
	}
	var clear []string
	if n, _ := res.RowsAffected(); n > 0 { // a new assignment overrides an earlier "removed by user"
		clear = []string{"addons|" + v.TransportURL}
	}
	if _, err := a.reconcileUserClearing(u.ID, clear); err != nil {
		writeInternal(w, a, "assign addon reconcile", err)
		return
	}
	if n, _ := res.RowsAffected(); n > 0 {
		a.auditAdmin(p, "admin.addon.assign", fmt.Sprintf("assigned addon %q to %s", v.Name, u.Username))
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *App) handleDeleteAddonUser(w http.ResponseWriter, r *http.Request, p *principal) {
	v, ok := a.loadAddon(w, r.PathValue("id"))
	if !ok {
		return
	}
	u, ok := a.pathUser(w, r, "userId")
	if !ok {
		return
	}
	res, err := a.db.Exec(`DELETE FROM addon_assignments WHERE addon_id = ? AND user_id = ?`, v.ID, u.ID)
	if err != nil {
		writeInternal(w, a, "unassign addon", err)
		return
	}
	if _, err := a.reconcileUser(u.ID); err != nil {
		writeInternal(w, a, "unassign addon reconcile", err)
		return
	}
	if n, _ := res.RowsAffected(); n > 0 {
		a.auditAdmin(p, "admin.addon.unassign", fmt.Sprintf("removed addon %q from %s", v.Name, u.Username))
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---- managed settings ---------------------------------------------------------------------------

type settingsInput struct {
	Values map[string]json.RawMessage `json:"values"`
}

// validateSettingsInput returns key → compacted value (nil = clear) or an error message.
func validateSettingsInput(in settingsInput) (map[string]json.RawMessage, string) {
	out := map[string]json.RawMessage{}
	for k, raw := range in.Values {
		t := strings.TrimSpace(string(raw))
		if t == "" || t == "null" {
			if _, ok := settingSpecFor(k); !ok {
				return nil, fmt.Sprintf("%q is not a synced settings key", k)
			}
			out[k] = nil
			continue
		}
		v, err := validateSettingValue(k, raw)
		if err != nil {
			return nil, err.Error()
		}
		out[k] = v
	}
	return out, ""
}

func (a *App) loadSettingsMap(query string, args ...any) (map[string]json.RawMessage, error) {
	rows, err := a.db.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]json.RawMessage{}
	for rows.Next() {
		var k, v string
		if err := rows.Scan(&k, &v); err != nil {
			return nil, err
		}
		out[k] = json.RawMessage(v)
	}
	return out, rows.Err()
}

func (a *App) handleGetAdminSettings(w http.ResponseWriter, r *http.Request, p *principal) {
	defaults, err := a.loadSettingsMap(`SELECT key, value FROM default_settings`)
	if err != nil {
		writeInternal(w, a, "settings defaults", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"keys": syncedSettings, "defaults": defaults})
}

func (a *App) handlePutDefaultSettings(w http.ResponseWriter, r *http.Request, p *principal) {
	var in settingsInput
	if !decodeJSON(w, r, maxSmallBody, &in) {
		return
	}
	vals, msg := validateSettingsInput(in)
	if msg != "" {
		writeErr(w, http.StatusBadRequest, "invalid_setting", msg)
		return
	}
	now := a.nowMs()
	for _, k := range sortedKeys(vals) {
		var err error
		if vals[k] == nil {
			_, err = a.db.Exec(`DELETE FROM default_settings WHERE key = ?`, k)
		} else {
			_, err = a.db.Exec(`INSERT INTO default_settings(key, value, updated_at) VALUES (?, ?, ?)
				ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`, k, string(vals[k]), now)
		}
		if err != nil {
			writeInternal(w, a, "set default setting", err)
			return
		}
	}
	if len(vals) > 0 {
		a.auditAdmin(p, "admin.settings.defaults", "changed default settings: "+strings.Join(sortedKeys(vals), ", "))
	}
	a.handleGetAdminSettings(w, r, p)
}

// handleApplyDefaultSettings pushes the default settings to existing users (all, or the
// listed ones), overwriting those keys in their managed settings.
func (a *App) handleApplyDefaultSettings(w http.ResponseWriter, r *http.Request, p *principal) {
	var req struct {
		Users []string `json:"users"`
	}
	if r.ContentLength != 0 && !decodeJSON(w, r, maxSmallBody, &req) {
		return
	}
	ids := req.Users
	if len(ids) == 0 {
		var err error
		if ids, err = a.allUserIDs(); err != nil {
			writeInternal(w, a, "apply defaults", err)
			return
		}
	}
	now := a.nowMs()
	applied := 0
	for _, uid := range ids {
		res, err := a.db.Exec(`INSERT INTO managed_settings(user_id, key, value, updated_at)
			SELECT u.id, d.key, d.value, ? FROM default_settings d JOIN users u ON u.id = ?
			WHERE 1
			ON CONFLICT(user_id, key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`, now, uid)
		if err != nil {
			writeInternal(w, a, "apply defaults", err)
			return
		}
		if n, _ := res.RowsAffected(); n > 0 {
			applied++
		}
	}
	// Pushing the defaults overrides users' earlier "removed by user" of those settings.
	keys, err := a.queryStrings(`SELECT key FROM default_settings ORDER BY key`)
	if err != nil {
		writeInternal(w, a, "apply defaults", err)
		return
	}
	clear := make([]string, 0, len(keys))
	for _, k := range keys {
		clear = append(clear, "settings|"+k)
	}
	seen := map[string]bool{}
	var firstErr error
	for _, uid := range ids {
		if seen[uid] {
			continue
		}
		seen[uid] = true
		if _, err := a.reconcileUserClearing(uid, clear); err != nil {
			a.log.Printf("reconcile managed records for %s: %v", uid, err)
			if firstErr == nil {
				firstErr = err
			}
		}
	}
	if firstErr != nil {
		writeInternal(w, a, "apply defaults reconcile", firstErr)
		return
	}
	a.auditAdmin(p, "admin.settings.apply", fmt.Sprintf("pushed default settings to %d user(s)", applied))
	writeJSON(w, http.StatusOK, map[string]any{"users": applied})
}

func (a *App) setManagedSettings(userID string, vals map[string]json.RawMessage) error {
	now := a.nowMs()
	for _, k := range sortedKeys(vals) {
		var err error
		if vals[k] == nil {
			_, err = a.db.Exec(`DELETE FROM managed_settings WHERE user_id = ? AND key = ?`, userID, k)
		} else {
			_, err = a.db.Exec(`INSERT INTO managed_settings(user_id, key, value, updated_at) VALUES (?, ?, ?, ?)
				ON CONFLICT(user_id, key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
				userID, k, string(vals[k]), now)
		}
		if err != nil {
			return err
		}
	}
	return nil
}

func (a *App) handlePutUserSettings(w http.ResponseWriter, r *http.Request, p *principal) {
	u, ok := a.pathUser(w, r, "id")
	if !ok {
		return
	}
	var in settingsInput
	if !decodeJSON(w, r, maxSmallBody, &in) {
		return
	}
	vals, msg := validateSettingsInput(in)
	if msg != "" {
		writeErr(w, http.StatusBadRequest, "invalid_setting", msg)
		return
	}
	if err := a.setManagedSettings(u.ID, vals); err != nil {
		writeInternal(w, a, "set user settings", err)
		return
	}
	var clear []string // setting a value for the user overrides an earlier "removed by user"
	for _, k := range sortedKeys(vals) {
		if vals[k] != nil {
			clear = append(clear, "settings|"+k)
		}
	}
	if _, err := a.reconcileUserClearing(u.ID, clear); err != nil {
		writeInternal(w, a, "user settings reconcile", err)
		return
	}
	if len(vals) > 0 {
		a.auditAdmin(p, "admin.settings.user", fmt.Sprintf("managed settings of %s: %s", u.Username, strings.Join(sortedKeys(vals), ", ")))
	}
	settings, err := a.userSettingsView(u.ID)
	if err != nil {
		writeInternal(w, a, "user settings", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"settings": settings})
}

// ---- per-user view ------------------------------------------------------------------------------

type userRecord struct {
	id      string
	data    map[string]json.RawMessage
	managed bool
}

func (a *App) userRecords(userID, collection string) ([]userRecord, error) {
	rows, err := a.db.Query(`SELECT id, data, managed FROM records WHERE user_id = ? AND collection = ? AND deleted = 0 ORDER BY id`, userID, collection)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []userRecord{}
	for rows.Next() {
		var r userRecord
		var data sql.NullString
		var man int
		if err := rows.Scan(&r.id, &data, &man); err != nil {
			return nil, err
		}
		r.managed = man != 0
		if data.Valid {
			_ = json.Unmarshal([]byte(data.String), &r.data)
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func jsonString(m map[string]json.RawMessage, k string) string {
	var s string
	_ = json.Unmarshal(m[k], &s)
	return s
}

func jsonInt(m map[string]json.RawMessage, k string) int {
	var f float64
	_ = json.Unmarshal(m[k], &f)
	return int(f)
}

type userSettingView struct {
	settingSpec
	Value        json.RawMessage `json:"value"`        // current synced value (null = never synced)
	Managed      bool            `json:"managed"`      // locked by the admin
	ManagedValue json.RawMessage `json:"managedValue"` // admin value (null = not managed)
}

func (a *App) userSettingsView(userID string) ([]userSettingView, error) {
	recs, err := a.userRecords(userID, "settings")
	if err != nil {
		return nil, err
	}
	managed, err := a.loadSettingsMap(`SELECT key, value FROM managed_settings WHERE user_id = ?`, userID)
	if err != nil {
		return nil, err
	}
	current := map[string]json.RawMessage{}
	for _, r := range recs {
		if v, ok := r.data["value"]; ok {
			current[r.id] = v
		}
	}
	out := make([]userSettingView, 0, len(syncedSettings))
	for _, s := range syncedSettings {
		v := userSettingView{settingSpec: s, Value: json.RawMessage("null"), ManagedValue: json.RawMessage("null")}
		if c, ok := current[s.Key]; ok {
			v.Value = c
		}
		if m, ok := managed[s.Key]; ok {
			v.Managed, v.ManagedValue = true, m
		}
		out = append(out, v)
	}
	return out, nil
}

type collectionStats struct {
	Rev         int64            `json:"rev"`
	LastSyncAt  int64            `json:"lastSyncAt"`
	Devices     int64            `json:"devices"`
	Records     int64            `json:"records"`
	Collections []collectionStat `json:"collections"`
}

func (a *App) userStats(uid string) (collectionStats, error) {
	var s collectionStats
	if err := a.db.QueryRow(`SELECT rev, last_sync_at, (SELECT COUNT(*) FROM devices WHERE user_id = users.id) FROM users WHERE id = ?`, uid).
		Scan(&s.Rev, &s.LastSyncAt, &s.Devices); err != nil {
		return s, err
	}
	rows, err := a.db.Query(`SELECT collection, SUM(CASE WHEN deleted = 0 THEN 1 ELSE 0 END), SUM(deleted)
		FROM records WHERE user_id = ? GROUP BY collection ORDER BY collection`, uid)
	if err != nil {
		return s, err
	}
	defer rows.Close()
	s.Collections = []collectionStat{}
	for rows.Next() {
		var c collectionStat
		if err := rows.Scan(&c.Collection, &c.Count, &c.Deleted); err != nil {
			return s, err
		}
		s.Records += c.Count
		s.Collections = append(s.Collections, c)
	}
	return s, rows.Err()
}

func (a *App) handleAdminUser(w http.ResponseWriter, r *http.Request, p *principal) {
	u, ok := a.pathUser(w, r, "id")
	if !ok {
		return
	}
	devices, err := a.listDevices(u.ID)
	if err != nil {
		writeInternal(w, a, "user devices", err)
		return
	}
	for i := range devices {
		devices[i].Current = devices[i].ID == p.device.ID
	}
	stats, err := a.userStats(u.ID)
	if err != nil {
		writeInternal(w, a, "user stats", err)
		return
	}
	assignments, err := a.loadAssignments(`x.user_id = ?`, u.ID)
	if err != nil {
		writeInternal(w, a, "user assignments", err)
		return
	}
	library, err := a.loadAddons("")
	if err != nil {
		writeInternal(w, a, "user addons", err)
		return
	}
	byURL := map[string]addonView{}
	type libRef struct {
		ID           string `json:"id"`
		Name         string `json:"name"`
		TransportURL string `json:"transportUrl"`
		Logo         string `json:"logo"`
		AllUsers     bool   `json:"allUsers"`
		Assigned     bool   `json:"assigned"` // directly assigned to this user
	}
	libOut := make([]libRef, 0, len(library))
	direct := map[string]bool{}
	for _, v := range library {
		byURL[v.TransportURL] = v
		ref := libRef{ID: v.ID, Name: v.Name, TransportURL: v.TransportURL, Logo: v.Logo, AllUsers: v.AllUsers}
		for _, x := range v.Users {
			if x.ID == u.ID {
				ref.Assigned = true
				direct[v.ID] = true
			}
		}
		libOut = append(libOut, ref)
	}

	type addonOut struct {
		TransportURL string `json:"transportUrl"`
		Name         string `json:"name"`
		Enabled      bool   `json:"enabled"`
		Order        int    `json:"order"`
		Managed      bool   `json:"managed"`
		LibraryID    string `json:"libraryId"`
		Logo         string `json:"logo"`
		Source       string `json:"source"` // "all" | "direct" | "" (user's own)
	}
	recs, err := a.userRecords(u.ID, "addons")
	if err != nil {
		writeInternal(w, a, "user addon records", err)
		return
	}
	addons := make([]addonOut, 0, len(recs))
	for _, rcd := range recs {
		o := addonOut{TransportURL: rcd.id, Name: jsonString(rcd.data, "name"), Enabled: true, Order: jsonInt(rcd.data, "order"), Managed: rcd.managed}
		if raw, ok := rcd.data["enabled"]; ok {
			_ = json.Unmarshal(raw, &o.Enabled)
		}
		if v, ok := byURL[rcd.id]; ok {
			o.LibraryID, o.Logo = v.ID, v.Logo
			if rcd.managed {
				switch {
				case direct[v.ID]:
					o.Source = "direct"
				case v.AllUsers:
					o.Source = "all"
				}
			}
		}
		addons = append(addons, o)
	}
	sort.SliceStable(addons, func(i, j int) bool { return addons[i].Order < addons[j].Order })

	type serverOut struct {
		ID       string `json:"id"`
		Name     string `json:"name"`
		URL      string `json:"url"`
		Username string `json:"username"`
		AuthMode string `json:"authMode"`
		Order    int    `json:"order"`
		Managed  bool   `json:"managed"`
	}
	srecs, err := a.userRecords(u.ID, "servers")
	if err != nil {
		writeInternal(w, a, "user server records", err)
		return
	}
	servers := make([]serverOut, 0, len(srecs))
	for _, rcd := range srecs {
		servers = append(servers, serverOut{ID: rcd.id, Name: jsonString(rcd.data, "name"), URL: jsonString(rcd.data, "url"),
			Username: jsonString(rcd.data, "username"), AuthMode: jsonString(rcd.data, "authMode"), Order: jsonInt(rcd.data, "order"), Managed: rcd.managed})
	}
	sort.SliceStable(servers, func(i, j int) bool { return servers[i].Order < servers[j].Order })

	settings, err := a.userSettingsView(u.ID)
	if err != nil {
		writeInternal(w, a, "user settings", err)
		return
	}

	// Managed items the user removed from their account ("Removed by user").
	type dismissedOut struct {
		Collection  string `json:"collection"`
		ID          string `json:"id"`
		Name        string `json:"name"`
		DismissedAt int64  `json:"dismissedAt"`
	}
	dm, err := activeDismissals(a.db, u.ID)
	if err != nil {
		writeInternal(w, a, "user dismissals", err)
		return
	}
	dismissed := make([]dismissedOut, 0, len(dm))
	for _, k := range sortedKeys(dm) {
		c, item := splitRecKey(k)
		o := dismissedOut{Collection: c, ID: item, DismissedAt: dm[k].dismissedAt}
		switch c {
		case "addons":
			if v, ok := byURL[item]; ok {
				o.Name = v.Name
			}
		case "servers":
			for _, x := range assignments {
				if x.ServerID == item {
					o.Name = x.ServerName
				}
			}
		case "settings":
			if spec, ok := settingSpecFor(item); ok {
				o.Name = spec.Label
			}
		}
		if o.Name == "" {
			o.Name = item
		}
		dismissed = append(dismissed, o)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"dismissed":     dismissed,
		"user":          u,
		"devices":       devices,
		"stats":         stats,
		"dispatcharr":   assignments,
		"servers":       servers,
		"addons":        addons,
		"libraryAddons": libOut,
		"settings":      settings,
	})
}

// handleRestoreDismissed ("Push again") lifts a user's dismissal of a managed item so it is
// written to their devices again.
func (a *App) handleRestoreDismissed(w http.ResponseWriter, r *http.Request, p *principal) {
	u, ok := a.pathUser(w, r, "id")
	if !ok {
		return
	}
	var req struct {
		Collection string `json:"collection"`
		ID         string `json:"id"`
	}
	if !decodeJSON(w, r, maxSmallBody, &req) {
		return
	}
	did := dismissalIDFor(req.Collection, req.ID)
	if req.Collection == secretsCollection || did == "" || req.ID == "" {
		writeErr(w, http.StatusBadRequest, "invalid_dismissal", "collection must be servers, addons or settings, with an id")
		return
	}
	dm, err := activeDismissals(a.db, u.ID)
	if err != nil {
		writeInternal(w, a, "restore dismissal", err)
		return
	}
	c, item, _ := parseDismissedID(did)
	d, found := dm[recKey(c, item)]
	if !found {
		writeErr(w, http.StatusNotFound, "not_found", "the user hasn't removed this item")
		return
	}
	if _, err := a.reconcileUserClearing(u.ID, []string{d.id}); err != nil {
		writeInternal(w, a, "restore dismissal reconcile", err)
		return
	}
	a.auditAdmin(p, "admin.dismissal.restore", fmt.Sprintf("pushed %s %q to %s again", c, item, u.Username))
	w.WriteHeader(http.StatusNoContent)
}

// ---- copy from another user -------------------------------------------------------------------------

func (a *App) handleCopyFromUser(w http.ResponseWriter, r *http.Request, p *principal) {
	target, ok := a.pathUser(w, r, "id")
	if !ok {
		return
	}
	var req struct {
		From     string `json:"from"`
		Addons   *bool  `json:"addons"`
		Servers  *bool  `json:"servers"`
		Settings *bool  `json:"settings"`
	}
	if !decodeJSON(w, r, maxSmallBody, &req) {
		return
	}
	src, err := a.getUser(req.From)
	if errors.Is(err, errNotFound) {
		writeErr(w, http.StatusBadRequest, "invalid_user", "source user not found")
		return
	}
	if err != nil {
		writeInternal(w, a, "copy source", err)
		return
	}
	if src.ID == target.ID {
		writeErr(w, http.StatusBadRequest, "invalid_user", "choose a different user to copy from")
		return
	}
	want := func(b *bool) bool { return b == nil || *b }
	counts := map[string]int{"addons": 0, "servers": 0, "settings": 0}
	now := a.nowMs()

	if want(req.Addons) {
		recs, err := a.userRecords(src.ID, "addons")
		if err != nil {
			writeInternal(w, a, "copy addons", err)
			return
		}
		for _, rcd := range recs {
			tu, err := normalizeAddonURL(rcd.id)
			if err != nil {
				continue
			}
			id, _, err := a.addLibraryAddon(r, tu, jsonString(rcd.data, "name"), false, nil, false)
			if err != nil {
				writeInternal(w, a, "copy addon", err)
				return
			}
			if _, err := a.db.Exec(`INSERT OR IGNORE INTO addon_assignments(addon_id, user_id, created_at) VALUES (?, ?, ?)`, id, target.ID, now); err != nil {
				writeInternal(w, a, "copy addon assign", err)
				return
			}
			counts["addons"]++
		}
	}

	if want(req.Servers) {
		recs, err := a.userRecords(src.ID, "servers")
		if err != nil {
			writeInternal(w, a, "copy servers", err)
			return
		}
		for _, rcd := range recs {
			sid := strings.ToLower(rcd.id)
			if !uuidRe.MatchString(sid) {
				continue
			}
			var exists int
			if err := a.db.QueryRow(`SELECT COUNT(*) FROM dispatcharr_servers WHERE id = ?`, sid).Scan(&exists); err != nil {
				writeInternal(w, a, "copy server", err)
				return
			}
			if exists == 0 {
				if _, msg := a.createServer(sid, jsonString(rcd.data, "name"), jsonString(rcd.data, "url"), nil); msg != "" {
					if strings.HasPrefix(msg, "internal: ") {
						writeInternal(w, a, "copy server", errors.New(msg))
						return
					}
					continue // e.g. the source record has no usable URL
				}
			}
			// Credentials: the source's managed assignment if it has one, else its own synced secret.
			in := assignmentInput{}
			mode, uname := jsonString(rcd.data, "authMode"), jsonString(rcd.data, "username")
			var sec serverSecret
			var amode, auser, asecret string
			err := a.db.QueryRow(`SELECT auth_mode, username, secret FROM dispatcharr_assignments WHERE server_id = ? AND user_id = ?`, sid, src.ID).
				Scan(&amode, &auser, &asecret)
			switch {
			case err == nil:
				mode, uname = amode, auser
				sec, _ = a.openAssignment(src.ID, sid, asecret)
			case errors.Is(err, sql.ErrNoRows):
				var stored sql.NullString
				if err := a.db.QueryRow(`SELECT data FROM records WHERE user_id = ? AND collection = 'secrets' AND id = ? AND deleted = 0`,
					src.ID, "server:"+rcd.id).Scan(&stored); err == nil && stored.Valid {
					if plain, err := a.decrypt(src.ID, secretsCollection, "server:"+rcd.id, stored.String); err == nil {
						_ = json.Unmarshal(plain, &sec)
					}
				}
			default:
				writeInternal(w, a, "copy server credentials", err)
				return
			}
			if !validAuthMode(mode) {
				mode = "xc"
			}
			in.AuthMode, in.Username = &mode, &uname
			in.XcPassword, in.WebPassword, in.APIKey = &sec.XcPassword, &sec.WebPassword, &sec.APIKey
			if _, err := a.upsertAssignment(sid, target.ID, in); err != nil {
				writeInternal(w, a, "copy server assign", err)
				return
			}
			counts["servers"]++
		}
	}

	if want(req.Settings) {
		recs, err := a.userRecords(src.ID, "settings")
		if err != nil {
			writeInternal(w, a, "copy settings", err)
			return
		}
		vals := map[string]json.RawMessage{}
		for _, rcd := range recs {
			raw, ok := rcd.data["value"]
			if !ok {
				continue
			}
			if v, err := validateSettingValue(rcd.id, raw); err == nil {
				vals[rcd.id] = v
			}
		}
		if err := a.setManagedSettings(target.ID, vals); err != nil {
			writeInternal(w, a, "copy settings", err)
			return
		}
		counts["settings"] = len(vals)
	}

	if _, err := a.reconcileUser(target.ID); err != nil {
		writeInternal(w, a, "copy reconcile", err)
		return
	}
	a.auditAdmin(p, "admin.copy", fmt.Sprintf("copied %d addon(s), %d server(s), %d setting(s) from %s to %s",
		counts["addons"], counts["servers"], counts["settings"], src.Username, target.Username))
	writeJSON(w, http.StatusOK, counts)
}

// ---- assignments when creating a user -----------------------------------------------------------------

type newUserServer struct {
	ServerID    string `json:"serverId"`
	AuthMode    string `json:"authMode"`
	Username    string `json:"username"`
	XcPassword  string `json:"xcPassword"`
	WebPassword string `json:"webPassword"`
	APIKey      string `json:"apiKey"`
}

// validateNewUserAssignments checks the optional assignments of POST /api/users.
func (a *App) validateNewUserAssignments(servers []newUserServer, addons []string) (string, error) {
	for i, s := range servers {
		var n int
		if err := a.db.QueryRow(`SELECT COUNT(*) FROM dispatcharr_servers WHERE id = ?`, strings.ToLower(s.ServerID)).Scan(&n); err != nil {
			return "", err
		}
		if n == 0 {
			return fmt.Sprintf("dispatcharr[%d]: unknown connection", i), nil
		}
		if s.AuthMode == "" {
			servers[i].AuthMode = "xc"
		}
		in := assignmentInput{AuthMode: &servers[i].AuthMode, Username: &s.Username, XcPassword: &s.XcPassword, WebPassword: &s.WebPassword, APIKey: &s.APIKey}
		if msg := in.validate(); msg != "" {
			return fmt.Sprintf("dispatcharr[%d]: %s", i, msg), nil
		}
	}
	for _, id := range addons {
		var n int
		if err := a.db.QueryRow(`SELECT COUNT(*) FROM addon_library WHERE id = ?`, id).Scan(&n); err != nil {
			return "", err
		}
		if n == 0 {
			return "unknown addon " + id, nil
		}
	}
	return "", nil
}

func (a *App) applyNewUserAssignments(userID string, servers []newUserServer, addons []string) error {
	for _, s := range servers {
		in := assignmentInput{AuthMode: &s.AuthMode, Username: &s.Username, XcPassword: &s.XcPassword, WebPassword: &s.WebPassword, APIKey: &s.APIKey}
		if _, err := a.upsertAssignment(strings.ToLower(s.ServerID), userID, in); err != nil {
			return err
		}
	}
	now := a.nowMs()
	for _, id := range addons {
		if _, err := a.db.Exec(`INSERT OR IGNORE INTO addon_assignments(addon_id, user_id, created_at) VALUES (?, ?, ?)`, id, userID, now); err != nil {
			return err
		}
	}
	if len(servers) == 0 && len(addons) == 0 {
		return nil
	}
	_, err := a.reconcileUser(userID)
	return err
}
