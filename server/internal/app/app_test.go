package app

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"
)

// ---- harness --------------------------------------------------------------------------

type clock struct {
	mu     sync.Mutex
	offset time.Duration
}

func (c *clock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return time.Now().Add(c.offset)
}

func (c *clock) Advance(d time.Duration) {
	c.mu.Lock()
	c.offset += d
	c.mu.Unlock()
}

type testEnv struct {
	t     *testing.T
	app   *App
	srv   *httptest.Server
	dir   string
	clock *clock
}

func newTestEnv(t *testing.T, mods ...func(*Config)) *testEnv {
	t.Helper()
	dir := t.TempDir()
	c := &clock{}
	cfg := Config{
		DataDir:    dir,
		Name:       "Test Server",
		Version:    "1.0.0-test",
		BcryptCost: bcrypt.MinCost,
		Now:        c.Now,
		Logger:     log.New(io.Discard, "", 0),
	}
	for _, m := range mods {
		m(&cfg)
	}
	a, err := New(cfg)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	srv := httptest.NewServer(a.Handler())
	t.Cleanup(func() {
		srv.Close()
		a.Close()
	})
	return &testEnv{t: t, app: a, srv: srv, dir: dir, clock: c}
}

type resp struct {
	status int
	header http.Header
	body   []byte
}

func (r resp) json(t *testing.T, v any) {
	t.Helper()
	if err := json.Unmarshal(r.body, v); err != nil {
		t.Fatalf("decode %q: %v", r.body, err)
	}
}

func (r resp) code(t *testing.T) string {
	var e apiError
	_ = json.Unmarshal(r.body, &e)
	return e.Code
}

func (e *testEnv) doCtx(ctx context.Context, method, path, token string, body any) (resp, error) {
	var rdr io.Reader
	switch b := body.(type) {
	case nil:
	case []byte:
		rdr = bytes.NewReader(b)
	case string:
		rdr = strings.NewReader(b)
	default:
		buf, err := json.Marshal(b)
		if err != nil {
			return resp{}, err
		}
		rdr = bytes.NewReader(buf)
	}
	req, err := http.NewRequestWithContext(ctx, method, e.srv.URL+path, rdr)
	if err != nil {
		return resp{}, err
	}
	if rdr != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := e.srv.Client().Do(req)
	if err != nil {
		return resp{}, err
	}
	defer res.Body.Close()
	b, err := io.ReadAll(res.Body)
	return resp{status: res.StatusCode, header: res.Header, body: b}, err
}

func (e *testEnv) do(method, path, token string, body any) resp {
	e.t.Helper()
	r, err := e.doCtx(context.Background(), method, path, token, body)
	if err != nil {
		e.t.Fatalf("%s %s: %v", method, path, err)
	}
	return r
}

func (e *testEnv) expect(r resp, status int) resp {
	e.t.Helper()
	if r.status != status {
		e.t.Fatalf("expected status %d, got %d: %s", status, r.status, r.body)
	}
	return r
}

func device(name, platform string) map[string]string {
	return map[string]string{"name": name, "platform": platform}
}

func (e *testEnv) setupAdmin() loginResponse {
	e.t.Helper()
	r := e.expect(e.do("POST", "/api/setup", "", map[string]any{
		"username": "admin", "password": "correct horse", "device": device("Browser", "web"),
	}), 200)
	var lr loginResponse
	r.json(e.t, &lr)
	return lr
}

func (e *testEnv) login(user, pass, platform string) loginResponse {
	e.t.Helper()
	r := e.expect(e.do("POST", "/api/auth/login", "", map[string]any{
		"username": user, "password": pass, "device": device(user+"'s "+platform, platform),
	}), 200)
	var lr loginResponse
	r.json(e.t, &lr)
	return lr
}

// pairTV runs the whole pairing flow and returns the TV's token.
func (e *testEnv) pairTV(approver string, scopes []string) (string, Device) {
	e.t.Helper()
	var start struct {
		PairID    string `json:"pairId"`
		Code      string `json:"code"`
		ExpiresIn int    `json:"expiresIn"`
	}
	e.expect(e.do("POST", "/api/auth/pair/start", "", map[string]any{"device": device("Living room TV", "tvos")}), 200).json(e.t, &start)
	e.expect(e.do("POST", "/api/pair/approve", approver, map[string]any{"code": start.Code, "scopes": scopes}), 200)
	var poll struct {
		Status string `json:"status"`
		Token  string `json:"token"`
		Device Device `json:"device"`
	}
	e.expect(e.do("GET", "/api/auth/pair/"+start.PairID, "", nil), 200).json(e.t, &poll)
	return poll.Token, poll.Device
}

type rec = map[string]any

func (e *testEnv) push(token string, records ...rec) (int64, []pushResult) {
	e.t.Helper()
	r := e.expect(e.do("POST", "/api/sync", token, map[string]any{"records": records}), 200)
	var out struct {
		Rev     int64        `json:"rev"`
		Results []pushResult `json:"results"`
	}
	r.json(e.t, &out)
	return out.Rev, out.Results
}

func (e *testEnv) pull(token string, query string) pullResponse {
	e.t.Helper()
	r := e.expect(e.do("GET", "/api/sync?"+query, token, nil), 200)
	var out pullResponse
	r.json(e.t, &out)
	return out
}

// ---- tests ------------------------------------------------------------------------------

func TestHealthzAndWebAdmin(t *testing.T) {
	e := newTestEnv(t)
	r := e.expect(e.do("GET", "/healthz", "", nil), 200)
	if string(r.body) != "ok" {
		t.Fatalf("healthz body %q", r.body)
	}
	r = e.expect(e.do("GET", "/", "", nil), 200)
	if !strings.Contains(r.header.Get("Content-Security-Policy"), "default-src 'none'") {
		t.Fatalf("missing CSP: %v", r.header)
	}
	if r.header.Get("X-Frame-Options") != "DENY" || r.header.Get("X-Content-Type-Options") != "nosniff" {
		t.Fatalf("missing security headers: %v", r.header)
	}
	if !strings.Contains(string(r.body), "<html") {
		t.Fatalf("index is not HTML")
	}
	e.expect(e.do("GET", "/app.js", "", nil), 200)
	e.expect(e.do("GET", "/app.css", "", nil), 200)
	if r := e.expect(e.do("GET", "/api/nope", "", nil), 404); r.code(t) != "not_found" {
		t.Fatalf("expected JSON 404")
	}
}

func TestSetupLoginMe(t *testing.T) {
	e := newTestEnv(t)
	var st map[string]any
	e.expect(e.do("GET", "/api/setup", "", nil), 200).json(t, &st)
	if st["needsSetup"] != true {
		t.Fatalf("needsSetup should be true: %v", st)
	}
	// Login before setup fails.
	e.expect(e.do("POST", "/api/auth/login", "", map[string]any{"username": "admin", "password": "correct horse"}), 401)

	admin := e.setupAdmin()
	if !strings.HasPrefix(admin.Token, "sf_") || admin.User.Role != "admin" || !admin.Device.Current {
		t.Fatalf("bad setup response: %+v", admin)
	}
	if got := strings.Join(admin.Device.Scopes, ","); got != "read,write,secrets" {
		t.Fatalf("scopes %q", got)
	}
	e.expect(e.do("GET", "/api/setup", "", nil), 200).json(t, &st)
	if st["needsSetup"] != false {
		t.Fatalf("needsSetup should be false")
	}
	// Second setup is refused.
	r := e.expect(e.do("POST", "/api/setup", "", map[string]any{"username": "evil", "password": "12345678"}), 409)
	if r.code(t) != "already_setup" {
		t.Fatalf("code %q", r.code(t))
	}

	if r := e.expect(e.do("POST", "/api/auth/login", "", map[string]any{"username": "admin", "password": "wrong!!!!", "device": device("x", "ios")}), 401); r.code(t) != "invalid_credentials" {
		t.Fatalf("code %q", r.code(t))
	}
	e.expect(e.do("POST", "/api/auth/login", "", map[string]any{"username": "nobody", "password": "whatever1", "device": device("x", "ios")}), 401)

	phone := e.login("ADMIN", "correct horse", "ios") // usernames are case-insensitive
	var me struct {
		User   User   `json:"user"`
		Device Device `json:"device"`
		Server struct {
			Name    string `json:"name"`
			Version string `json:"version"`
		} `json:"server"`
	}
	e.expect(e.do("GET", "/api/me", phone.Token, nil), 200).json(t, &me)
	if me.User.Username != "admin" || me.Device.ID != phone.Device.ID || !me.Device.Current || me.Server.Name != "Test Server" || me.Server.Version != "1.0.0-test" {
		t.Fatalf("bad /api/me: %+v", me)
	}
	if me.Device.Platform != "ios" {
		t.Fatalf("platform %q", me.Device.Platform)
	}
	// Bad tokens.
	e.expect(e.do("GET", "/api/me", "", nil), 401)
	e.expect(e.do("GET", "/api/me", "sf_nope", nil), 401)
	e.expect(e.do("GET", "/api/me", "garbage", nil), 401)

	// Token is stored hashed, never in plaintext.
	var stored string
	if err := e.app.db.QueryRow(`SELECT token_hash FROM devices WHERE id = ?`, phone.Device.ID).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if stored == phone.Token || stored != hashToken(phone.Token) {
		t.Fatalf("token not stored as SHA-256")
	}

	// Logout revokes the calling device only.
	e.expect(e.do("POST", "/api/auth/logout", phone.Token, nil), 204)
	e.expect(e.do("GET", "/api/me", phone.Token, nil), 401)
	e.expect(e.do("GET", "/api/me", admin.Token, nil), 200)
}

func TestEnvBootstrap(t *testing.T) {
	e := newTestEnv(t, func(c *Config) { c.AdminUser = "boss"; c.AdminPassword = "s3cretpass" })
	var st map[string]any
	e.expect(e.do("GET", "/api/setup", "", nil), 200).json(t, &st)
	if st["needsSetup"] != false {
		t.Fatalf("env bootstrap should complete setup")
	}
	lr := e.login("boss", "s3cretpass", "android")
	if lr.User.Role != "admin" {
		t.Fatalf("role %q", lr.User.Role)
	}
}

func TestLoginRateLimit(t *testing.T) {
	e := newTestEnv(t)
	e.setupAdmin()
	for i := 0; i < 10; i++ {
		e.expect(e.do("POST", "/api/auth/login", "", map[string]any{"username": "admin", "password": "wrong-password"}), 401)
	}
	r := e.expect(e.do("POST", "/api/auth/login", "", map[string]any{"username": "admin", "password": "correct horse"}), 429)
	if r.header.Get("Retry-After") == "" || r.code(t) != "rate_limited" {
		t.Fatalf("missing Retry-After / code: %v %s", r.header, r.body)
	}
	e.clock.Advance(16 * time.Minute)
	e.login("admin", "correct horse", "ios")
}

func TestScopesEnforced(t *testing.T) {
	e := newTestEnv(t)
	admin := e.setupAdmin()

	readOnly, _ := e.pairTV(admin.Token, []string{"read"})
	writeOnly, _ := e.pairTV(admin.Token, []string{"write"})

	r := e.expect(e.do("POST", "/api/sync", readOnly, map[string]any{"records": []rec{{"collection": "progress", "id": "a", "data": rec{"x": 1}, "updatedAt": 1}}}), 403)
	if r.code(t) != "scope_missing" {
		t.Fatalf("code %q", r.code(t))
	}
	e.expect(e.do("GET", "/api/sync?since=0", readOnly, nil), 200)

	e.expect(e.do("GET", "/api/sync?since=0", writeOnly, nil), 403)
	e.push(writeOnly, rec{"collection": "progress", "id": "a", "data": rec{"x": 1}, "updatedAt": 1})

	// A restricted device cannot escalate itself or grant more than it has.
	var me struct{ Device Device }
	e.expect(e.do("GET", "/api/me", readOnly, nil), 200).json(t, &me)
	if r := e.expect(e.do("PATCH", "/api/devices/"+me.Device.ID, readOnly, map[string]any{"scopes": []string{"read", "secrets"}}), 403); r.code(t) != "scope_escalation" {
		t.Fatalf("code %q", r.code(t))
	}
	var start struct{ Code string }
	e.expect(e.do("POST", "/api/auth/pair/start", "", map[string]any{"device": device("TV2", "androidtv")}), 200).json(t, &start)
	e.expect(e.do("POST", "/api/pair/approve", readOnly, map[string]any{"code": start.Code, "scopes": []string{"read", "write"}}), 403)

	// Admin (full scopes) can re-scope the TV; it then may push.
	var patched Device
	e.expect(e.do("PATCH", "/api/devices/"+me.Device.ID, admin.Token, map[string]any{"scopes": []string{"write", "read", "read"}, "name": "  Bedroom TV "}), 200).json(t, &patched)
	if strings.Join(patched.Scopes, ",") != "read,write" || patched.Name != "Bedroom TV" {
		t.Fatalf("patched %+v", patched)
	}
	e.push(readOnly, rec{"collection": "progress", "id": "b", "data": rec{"x": 2}, "updatedAt": 1})
	e.expect(e.do("PATCH", "/api/devices/"+me.Device.ID, admin.Token, map[string]any{"scopes": []string{"bogus"}}), 400)
	e.expect(e.do("PATCH", "/api/devices/"+me.Device.ID, admin.Token, map[string]any{"scopes": []string{}}), 400)
}

func TestLWWPushPull(t *testing.T) {
	e := newTestEnv(t)
	admin := e.setupAdmin()
	phone := e.login("admin", "correct horse", "ios")
	tv := e.login("admin", "correct horse", "tvos")

	rev, res := e.push(phone.Token, rec{"collection": "progress", "id": "default|movie:tt1", "data": rec{"position": 10}, "updatedAt": 1000})
	if rev != 1 || res[0].Status != "applied" || res[0].Rev != 1 {
		t.Fatalf("first push: rev=%d %+v", rev, res)
	}
	// Older and equal updatedAt are stale (ties keep the stored copy).
	rev, res = e.push(tv.Token,
		rec{"collection": "progress", "id": "default|movie:tt1", "data": rec{"position": 5}, "updatedAt": 999},
		rec{"collection": "progress", "id": "default|movie:tt1", "data": rec{"position": 6}, "updatedAt": 1000},
	)
	if rev != 1 || res[0].Status != "stale" || res[0].Rev != 1 || res[1].Status != "stale" {
		t.Fatalf("stale push: rev=%d %+v", rev, res)
	}
	// Newer wins.
	rev, res = e.push(tv.Token, rec{"collection": "progress", "id": "default|movie:tt1", "data": rec{"position": 42}, "updatedAt": 2000})
	if rev != 2 || res[0].Status != "applied" || res[0].Rev != 2 {
		t.Fatalf("newer push: rev=%d %+v", rev, res)
	}
	p := e.pull(phone.Token, "since=0")
	if p.Rev != 2 || len(p.Records) != 1 || p.More {
		t.Fatalf("pull: %+v", p)
	}
	got := p.Records[0]
	if got.UpdatedAt != 2000 || got.Rev != 2 || got.Device != tv.Device.ID || string(got.Data) != `{"position":42}` || got.Deleted {
		t.Fatalf("record: %+v data=%s", got, got.Data)
	}
	// Nothing new since 2.
	if p := e.pull(phone.Token, "since=2"); len(p.Records) != 0 || p.Rev != 2 {
		t.Fatalf("empty pull: %+v", p)
	}

	// Tombstone.
	e.push(phone.Token, rec{"collection": "progress", "id": "default|movie:tt1", "deleted": true, "data": rec{"ignored": true}, "updatedAt": 3000})
	p = e.pull(tv.Token, "since=2")
	if len(p.Records) != 1 || !p.Records[0].Deleted || string(p.Records[0].Data) != "null" || p.Rev != 3 {
		t.Fatalf("tombstone pull: %+v", p)
	}
	// Tombstones are removed after 180 days.
	e.clock.Advance(181 * 24 * time.Hour)
	e.app.cleanup()
	if p := e.pull(tv.Token, "since=0"); len(p.Records) != 0 {
		t.Fatalf("tombstone not cleaned: %+v", p)
	}

	// Future timestamps are clamped to now + 5 min.
	far := e.clock.Now().Add(24 * time.Hour).UnixMilli()
	e.push(phone.Token, rec{"collection": "settings", "id": "seekStep", "data": rec{"value": 10}, "updatedAt": far})
	p = e.pull(phone.Token, "since=3")
	if len(p.Records) != 1 || p.Records[0].UpdatedAt > e.clock.Now().Add(5*time.Minute+time.Second).UnixMilli() {
		t.Fatalf("not clamped: %+v", p.Records)
	}

	// Data is per-user: a second user sees nothing.
	e.expect(e.do("POST", "/api/users", admin.Token, map[string]any{"username": "kid", "password": "kidpassword", "role": "member"}), 200)
	kid := e.login("kid", "kidpassword", "android")
	if p := e.pull(kid.Token, "since=0"); len(p.Records) != 0 || p.Rev != 0 {
		t.Fatalf("data leaked across users: %+v", p)
	}
	rev, _ = e.push(kid.Token, rec{"collection": "watched", "id": "default|movie:tt9", "data": rec{"key": "movie:tt9"}, "updatedAt": 5})
	if rev != 1 {
		t.Fatalf("per-user rev should start at 1, got %d", rev)
	}
}

func TestPushValidationAndLimits(t *testing.T) {
	e := newTestEnv(t)
	admin := e.setupAdmin()
	tok := admin.Token
	cases := []struct {
		r    rec
		code string
	}{
		{rec{"collection": "", "id": "a", "data": rec{}, "updatedAt": 1}, "invalid_record"},
		{rec{"collection": "progress", "id": "", "data": rec{}, "updatedAt": 1}, "invalid_record"},
		{rec{"collection": "progress", "id": "a", "data": rec{}, "updatedAt": 0}, "invalid_record"},
		{rec{"collection": "progress", "id": "a", "updatedAt": 1}, "invalid_record"},
	}
	for i, c := range cases {
		if r := e.expect(e.do("POST", "/api/sync", tok, map[string]any{"records": []rec{c.r}}), 400); r.code(t) != c.code {
			t.Fatalf("case %d: code %q", i, r.code(t))
		}
	}
	big := strings.Repeat("x", maxRecordData+10)
	if r := e.expect(e.do("POST", "/api/sync", tok, map[string]any{"records": []rec{{"collection": "progress", "id": "a", "data": rec{"v": big}, "updatedAt": 1}}}), 413); r.code(t) != "record_too_large" {
		t.Fatalf("code %q", r.code(t))
	}
	many := make([]rec, maxPushRecords+1)
	for i := range many {
		many[i] = rec{"collection": "watched", "id": fmt.Sprint(i), "data": rec{"k": i}, "updatedAt": 1}
	}
	e.expect(e.do("POST", "/api/sync", tok, map[string]any{"records": many}), 400)
	huge := `{"records":[{"collection":"progress","id":"a","updatedAt":1,"data":"` + strings.Repeat("y", maxPushBody) + `"}]}`
	e.expect(e.do("POST", "/api/sync", tok, huge), 413)
	e.expect(e.do("POST", "/api/sync", tok, "{not json"), 400)
	// Empty push is fine.
	rev, res := e.push(tok)
	if rev != 0 || len(res) != 0 {
		t.Fatalf("empty push: %d %+v", rev, res)
	}
	e.expect(e.do("GET", "/api/sync?since=abc", tok, nil), 400)
}

func TestPagination(t *testing.T) {
	e := newTestEnv(t)
	admin := e.setupAdmin()
	var recs []rec
	for i := 0; i < 25; i++ {
		recs = append(recs, rec{"collection": "watched", "id": fmt.Sprintf("default|movie:tt%02d", i), "data": rec{"key": i}, "updatedAt": 100 + i})
	}
	rev, _ := e.push(admin.Token, recs...)
	if rev != 25 {
		t.Fatalf("rev %d", rev)
	}
	var all []Record
	since := int64(0)
	pages := 0
	for {
		p := e.pull(admin.Token, fmt.Sprintf("since=%d&limit=10", since))
		pages++
		all = append(all, p.Records...)
		for i := 1; i < len(p.Records); i++ {
			if p.Records[i].Rev <= p.Records[i-1].Rev {
				t.Fatalf("not ordered by rev")
			}
		}
		if p.More {
			if p.Rev != p.Records[len(p.Records)-1].Rev || len(p.Records) != 10 {
				t.Fatalf("page: rev=%d n=%d", p.Rev, len(p.Records))
			}
		}
		since = p.Rev
		if !p.More {
			break
		}
		if pages > 5 {
			t.Fatal("too many pages")
		}
	}
	if len(all) != 25 || pages != 3 || since != 25 {
		t.Fatalf("got %d records over %d pages, final rev %d", len(all), pages, since)
	}
}

func TestLongPollWakesOnPush(t *testing.T) {
	e := newTestEnv(t)
	admin := e.setupAdmin()
	tv := e.login("admin", "correct horse", "tvos")

	type result struct {
		p   pullResponse
		dur time.Duration
		err error
	}
	done := make(chan result, 1)
	go func() {
		start := time.Now()
		r, err := e.doCtx(context.Background(), "GET", "/api/sync?since=0&wait=20", tv.Token, nil)
		var p pullResponse
		if err == nil {
			err = json.Unmarshal(r.body, &p)
		}
		done <- result{p, time.Since(start), err}
	}()
	time.Sleep(300 * time.Millisecond)
	select {
	case <-done:
		t.Fatal("long poll returned before any push")
	default:
	}
	e.push(admin.Token, rec{"collection": "favorites", "id": "default|movie:tt1", "data": rec{"addedAt": 1}, "updatedAt": 10})
	select {
	case r := <-done:
		if r.err != nil {
			t.Fatal(r.err)
		}
		if len(r.p.Records) != 1 || r.p.Rev != 1 {
			t.Fatalf("woken pull: %+v", r.p)
		}
		if r.dur > 5*time.Second {
			t.Fatalf("wake took %v", r.dur)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("long poll was not woken by push")
	}

	// Timeout path: nothing new → empty answer after ~wait seconds.
	start := time.Now()
	p := e.pull(tv.Token, "since=1&wait=1")
	if len(p.Records) != 0 || p.Rev != 1 || time.Since(start) < 900*time.Millisecond {
		t.Fatalf("timeout pull: %+v after %v", p, time.Since(start))
	}

	// Client cancellation ends the request promptly.
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	start = time.Now()
	_, err := e.doCtx(ctx, "GET", "/api/sync?since=1&wait=30", tv.Token, nil)
	if err == nil || time.Since(start) > 3*time.Second {
		t.Fatalf("cancel: err=%v after %v", err, time.Since(start))
	}

	// Revoking a device while it long-polls answers 401 immediately.
	go func() {
		r, err := e.doCtx(context.Background(), "GET", "/api/sync?since=1&wait=20", tv.Token, nil)
		if err != nil {
			done <- result{err: err}
			return
		}
		done <- result{err: fmt.Errorf("status %d", r.status)}
	}()
	time.Sleep(300 * time.Millisecond)
	e.expect(e.do("DELETE", "/api/devices/"+tv.Device.ID, admin.Token, nil), 204)
	select {
	case r := <-done:
		if r.err == nil || r.err.Error() != "status 401" {
			t.Fatalf("expected 401 for revoked long poll, got %v", r.err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("revoked long poll not released")
	}
}

func TestPairingFlow(t *testing.T) {
	e := newTestEnv(t)
	admin := e.setupAdmin()

	var start struct {
		PairID    string `json:"pairId"`
		Code      string `json:"code"`
		ExpiresIn int    `json:"expiresIn"`
	}
	e.expect(e.do("POST", "/api/auth/pair/start", "", map[string]any{"device": device("Living room TV", "tvos")}), 200).json(t, &start)
	if len(start.Code) != 7 || start.Code[3] != '-' || start.ExpiresIn != 600 || start.PairID == "" {
		t.Fatalf("start: %+v", start)
	}
	for _, c := range strings.ReplaceAll(start.Code, "-", "") {
		if strings.ContainsRune("01OIL", c) {
			t.Fatalf("ambiguous char in %s", start.Code)
		}
	}
	var st map[string]any
	e.expect(e.do("GET", "/api/auth/pair/"+start.PairID, "", nil), 202).json(t, &st)
	if st["status"] != "pending" {
		t.Fatalf("status %v", st)
	}
	// Approval needs auth; wrong codes are 404.
	e.expect(e.do("POST", "/api/pair/approve", "", map[string]any{"code": start.Code}), 401)
	e.expect(e.do("POST", "/api/pair/approve", admin.Token, map[string]any{"code": "AAA-AAA"}), 404)

	// Lowercase / no dash is accepted.
	sloppy := strings.ToLower(strings.ReplaceAll(start.Code, "-", ""))
	var appr struct{ Device Device }
	e.expect(e.do("POST", "/api/pair/approve", admin.Token, map[string]any{"code": sloppy, "scopes": []string{"read", "write"}}), 200).json(t, &appr)
	if appr.Device.Platform != "tvos" || appr.Device.Name != "Living room TV" || strings.Join(appr.Device.Scopes, ",") != "read,write" {
		t.Fatalf("approved device %+v", appr.Device)
	}
	e.expect(e.do("POST", "/api/pair/approve", admin.Token, map[string]any{"code": start.Code}), 409)

	var poll struct {
		Status string `json:"status"`
		Token  string `json:"token"`
		User   User   `json:"user"`
		Device Device `json:"device"`
	}
	e.expect(e.do("GET", "/api/auth/pair/"+start.PairID, "", nil), 200).json(t, &poll)
	if poll.Status != "approved" || !strings.HasPrefix(poll.Token, "sf_") || poll.User.ID != admin.User.ID || poll.Device.ID != appr.Device.ID || !poll.Device.Current {
		t.Fatalf("poll: %+v", poll)
	}
	// Token is handed out once.
	e.expect(e.do("GET", "/api/auth/pair/"+start.PairID, "", nil), 410)

	var me struct{ Device Device }
	e.expect(e.do("GET", "/api/me", poll.Token, nil), 200).json(t, &me)
	if strings.Join(me.Device.Scopes, ",") != "read,write" {
		t.Fatalf("scopes %v", me.Device.Scopes)
	}

	// Expiry.
	e.expect(e.do("POST", "/api/auth/pair/start", "", map[string]any{"device": device("Kitchen TV", "androidtv")}), 200).json(t, &start)
	e.clock.Advance(11 * time.Minute)
	e.expect(e.do("POST", "/api/pair/approve", admin.Token, map[string]any{"code": start.Code}), 410)
	e.expect(e.do("GET", "/api/auth/pair/"+start.PairID, "", nil), 410)
	e.expect(e.do("GET", "/api/auth/pair/p_unknown", "", nil), 410)

	// Audit log records the pairing.
	var audit struct{ Events []AuditEvent }
	e.expect(e.do("GET", "/api/audit", admin.Token, nil), 200).json(t, &audit)
	found := false
	for _, ev := range audit.Events {
		if ev.Event == "pair.approve" {
			found = true
		}
	}
	if !found {
		t.Fatalf("pair.approve not audited: %+v", audit.Events)
	}
}

func TestRevocation(t *testing.T) {
	e := newTestEnv(t)
	admin := e.setupAdmin()
	phone := e.login("admin", "correct horse", "ios")

	var list struct{ Devices []Device }
	e.expect(e.do("GET", "/api/devices", admin.Token, nil), 200).json(t, &list)
	if len(list.Devices) != 2 {
		t.Fatalf("devices: %+v", list.Devices)
	}
	current := 0
	for _, d := range list.Devices {
		if d.Current {
			current++
			if d.ID != admin.Device.ID {
				t.Fatalf("wrong current device")
			}
		}
	}
	if current != 1 {
		t.Fatalf("current count %d", current)
	}

	e.expect(e.do("GET", "/api/sync?since=0", phone.Token, nil), 200)
	e.expect(e.do("DELETE", "/api/devices/"+phone.Device.ID, admin.Token, nil), 204)
	e.expect(e.do("GET", "/api/sync?since=0", phone.Token, nil), 401)
	e.expect(e.do("POST", "/api/sync", phone.Token, map[string]any{"records": []rec{}}), 401)
	e.expect(e.do("DELETE", "/api/devices/"+phone.Device.ID, admin.Token, nil), 404)

	// Disabling a user revokes all its devices and blocks login.
	e.expect(e.do("POST", "/api/users", admin.Token, map[string]any{"username": "guest", "password": "guestpass1"}), 200)
	g1 := e.login("guest", "guestpass1", "android")
	g2 := e.login("guest", "guestpass1", "androidtv")
	// Members can't see or touch other users' devices or users.
	e.expect(e.do("GET", "/api/users", g1.Token, nil), 403)
	e.expect(e.do("GET", "/api/devices?user="+admin.User.ID, g1.Token, nil), 403)
	e.expect(e.do("DELETE", "/api/devices/"+admin.Device.ID, g1.Token, nil), 404)

	var users struct{ Users []User }
	e.expect(e.do("GET", "/api/users", admin.Token, nil), 200).json(t, &users)
	var guestID string
	for _, u := range users.Users {
		if u.Username == "guest" {
			guestID = u.ID
		}
	}
	var u User
	e.expect(e.do("PATCH", "/api/users/"+guestID, admin.Token, map[string]any{"disabled": true}), 200).json(t, &u)
	if !u.Disabled {
		t.Fatal("not disabled")
	}
	e.expect(e.do("GET", "/api/me", g1.Token, nil), 401)
	e.expect(e.do("GET", "/api/me", g2.Token, nil), 401)
	if r := e.expect(e.do("POST", "/api/auth/login", "", map[string]any{"username": "guest", "password": "guestpass1"}), 403); r.code(t) != "account_disabled" {
		t.Fatalf("code %q", r.code(t))
	}
	e.expect(e.do("PATCH", "/api/users/"+guestID, admin.Token, map[string]any{"disabled": false, "password": "newguestpass"}), 200)
	g3 := e.login("guest", "newguestpass", "android")
	e.push(g3.Token, rec{"collection": "watched", "id": "x", "data": rec{"k": 1}, "updatedAt": 1})

	// Last-admin protection and self-protection.
	e.expect(e.do("PATCH", "/api/users/"+admin.User.ID, admin.Token, map[string]any{"role": "member"}), 409)
	e.expect(e.do("PATCH", "/api/users/"+admin.User.ID, admin.Token, map[string]any{"disabled": true}), 400)
	e.expect(e.do("DELETE", "/api/users/"+admin.User.ID, admin.Token, nil), 400)

	// Deleting a user removes their data and tokens.
	e.expect(e.do("DELETE", "/api/users/"+guestID, admin.Token, nil), 204)
	e.expect(e.do("GET", "/api/me", g3.Token, nil), 401)
	var n int
	e.app.db.QueryRow(`SELECT COUNT(*) FROM records WHERE user_id = ?`, guestID).Scan(&n)
	if n != 0 {
		t.Fatalf("records left after delete: %d", n)
	}
}

func TestChangePassword(t *testing.T) {
	e := newTestEnv(t)
	admin := e.setupAdmin()
	if r := e.expect(e.do("POST", "/api/me/password", admin.Token, map[string]any{"current": "nope-nope", "new": "brand new pass"}), 403); r.code(t) != "wrong_password" {
		t.Fatalf("code %q", r.code(t))
	}
	e.expect(e.do("POST", "/api/me/password", admin.Token, map[string]any{"current": "correct horse", "new": "short"}), 400)
	e.expect(e.do("POST", "/api/me/password", admin.Token, map[string]any{"current": "correct horse", "new": "brand new pass"}), 204)
	e.expect(e.do("POST", "/api/auth/login", "", map[string]any{"username": "admin", "password": "correct horse"}), 401)
	e.login("admin", "brand new pass", "web")
}

func TestSecrets(t *testing.T) {
	e := newTestEnv(t)
	admin := e.setupAdmin()
	noSecrets, _ := e.pairTV(admin.Token, []string{"read", "write"})

	secret := rec{"collection": "secrets", "id": "server:abc", "data": rec{"xcPassword": "hunter2-very-secret"}, "updatedAt": 100}
	e.push(admin.Token,
		secret,
		rec{"collection": "servers", "id": "abc", "data": rec{"name": "Home", "url": "http://x"}, "updatedAt": 100},
	)

	// Device without the scope: secret filtered out, rev still advances past it.
	p := e.pull(noSecrets, "since=0")
	if len(p.Records) != 1 || p.Records[0].Collection != "servers" || p.Rev != 2 {
		t.Fatalf("filtered pull: %+v", p)
	}
	if bytes.Contains(e.do("GET", "/api/sync?since=0", noSecrets, nil).body, []byte("hunter2")) {
		t.Fatal("secret leaked")
	}
	// Only a secret is newer: no records but rev advances, and a long poll returns at once.
	e.push(admin.Token, rec{"collection": "secrets", "id": "key:tmdb", "data": rec{"value": "tmdbkey"}, "updatedAt": 100})
	start := time.Now()
	p = e.pull(noSecrets, "since=2&wait=10")
	if len(p.Records) != 0 || p.Rev != 3 || time.Since(start) > 3*time.Second {
		t.Fatalf("secret-only pull: %+v", p)
	}
	// A device without the scope can't write secrets either.
	_, res := e.push(noSecrets, rec{"collection": "secrets", "id": "server:abc", "data": rec{"xcPassword": "evil"}, "updatedAt": 999999})
	if res[0].Status != "stale" {
		t.Fatalf("expected stale for unscoped secret push: %+v", res)
	}

	// Full device gets the secret back, decrypted, unchanged.
	p = e.pull(admin.Token, "since=0")
	var got Record
	for _, r := range p.Records {
		if r.Collection == "secrets" && r.ID == "server:abc" {
			got = r
		}
	}
	if string(got.Data) != `{"xcPassword":"hunter2-very-secret"}` {
		t.Fatalf("secret data %s", got.Data)
	}

	// At rest it is AES-GCM encrypted and bound to the record.
	var stored string
	if err := e.app.db.QueryRow(`SELECT data FROM records WHERE collection='secrets' AND id='server:abc'`).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(stored, encPrefix) || strings.Contains(stored, "hunter2") {
		t.Fatalf("not encrypted at rest: %q", stored)
	}
	if _, err := e.app.decrypt(admin.User.ID, "secrets", "key:tmdb", stored); err == nil {
		t.Fatal("ciphertext should be bound to its record id")
	}
	// The raw database file doesn't contain the plaintext either.
	_ = e.app.db.Close()
	for _, f := range []string{"streamforge.db", "streamforge.db-wal"} {
		b, _ := os.ReadFile(filepath.Join(e.dir, f))
		if bytes.Contains(b, []byte("hunter2")) {
			t.Fatalf("plaintext secret found in %s", f)
		}
	}
	fi, err := os.Stat(filepath.Join(e.dir, "secret.key"))
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o600 || fi.Size() != 32 {
		t.Fatalf("secret.key mode %v size %d", fi.Mode().Perm(), fi.Size())
	}
}

func TestStatsAndSignup(t *testing.T) {
	e := newTestEnv(t)
	admin := e.setupAdmin()
	e.push(admin.Token,
		rec{"collection": "progress", "id": "a", "data": rec{"p": 1}, "updatedAt": 1},
		rec{"collection": "progress", "id": "b", "data": rec{"p": 1}, "updatedAt": 1},
		rec{"collection": "watched", "id": "c", "deleted": true, "updatedAt": 1},
	)
	var st struct {
		Rev         int64
		LastSyncAt  int64
		Records     int64
		Collections []collectionStat
	}
	e.expect(e.do("GET", "/api/stats", admin.Token, nil), 200).json(t, &st)
	if st.Rev != 3 || st.Records != 2 || st.LastSyncAt == 0 || len(st.Collections) != 2 || st.Collections[0].Count != 2 || st.Collections[1].Deleted != 1 {
		t.Fatalf("stats %+v", st)
	}
	if r := e.expect(e.do("POST", "/api/auth/signup", "", map[string]any{"username": "x", "password": "12345678"}), 403); r.code(t) != "signup_disabled" {
		t.Fatalf("code %q", r.code(t))
	}

	e2 := newTestEnv(t, func(c *Config) { c.OpenSignup = true })
	e2.setupAdmin()
	var lr loginResponse
	e2.expect(e2.do("POST", "/api/auth/signup", "", map[string]any{"username": "newbie", "password": "12345678", "device": device("p", "ios")}), 200).json(t, &lr)
	if lr.User.Role != "member" || lr.Token == "" {
		t.Fatalf("signup %+v", lr)
	}
	e2.expect(e2.do("POST", "/api/auth/signup", "", map[string]any{"username": "NEWBIE", "password": "12345678"}), 409)
}

func TestTrustProxy(t *testing.T) {
	e := newTestEnv(t, func(c *Config) { c.TrustProxy = true })
	r := httptest.NewRequest("GET", "/", nil)
	r.RemoteAddr = "10.0.0.2:5555"
	r.Header.Set("X-Forwarded-For", "1.2.3.4, 203.0.113.9")
	if ip := e.app.clientIP(r); ip != "203.0.113.9" {
		t.Fatalf("ip %q", ip)
	}
	e2 := newTestEnv(t)
	if ip := e2.app.clientIP(r); ip != "10.0.0.2" {
		t.Fatalf("ip %q", ip)
	}
}

func TestPairCodeHelpers(t *testing.T) {
	for i := 0; i < 200; i++ {
		c := newPairCode()
		n, ok := normalizePairCode(strings.ToLower(c))
		if !ok || n != c {
			t.Fatalf("roundtrip %q → %q", c, n)
		}
	}
	if _, ok := normalizePairCode("K7Q-4M0"); ok {
		t.Fatal("0 must be rejected")
	}
}
