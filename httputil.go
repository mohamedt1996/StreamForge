package app

import (
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

type apiError struct {
	Error string `json:"error"`
	Code  string `json:"code"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	h := w.Header()
	h.Set("Content-Type", "application/json; charset=utf-8")
	h.Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, apiError{Error: msg, Code: code})
}

func writeInternal(w http.ResponseWriter, a *App, where string, err error) {
	a.log.Printf("internal error (%s): %v", where, err)
	writeErr(w, http.StatusInternalServerError, "internal", "internal server error")
}

// decodeJSON reads a size-limited JSON body into v. On failure it writes the error response
// and returns false.
func decodeJSON(w http.ResponseWriter, r *http.Request, max int64, v any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, max)
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(v); err != nil {
		var mbe *http.MaxBytesError
		switch {
		case errors.As(err, &mbe):
			writeErr(w, http.StatusRequestEntityTooLarge, "too_large", "request body too large")
		case errors.Is(err, io.EOF):
			writeErr(w, http.StatusBadRequest, "bad_request", "request body is empty")
		default:
			writeErr(w, http.StatusBadRequest, "bad_request", "invalid JSON body")
		}
		return false
	}
	// Reject trailing garbage (but allow whitespace).
	if dec.More() {
		writeErr(w, http.StatusBadRequest, "bad_request", "invalid JSON body")
		return false
	}
	return true
}

// clientIP returns the caller's IP. With TrustProxy, the right-most X-Forwarded-For entry
// (the address the nearest proxy saw) is used, which cannot be spoofed by the client.
func (a *App) clientIP(r *http.Request) string {
	if a.cfg.TrustProxy {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			for i := len(parts) - 1; i >= 0; i-- {
				ip := strings.TrimSpace(parts[i])
				if net.ParseIP(ip) != nil {
					return ip
				}
			}
		}
		if xr := strings.TrimSpace(r.Header.Get("X-Real-IP")); net.ParseIP(xr) != nil {
			return xr
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// cleanText trims, strips control characters and caps length (runes).
func cleanText(s string, max int) string {
	s = strings.ToValidUTF8(strings.TrimSpace(s), "")
	s = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, s)
	if utf8.RuneCountInString(s) > max {
		s = string([]rune(s)[:max])
	}
	return s
}

// ---- rate limiter --------------------------------------------------------------

// limiter is a fixed-window failure counter keyed by string.
type limiter struct {
	mu     sync.Mutex
	max    int
	window time.Duration
	now    func() time.Time
	m      map[string]*bucket
}

type bucket struct {
	count int
	start time.Time
}

func newLimiter(max int, window time.Duration, now func() time.Time) *limiter {
	return &limiter{max: max, window: window, now: now, m: map[string]*bucket{}}
}

// blocked reports whether key has used up its budget, and when it may retry.
func (l *limiter) blocked(key string) (bool, time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	b, ok := l.m[key]
	if !ok {
		return false, 0
	}
	now := l.now()
	if now.Sub(b.start) >= l.window {
		delete(l.m, key)
		return false, 0
	}
	if b.count >= l.max {
		return true, b.start.Add(l.window).Sub(now)
	}
	return false, 0
}

// hit records one attempt/failure for key.
func (l *limiter) hit(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	b, ok := l.m[key]
	if !ok || now.Sub(b.start) >= l.window {
		l.m[key] = &bucket{count: 1, start: now}
		return
	}
	b.count++
}

// allow records an attempt and reports whether it is within budget.
func (l *limiter) allow(key string) (bool, time.Duration) {
	if blocked, retry := l.blocked(key); blocked {
		return false, retry
	}
	l.hit(key)
	return true, 0
}

func (l *limiter) reset(key string) {
	l.mu.Lock()
	delete(l.m, key)
	l.mu.Unlock()
}

func (l *limiter) cleanup() {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	for k, b := range l.m {
		if now.Sub(b.start) >= l.window {
			delete(l.m, k)
		}
	}
}

func writeRateLimited(w http.ResponseWriter, retry time.Duration) {
	secs := int(retry.Round(time.Second) / time.Second)
	if secs < 1 {
		secs = 1
	}
	w.Header().Set("Retry-After", strconv.Itoa(secs))
	writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many attempts, try again later")
}

// ---- long-poll hub -------------------------------------------------------------

// hub is a per-user broadcast: waiters grab the user's current channel, and a push closes
// it (waking every waiter) and drops it so the next waiter gets a fresh one.
type hub struct {
	mu    sync.Mutex
	chans map[string]chan struct{}
}

func newHub() *hub { return &hub{chans: map[string]chan struct{}{}} }

func (h *hub) subscribe(userID string) <-chan struct{} {
	h.mu.Lock()
	defer h.mu.Unlock()
	c, ok := h.chans[userID]
	if !ok {
		c = make(chan struct{})
		h.chans[userID] = c
	}
	return c
}

func (h *hub) notify(userID string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if c, ok := h.chans[userID]; ok {
		close(c)
		delete(h.chans, userID)
	}
}
