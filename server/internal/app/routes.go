package app

import (
	"embed"
	"io/fs"
	"net/http"
	"strings"
)

//go:embed web
var webFS embed.FS

func (a *App) routes() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		if err := a.db.PingContext(r.Context()); err != nil {
			http.Error(w, "database unavailable", http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write([]byte("ok"))
	})

	// First run / sign-up (extensions used by the web admin).
	mux.HandleFunc("GET /api/setup", a.handleSetupStatus)
	mux.HandleFunc("POST /api/setup", a.handleSetup)
	mux.HandleFunc("POST /api/auth/signup", a.handleSignup)

	// Auth
	mux.HandleFunc("POST /api/auth/login", a.handleLogin)
	mux.HandleFunc("POST /api/auth/pair/start", a.handlePairStart)
	mux.HandleFunc("GET /api/auth/pair/{pairId}", a.handlePairPoll)
	mux.HandleFunc("POST /api/auth/logout", a.authed(a.handleLogout))
	mux.HandleFunc("POST /api/pair/approve", a.authed(a.handlePairApprove))

	// Me
	mux.HandleFunc("GET /api/me", a.authed(a.handleMe))
	mux.HandleFunc("POST /api/me/password", a.authed(a.handleChangePassword))

	// Devices
	mux.HandleFunc("GET /api/devices", a.authed(a.handleListDevices))
	mux.HandleFunc("PATCH /api/devices/{id}", a.authed(a.handlePatchDevice))
	mux.HandleFunc("DELETE /api/devices/{id}", a.authed(a.handleDeleteDevice))

	// Users (admin)
	mux.HandleFunc("GET /api/users", a.adminOnly(a.handleListUsers))
	mux.HandleFunc("POST /api/users", a.adminOnly(a.handleCreateUser))
	mux.HandleFunc("PATCH /api/users/{id}", a.adminOnly(a.handlePatchUser))
	mux.HandleFunc("DELETE /api/users/{id}", a.adminOnly(a.handleDeleteUser))

	// Sync
	mux.HandleFunc("GET /api/sync", a.authed(a.handlePull))
	mux.HandleFunc("POST /api/sync", a.authed(a.handlePush))

	// Web admin helpers (extensions)
	mux.HandleFunc("GET /api/stats", a.authed(a.handleStats))
	mux.HandleFunc("GET /api/audit", a.authed(a.handleAudit))

	mux.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) {
		writeErr(w, http.StatusNotFound, "not_found", "no such endpoint")
	})

	// Web admin (static, embedded).
	static, _ := fs.Sub(webFS, "web")
	fileServer := http.FileServerFS(static)
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		setPageHeaders(w)
		http.ServeFileFS(w, r, static, "index.html")
	})
	for _, f := range []string{"app.js", "app.css", "icon.svg"} {
		mux.HandleFunc("GET /"+f, func(w http.ResponseWriter, r *http.Request) {
			setPageHeaders(w)
			fileServer.ServeHTTP(w, r)
		})
	}

	return commonHeaders(mux)
}

const csp = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; " +
	"connect-src 'self'; font-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"

func setPageHeaders(w http.ResponseWriter) {
	h := w.Header()
	h.Set("Content-Security-Policy", csp)
	h.Set("X-Frame-Options", "DENY")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), interest-cohort=()")
	h.Set("Cross-Origin-Opener-Policy", "same-origin")
	h.Set("Cache-Control", "no-cache")
}

// commonHeaders adds headers that apply to every response.
func commonHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		if strings.HasPrefix(r.URL.Path, "/api/") {
			h.Set("Cache-Control", "no-store")
			h.Set("X-Frame-Options", "DENY")
		}
		next.ServeHTTP(w, r)
	})
}
