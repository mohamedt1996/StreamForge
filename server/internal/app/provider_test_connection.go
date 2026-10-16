package app

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Probe only saved assignments. Never follow redirects with stored credentials, or return
// upstream bodies/errors (which can echo passwords, API keys, or credential-bearing URLs).
func (a *App) handleTestProvider(w http.ResponseWriter, r *http.Request, p *principal) {
	if !backupAccess(w, p) {
		return
	}
	var base, mode, username, sealed string
	err := a.db.QueryRow(`SELECT s.url,x.auth_mode,x.username,x.secret FROM dispatcharr_servers s JOIN dispatcharr_assignments x ON x.server_id=s.id WHERE s.id=? AND x.user_id=?`, r.PathValue("id"), r.PathValue("userId")).Scan(&base, &mode, &username, &sealed)
	if err != nil {
		writeErr(w, 404, "not_found", "saved assignment not found")
		return
	}
	secret, err := a.openAssignment(r.PathValue("userId"), r.PathValue("id"), sealed)
	if err != nil {
		writeErr(w, 400, "credentials_unreadable", "save credentials again before testing")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()
	target := strings.TrimRight(base, "/")
	method := "GET"
	var body io.Reader
	switch mode {
	case "xc":
		target += "/player_api.php?" + url.Values{"username": {username}, "password": {secret.XcPassword}}.Encode()
	case "web":
		target += "/api/accounts/token/"
		method = "POST"
		b, _ := json.Marshal(map[string]string{"username": username, "password": secret.WebPassword})
		body = bytes.NewReader(b)
	case "apiKey":
		target += "/api/channels/profiles/"
	default:
		writeErr(w, 400, "invalid_auth", "unknown authentication mode")
		return
	}
	req, err := http.NewRequestWithContext(ctx, method, target, body)
	if err != nil {
		writeErr(w, 400, "invalid_url", "invalid provider URL")
		return
	}
	req.Header.Set("Accept", "application/json")
	if mode == "web" {
		req.Header.Set("Content-Type", "application/json")
	}
	if mode == "apiKey" {
		req.Header.Set("X-API-Key", secret.APIKey)
	}
	client := *a.httpClient
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	start := time.Now()
	res, err := client.Do(req)
	ok := false
	message := "Could not connect. Check the server address and network."
	if err == nil {
		defer res.Body.Close()
		data, readErr := io.ReadAll(io.LimitReader(res.Body, 1<<20+1))
		switch {
		case res.StatusCode == 401 || res.StatusCode == 403:
			message = "Credentials rejected or access denied."
		case res.StatusCode >= 300 && res.StatusCode < 400:
			message = "Provider redirected the request. Save its final URL and test again."
		case res.StatusCode < 200 || res.StatusCode >= 300:
			message = "Provider returned an unsuccessful HTTP response."
		case readErr != nil || len(data) > 1<<20:
			message = "Provider response was incomplete or too large."
		default:
			var obj map[string]json.RawMessage
			if mode == "apiKey" {
				ok = json.Valid(data)
			} else if json.Unmarshal(data, &obj) == nil {
				if mode == "web" {
					var access string
					_ = json.Unmarshal(obj["access"], &access)
					ok = access != ""
				} else {
					var user struct {
						Auth json.RawMessage `json:"auth"`
					}
					_ = json.Unmarshal(obj["user_info"], &user)
					ok = string(user.Auth) == "1" || string(user.Auth) == `"1"`
				}
			}
			if ok {
				message = "Connected and authenticated."
			} else {
				message = "Provider responded, but authentication could not be verified."
			}
		}
	} else if ctx.Err() != nil {
		message = "Connection timed out after 8 seconds."
	}
	a.auditAdmin(p, "provider_test", r.PathValue("id"))
	writeJSON(w, 200, map[string]any{"ok": ok, "message": message, "latencyMs": time.Since(start).Milliseconds(), "checkedAt": a.nowMs()})
}
