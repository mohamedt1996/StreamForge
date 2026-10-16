package app

import (
	"crypto/subtle"
	"database/sql"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/crypto/bcrypt"
)

// principal is the authenticated caller: a device and the user it belongs to.
type principal struct {
	user      User
	device    Device
	tokenHash string
	ip        string
}

func bearerToken(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if len(h) < 7 || !strings.EqualFold(h[:7], "bearer ") {
		return ""
	}
	return strings.TrimSpace(h[7:])
}

var errUnauthorized = errors.New("unauthorized")

// lookupToken resolves a token hash to its device and user. Disabled users are rejected.
func (a *App) lookupToken(tokenHash string) (*principal, error) {
	var p principal
	var scopes, storedHash string
	var disabled int
	err := a.db.QueryRow(`
		SELECT d.id, d.user_id, d.name, d.platform, d.scopes, d.token_hash, d.created_at, d.last_seen_at, d.last_ip,
		       u.id, u.username, u.role, u.disabled, u.created_at
		FROM devices d JOIN users u ON u.id = d.user_id
		WHERE d.token_hash = ?`, tokenHash).Scan(
		&p.device.ID, &p.device.userID, &p.device.Name, &p.device.Platform, &scopes, &storedHash,
		&p.device.CreatedAt, &p.device.LastSeenAt, &p.device.LastIP,
		&p.user.ID, &p.user.Username, &p.user.Role, &disabled, &p.user.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, errUnauthorized
	}
	if err != nil {
		return nil, err
	}
	// The lookup is by hash (an index), but compare in constant time anyway.
	if subtle.ConstantTimeCompare([]byte(storedHash), []byte(tokenHash)) != 1 {
		return nil, errUnauthorized
	}
	p.user.Disabled = disabled != 0
	if p.user.Disabled {
		return nil, errUnauthorized
	}
	p.device.Scopes = splitScopes(scopes)
	p.device.Current = true
	p.tokenHash = tokenHash
	return &p, nil
}

func (a *App) authenticate(r *http.Request) (*principal, error) {
	tok := bearerToken(r)
	if !strings.HasPrefix(tok, "sf_") || len(tok) > 200 {
		return nil, errUnauthorized
	}
	p, err := a.lookupToken(hashToken(tok))
	if err != nil {
		return nil, err
	}
	p.ip = a.clientIP(r)
	// Track last seen (throttled to one write per minute unless the IP changed).
	now := a.nowMs()
	if now-p.device.LastSeenAt > 60_000 || p.device.LastIP != p.ip {
		if _, err := a.db.Exec(`UPDATE devices SET last_seen_at = ?, last_ip = ? WHERE id = ?`, now, p.ip, p.device.ID); err != nil {
			a.log.Printf("update last seen: %v", err)
		}
		p.device.LastSeenAt, p.device.LastIP = now, p.ip
	}
	return p, nil
}

type authedHandler func(w http.ResponseWriter, r *http.Request, p *principal)

func (a *App) authed(h authedHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		p, err := a.authenticate(r)
		if err != nil {
			if errors.Is(err, errUnauthorized) {
				w.Header().Set("WWW-Authenticate", `Bearer realm="streamforge"`)
				writeErr(w, http.StatusUnauthorized, "unauthorized", "missing, invalid or revoked token")
				return
			}
			writeInternal(w, a, "auth", err)
			return
		}
		h(w, r, p)
	}
}

func (a *App) adminOnly(h authedHandler) http.HandlerFunc {
	return a.authed(func(w http.ResponseWriter, r *http.Request, p *principal) {
		if p.user.Role != "admin" {
			writeErr(w, http.StatusForbidden, "admin_required", "administrator role required")
			return
		}
		h(w, r, p)
	})
}

// ---- validation ------------------------------------------------------------------

var (
	usernameRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._@-]{0,63}$`)
	platformRe = regexp.MustCompile(`^[a-z0-9]{1,20}$`)
)

func validateUsername(s string) string {
	if !usernameRe.MatchString(s) {
		return "username must be 1–64 characters: letters, digits, '.', '_', '-', '@'"
	}
	return ""
}

func validatePassword(s string) string {
	if utf8.RuneCountInString(s) < 8 {
		return "password must be at least 8 characters"
	}
	if len(s) > 72 {
		return "password must be at most 72 bytes"
	}
	return ""
}

func validRole(s string) bool { return s == "admin" || s == "member" }

type deviceInput struct {
	Name     string `json:"name"`
	Platform string `json:"platform"`
}

// knownPlatforms are the platforms listed in the protocol; other lowercase identifiers are
// accepted too so newer clients are not locked out.
var knownPlatforms = map[string]string{
	"ios": "iPhone", "ipados": "iPad", "tvos": "Apple TV", "android": "Android",
	"androidtv": "Android TV", "web": "Web admin",
}

func normalizeDevice(in deviceInput) (name, platform string, msg string) {
	platform = strings.ToLower(strings.TrimSpace(in.Platform))
	if platform == "" {
		platform = "unknown"
	}
	if !platformRe.MatchString(platform) {
		return "", "", "device.platform must be one of ios, ipados, tvos, android, androidtv, web"
	}
	name = cleanText(in.Name, 64)
	if name == "" {
		if n, ok := knownPlatforms[platform]; ok {
			name = n
		} else {
			name = "Device"
		}
	}
	return name, platform, ""
}

// ---- handlers: setup, login, signup, logout, me --------------------------------

type loginResponse struct {
	Token  string `json:"token"`
	User   User   `json:"user"`
	Device Device `json:"device"`
}

func (a *App) handleSetupStatus(w http.ResponseWriter, r *http.Request) {
	n, err := a.userCount()
	if err != nil {
		writeInternal(w, a, "setup status", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"needsSetup": n == 0,
		"openSignup": a.cfg.OpenSignup,
		"name":       a.cfg.Name,
		"version":    a.cfg.Version,
	})
}

type credentialsRequest struct {
	Username string      `json:"username"`
	Password string      `json:"password"`
	Device   deviceInput `json:"device"`
}

func (a *App) handleSetup(w http.ResponseWriter, r *http.Request) {
	var req credentialsRequest
	if !decodeJSON(w, r, maxSmallBody, &req) {
		return
	}
	req.Username = strings.TrimSpace(req.Username)
	if msg := validateUsername(req.Username); msg != "" {
		writeErr(w, http.StatusBadRequest, "invalid_username", msg)
		return
	}
	if msg := validatePassword(req.Password); msg != "" {
		writeErr(w, http.StatusBadRequest, "invalid_password", msg)
		return
	}
	if req.Device.Platform == "" {
		req.Device.Platform = "web"
	}
	name, platform, msg := normalizeDevice(req.Device)
	if msg != "" {
		writeErr(w, http.StatusBadRequest, "invalid_device", msg)
		return
	}
	a.setupMu.Lock()
	defer a.setupMu.Unlock()
	n, err := a.userCount()
	if err != nil {
		writeInternal(w, a, "setup", err)
		return
	}
	if n > 0 {
		writeErr(w, http.StatusConflict, "already_setup", "this server is already set up; sign in instead")
		return
	}
	ip := a.clientIP(r)
	u, err := a.createUser(req.Username, req.Password, "admin")
	if err != nil {
		writeInternal(w, a, "setup create user", err)
		return
	}
	d, token, err := a.createDevice(u.ID, name, platform, allScopes, ip)
	if err != nil {
		writeInternal(w, a, "setup create device", err)
		return
	}
	d.Current = true
	a.audit(u.ID, u.Username, d.ID, "setup", "first admin account created", ip)
	writeJSON(w, http.StatusOK, loginResponse{Token: token, User: u, Device: d})
}

func (a *App) handleLogin(w http.ResponseWriter, r *http.Request) {
	var req credentialsRequest
	if !decodeJSON(w, r, maxSmallBody, &req) {
		return
	}
	ip := a.clientIP(r)
	uname := strings.TrimSpace(req.Username)
	key := ip + "|" + strings.ToLower(uname)
	if blocked, retry := a.loginLimiter.blocked(key); blocked {
		writeRateLimited(w, retry)
		return
	}
	if blocked, retry := a.ipLimiter.blocked(ip); blocked {
		writeRateLimited(w, retry)
		return
	}
	name, platform, msg := normalizeDevice(req.Device)
	if msg != "" {
		writeErr(w, http.StatusBadRequest, "invalid_device", msg)
		return
	}
	u, hash, err := a.userByName(uname)
	ok := false
	switch {
	case errors.Is(err, errNotFound) || uname == "":
		// Spend the same time as a real check so usernames can't be probed by timing.
		_ = bcrypt.CompareHashAndPassword(a.dummyHash, []byte(req.Password))
	case err != nil:
		writeInternal(w, a, "login lookup", err)
		return
	default:
		ok = bcrypt.CompareHashAndPassword(hash, []byte(req.Password)) == nil
	}
	if !ok {
		a.loginLimiter.hit(key)
		a.ipLimiter.hit(ip)
		a.audit(u.ID, uname, "", "login.failed", "wrong username or password", ip)
		writeErr(w, http.StatusUnauthorized, "invalid_credentials", "wrong username or password")
		return
	}
	if u.Disabled {
		a.audit(u.ID, u.Username, "", "login.failed", "account disabled", ip)
		writeErr(w, http.StatusForbidden, "account_disabled", "this account is disabled")
		return
	}
	a.loginLimiter.reset(key)
	d, token, err := a.createDevice(u.ID, name, platform, allScopes, ip)
	if err != nil {
		writeInternal(w, a, "login create device", err)
		return
	}
	d.Current = true
	a.audit(u.ID, u.Username, d.ID, "login", fmt.Sprintf("signed in on %s (%s)", d.Name, d.Platform), ip)
	writeJSON(w, http.StatusOK, loginResponse{Token: token, User: u, Device: d})
}

func (a *App) handleSignup(w http.ResponseWriter, r *http.Request) {
	if !a.cfg.OpenSignup {
		writeErr(w, http.StatusForbidden, "signup_disabled", "open sign-up is disabled; ask an admin for an account")
		return
	}
	ip := a.clientIP(r)
	if ok, retry := a.pairLimiter.allow("signup|" + ip); !ok {
		writeRateLimited(w, retry)
		return
	}
	var req credentialsRequest
	if !decodeJSON(w, r, maxSmallBody, &req) {
		return
	}
	req.Username = strings.TrimSpace(req.Username)
	if msg := validateUsername(req.Username); msg != "" {
		writeErr(w, http.StatusBadRequest, "invalid_username", msg)
		return
	}
	if msg := validatePassword(req.Password); msg != "" {
		writeErr(w, http.StatusBadRequest, "invalid_password", msg)
		return
	}
	name, platform, msg := normalizeDevice(req.Device)
	if msg != "" {
		writeErr(w, http.StatusBadRequest, "invalid_device", msg)
		return
	}
	u, err := a.createUser(req.Username, req.Password, "member")
	if errors.Is(err, errUsernameTaken) {
		writeErr(w, http.StatusConflict, "username_taken", "that username is taken")
		return
	}
	if err != nil {
		writeInternal(w, a, "signup", err)
		return
	}
	d, token, err := a.createDevice(u.ID, name, platform, allScopes, ip)
	if err != nil {
		writeInternal(w, a, "signup device", err)
		return
	}
	d.Current = true
	a.audit(u.ID, u.Username, d.ID, "signup", fmt.Sprintf("account created on %s (%s)", d.Name, d.Platform), ip)
	writeJSON(w, http.StatusOK, loginResponse{Token: token, User: u, Device: d})
}

func (a *App) handleLogout(w http.ResponseWriter, r *http.Request, p *principal) {
	if err := a.deleteDevice(p.device.ID); err != nil {
		writeInternal(w, a, "logout", err)
		return
	}
	a.hub.notify(p.user.ID) // wake this device's long polls so they fail fast
	a.audit(p.user.ID, p.user.Username, p.device.ID, "logout", fmt.Sprintf("signed out %s", p.device.Name), p.ip)
	w.WriteHeader(http.StatusNoContent)
}

func (a *App) handleMe(w http.ResponseWriter, r *http.Request, p *principal) {
	writeJSON(w, http.StatusOK, map[string]any{
		"user":   p.user,
		"device": p.device,
		"server": map[string]any{"name": a.cfg.Name, "version": a.cfg.Version},
	})
}

func (a *App) handleChangePassword(w http.ResponseWriter, r *http.Request, p *principal) {
	var req struct {
		Current string `json:"current"`
		New     string `json:"new"`
	}
	if !decodeJSON(w, r, maxSmallBody, &req) {
		return
	}
	key := "pw|" + p.user.ID
	if blocked, retry := a.pwLimiter.blocked(key); blocked {
		writeRateLimited(w, retry)
		return
	}
	hash, err := a.passHash(p.user.ID)
	if err != nil {
		writeInternal(w, a, "password lookup", err)
		return
	}
	if bcrypt.CompareHashAndPassword(hash, []byte(req.Current)) != nil {
		a.pwLimiter.hit(key)
		a.audit(p.user.ID, p.user.Username, p.device.ID, "password.failed", "wrong current password", p.ip)
		// 403, not 401: a 401 would make clients sign out.
		writeErr(w, http.StatusForbidden, "wrong_password", "current password is wrong")
		return
	}
	if msg := validatePassword(req.New); msg != "" {
		writeErr(w, http.StatusBadRequest, "invalid_password", msg)
		return
	}
	if err := a.setPassword(p.user.ID, req.New); err != nil {
		writeInternal(w, a, "set password", err)
		return
	}
	a.pwLimiter.reset(key)
	a.audit(p.user.ID, p.user.Username, p.device.ID, "password.change", "password changed", p.ip)
	w.WriteHeader(http.StatusNoContent)
}

// ---- pairing ------------------------------------------------------------------------

func (a *App) handlePairStart(w http.ResponseWriter, r *http.Request) {
	ip := a.clientIP(r)
	if ok, retry := a.pairLimiter.allow("pair|" + ip); !ok {
		writeRateLimited(w, retry)
		return
	}
	var req struct {
		Device deviceInput `json:"device"`
	}
	if !decodeJSON(w, r, maxSmallBody, &req) {
		return
	}
	name, platform, msg := normalizeDevice(req.Device)
	if msg != "" {
		writeErr(w, http.StatusBadRequest, "invalid_device", msg)
		return
	}
	now := a.now()
	p, err := a.pairs.start(name, platform, ip, now, now.Add(pairTTL))
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "busy", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"pairId":    p.id,
		"code":      p.code,
		"expiresIn": int(pairTTL / time.Second),
	})
}

func (a *App) handlePairPoll(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("pairId")
	res := a.pairs.poll(id, a.now())
	switch res.status {
	case "pending":
		writeJSON(w, http.StatusAccepted, map[string]any{"status": "pending"})
	case "approved":
		// The device may have been revoked between approval and pickup.
		if _, err := a.lookupToken(hashToken(res.token)); err != nil {
			writeErr(w, http.StatusGone, "expired", "pairing was revoked")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"status": "approved",
			"token":  res.token,
			"user":   res.user,
			"device": res.device,
		})
	default:
		writeErr(w, http.StatusGone, "expired", "pairing code expired or was not approved")
	}
}

func (a *App) handlePairApprove(w http.ResponseWriter, r *http.Request, p *principal) {
	var req struct {
		Code   string    `json:"code"`
		Scopes *[]string `json:"scopes"`
	}
	if !decodeJSON(w, r, maxSmallBody, &req) {
		return
	}
	key := "code|" + p.user.ID
	if blocked, retry := a.codeLimiter.blocked(key); blocked {
		writeRateLimited(w, retry)
		return
	}
	// Also budget wrong codes per IP, so many accounts (open sign-up) can't pool their guesses.
	ipKey := "code|" + p.ip
	if blocked, retry := a.ipLimiter.blocked(ipKey); blocked {
		writeRateLimited(w, retry)
		return
	}
	scopes := p.device.Scopes
	if req.Scopes != nil {
		s, ok := normalizeScopes(*req.Scopes)
		if !ok {
			writeErr(w, http.StatusBadRequest, "invalid_scopes", "scopes must be read, write and/or secrets")
			return
		}
		scopes = s
	}
	if len(scopes) == 0 {
		writeErr(w, http.StatusBadRequest, "invalid_scopes", "grant at least one scope")
		return
	}
	if !subsetOf(scopes, p.device.Scopes) {
		writeErr(w, http.StatusForbidden, "scope_escalation", "you can only grant scopes this device has itself")
		return
	}
	code, ok := normalizePairCode(req.Code)
	if !ok {
		a.codeLimiter.hit(key)
		a.ipLimiter.hit(ipKey)
		writeErr(w, http.StatusNotFound, "invalid_code", "unknown pairing code")
		return
	}
	d, status, err := a.pairs.approve(code, a.now(), func(pr *pairing) (Device, string, error) {
		return a.createDevice(p.user.ID, pr.name, pr.platform, scopes, pr.ip)
	}, p.user)
	switch {
	case err != nil:
		writeInternal(w, a, "pair approve", err)
		return
	case status == "not_found":
		a.codeLimiter.hit(key)
		a.ipLimiter.hit(ipKey)
		writeErr(w, http.StatusNotFound, "invalid_code", "unknown pairing code")
		return
	case status == "expired":
		writeErr(w, http.StatusGone, "expired", "pairing code expired; start pairing again on the TV")
		return
	case status == "used":
		writeErr(w, http.StatusConflict, "already_approved", "this code was already approved")
		return
	}
	a.audit(p.user.ID, p.user.Username, d.ID, "pair.approve",
		fmt.Sprintf("paired %s (%s) with %s", d.Name, d.Platform, joinScopes(d.Scopes)), p.ip)
	writeJSON(w, http.StatusOK, map[string]any{"device": d})
}
