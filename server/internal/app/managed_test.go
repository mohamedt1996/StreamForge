package app

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

// ---- helpers ------------------------------------------------------------------------------

func (e *testEnv) createUser(adminToken, username string, extra map[string]any) User {
	e.t.Helper()
	body := map[string]any{"username": username, "password": "password-" + username, "role": "member"}
	for k, v := range extra {
		body[k] = v
	}
	var u User
	e.expect(e.do("POST", "/api/users", adminToken, body), 200).json(e.t, &u)
	return u
}

func findRec(p pullResponse, collection, id string) *Record {
	var out *Record
	for i := range p.Records {
		if p.Records[i].Collection == collection && p.Records[i].ID == id {
			out = &p.Records[i]
		}
	}
	return out
}

func dataMap(t *testing.T, r *Record) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(r.Data, &m); err != nil {
		t.Fatalf("record data %s: %v", r.Data, err)
	}
	return m
}

// manifestServer serves an addon manifest (+ logo) and counts requests.
func manifestServer(t *testing.T, name string) *httptest.Server {
	t.Helper()
	png := []byte("\x89PNG\r\n\x1a\nfake")
	mux := http.NewServeMux()
	mux.HandleFunc("/manifest.json", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"id": "org.test." + strings.ToLower(name), "name": name, "version": "1.2.3",
			"description": "A test addon", "logo": "/logo.png", "resources": []string{"stream"},
		})
	})
	mux.HandleFunc("/logo.png", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write(png)
	})
	s := httptest.NewServer(mux)
	t.Cleanup(s.Close)
	return s
}

type serverView = dispatcharrServerView

func (e *testEnv) createConnection(adminToken, name, url string) serverView {
	e.t.Helper()
	var s serverView
	e.expect(e.do("POST", "/api/admin/dispatcharr", adminToken, map[string]any{"name": name, "url": url}), 200).json(e.t, &s)
	return s
}

func (e *testEnv) createAddon(adminToken string, body map[string]any) addonView {
	e.t.Helper()
	var v addonView
	e.expect(e.do("POST", "/api/admin/addons", adminToken, body), 200).json(e.t, &v)
	return v
}

// ---- tests --------------------------------------------------------------------------------

func TestAddonURLNormalization(t *testing.T) {
	cases := []struct{ in, want string }{
		// Examples the apps handle (AddonManager.swift / Addons.kt).
		{"https://v3-cinemeta.strem.io/manifest.json", "https://v3-cinemeta.strem.io/manifest.json"},
		{"https://opensubtitles-v3.strem.io/manifest.json", "https://opensubtitles-v3.strem.io/manifest.json"},
		{"stremio://torrentio.strem.fun/manifest.json", "https://torrentio.strem.fun/manifest.json"},
		{"STREMIO://torrentio.strem.fun/manifest.json", "https://torrentio.strem.fun/manifest.json"},
		{"torrentio.strem.fun", "https://torrentio.strem.fun/manifest.json"},
		{"  https://torrentio.strem.fun/  ", "https://torrentio.strem.fun/manifest.json"},
		{"https://torrentio.strem.fun///", "https://torrentio.strem.fun/manifest.json"},
		{"https://torrentio.strem.fun/manifest.json/", "https://torrentio.strem.fun/manifest.json"},
		// Configured Torrentio link: "|" is percent-encoded like both apps do.
		{"https://torrentio.strem.fun/providers=yts,eztv|qualityfilter=480p,scr/manifest.json",
			"https://torrentio.strem.fun/providers=yts,eztv%7Cqualityfilter=480p,scr/manifest.json"},
		{"stremio://torrentio.strem.fun/sort=size|debridoptions=nodownloadlinks", "https://torrentio.strem.fun/sort=size%7Cdebridoptions=nodownloadlinks/manifest.json"},
		// Already-encoded input stays as it is ("%" is URL-safe for both apps).
		{"https://torrentio.strem.fun/a%7Cb/manifest.json", "https://torrentio.strem.fun/a%7Cb/manifest.json"},
		// Spaces and non-ASCII: UTF-8, upper-case hex.
		{"https://example.com/my addon/é", "https://example.com/my%20addon/%C3%A9/manifest.json"},
		{"http://192.168.1.5:7000/abc", "http://192.168.1.5:7000/abc/manifest.json"},
		{"https://x.example/k=v;a=b@c:d!$&'()*+~/manifest.json", "https://x.example/k=v;a=b@c:d!$&'()*+~/manifest.json"},
		{"https://x.example/{a}^`\"<>\\", "https://x.example/%7Ba%7D%5E%60%22%3C%3E%5C/manifest.json"},
	}
	for _, c := range cases {
		got, err := normalizeAddonURL(c.in)
		if err != nil || got != c.want {
			t.Errorf("normalizeAddonURL(%q) = %q, %v; want %q", c.in, got, err, c.want)
		}
	}
	for _, bad := range []string{"", "   ", "ftp://example.com/x", "javascript:alert(1)", "https:///manifest.json"} {
		if got, err := normalizeAddonURL(bad); err == nil {
			t.Errorf("normalizeAddonURL(%q) = %q, want error", bad, got)
		}
	}
}

func TestDispatcharrAssignmentSync(t *testing.T) {
	e := newTestEnv(t)
	admin := e.setupAdmin()
	e.createUser(admin.Token, "mo", nil)
	other := e.createUser(admin.Token, "sara", nil)
	mo := e.login("mo", "password-mo", "ios")
	tv, _ := e.pairTV(mo.Token, []string{"read", "write"}) // no secrets scope

	// Members can't use the admin API.
	if r := e.expect(e.do("GET", "/api/admin/dispatcharr", mo.Token, nil), 403); r.code(t) != "admin_required" {
		t.Fatalf("member admin access: %s", r.body)
	}

	conn := e.createConnection(admin.Token, "Home", "http://192.168.1.10:9191/")
	if !uuidRe.MatchString(conn.ID) || conn.URL != "http://192.168.1.10:9191" {
		t.Fatalf("connection: %+v", conn)
	}
	e.expect(e.do("POST", "/api/admin/dispatcharr", admin.Token, map[string]any{"name": "Bad", "url": "not a url"}), 400)

	// A long poll of mo's phone is woken by the assignment.
	base := e.pull(mo.Token, "since=0").Rev
	done := make(chan pullResponse, 1)
	go func() {
		r, err := e.doCtx(t.Context(), "GET", "/api/sync?since="+itoa(base)+"&wait=20", mo.Token, nil)
		var p pullResponse
		if err == nil {
			_ = json.Unmarshal(r.body, &p)
		}
		done <- p
	}()
	time.Sleep(150 * time.Millisecond)

	var av assignmentView
	e.expect(e.do("PUT", "/api/admin/dispatcharr/"+conn.ID+"/users/"+mo.User.ID, admin.Token, map[string]any{
		"authMode": "xc", "username": "mo-iptv", "xcPassword": "xc-hunter2", "apiKey": "key-abc",
	}), 200).json(t, &av)
	if !av.HasXcPassword || av.HasWebPassword || !av.HasAPIKey || av.Username != "mo-iptv" || av.User != "mo" {
		t.Fatalf("assignment view: %+v", av)
	}
	select {
	case p := <-done:
		if findRec(p, "servers", conn.ID) == nil {
			t.Fatalf("long poll didn't deliver the server: %+v", p)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("long poll was not woken by the assignment")
	}

	// Phone (secrets scope): server + credentials.
	p := e.pull(mo.Token, "since=0")
	srv, sec := findRec(p, "servers", conn.ID), findRec(p, "secrets", "server:"+conn.ID)
	if srv == nil || sec == nil {
		t.Fatalf("phone pull: %+v", p)
	}
	d := dataMap(t, srv)
	if d["name"] != "Home" || d["url"] != "http://192.168.1.10:9191" || d["username"] != "mo-iptv" || d["authMode"] != "xc" || d["managed"] != true {
		t.Fatalf("server data: %s", srv.Data)
	}
	if !srv.Managed || !sec.Managed {
		t.Fatal("records should be flagged managed")
	}
	if string(sec.Data) != `{"xcPassword":"xc-hunter2","webPassword":"","apiKey":"key-abc"}` {
		t.Fatalf("secret data: %s", sec.Data)
	}
	// TV without the secrets scope: the server but never the credentials.
	tp := e.pull(tv, "since=0")
	if findRec(tp, "servers", conn.ID) == nil || findRec(tp, "secrets", "server:"+conn.ID) != nil {
		t.Fatalf("tv pull: %+v", tp)
	}
	if bytes.Contains(e.do("GET", "/api/sync?since=0", tv, nil).body, []byte("xc-hunter2")) {
		t.Fatal("secret leaked to a device without the secrets scope")
	}
	// Other users get nothing.
	if findRec(e.pull(e.login("sara", "password-sara", "android").Token, "since=0"), "servers", conn.ID) != nil {
		t.Fatal("unassigned user received the server")
	}
	// The admin API never returns credentials; at rest they're encrypted.
	if r := e.expect(e.do("GET", "/api/admin/dispatcharr", admin.Token, nil), 200); bytes.Contains(r.body, []byte("xc-hunter2")) || bytes.Contains(r.body, []byte("key-abc")) {
		t.Fatalf("credentials returned to the browser: %s", r.body)
	}
	var stored string
	if err := e.app.db.QueryRow(`SELECT secret FROM dispatcharr_assignments`).Scan(&stored); err != nil || !strings.HasPrefix(stored, encPrefix) || strings.Contains(stored, "hunter2") {
		t.Fatalf("assignment credentials not encrypted: %q %v", stored, err)
	}

	// Editing the connection rewrites the user's record (higher updatedAt and rev).
	var upd serverView
	e.expect(e.do("PATCH", "/api/admin/dispatcharr/"+conn.ID, admin.Token, map[string]any{"name": "Home 2"}), 200).json(t, &upd)
	p2 := e.pull(mo.Token, "since="+itoa(p.Rev))
	srv2 := findRec(p2, "servers", conn.ID)
	if srv2 == nil || dataMap(t, srv2)["name"] != "Home 2" || srv2.UpdatedAt <= srv.UpdatedAt || srv2.Rev <= srv.Rev {
		t.Fatalf("edit not propagated: %+v", p2)
	}
	if findRec(p2, "secrets", "server:"+conn.ID) != nil {
		t.Fatal("unchanged secret should not be rewritten")
	}
	// Editing the assignment without passwords keeps them; replacing one rewrites the secret.
	e.expect(e.do("PUT", "/api/admin/dispatcharr/"+conn.ID+"/users/"+mo.User.ID, admin.Token, map[string]any{"webPassword": "web-pw"}), 200).json(t, &av)
	p3 := e.pull(mo.Token, "since="+itoa(p2.Rev))
	if s := findRec(p3, "secrets", "server:"+conn.ID); s == nil || string(s.Data) != `{"xcPassword":"xc-hunter2","webPassword":"web-pw","apiKey":"key-abc"}` {
		t.Fatalf("credential update: %+v", p3)
	}

	// Unassign → tombstones for both records.
	e.expect(e.do("DELETE", "/api/admin/dispatcharr/"+conn.ID+"/users/"+mo.User.ID, admin.Token, nil), 204)
	p4 := e.pull(mo.Token, "since="+itoa(p3.Rev))
	for _, k := range [][2]string{{"servers", conn.ID}, {"secrets", "server:" + conn.ID}} {
		r := findRec(p4, k[0], k[1])
		if r == nil || !r.Deleted || string(r.Data) != "null" || r.Managed {
			t.Fatalf("expected tombstone for %v: %+v", k, p4)
		}
	}
	// TV sees the server tombstone too (and still no secrets).
	if r := findRec(e.pull(tv, "since=0"), "servers", conn.ID); r == nil || !r.Deleted {
		t.Fatal("tv didn't get the tombstone")
	}

	// Deleting a connection tombstones it for every assigned user.
	e.expect(e.do("PUT", "/api/admin/dispatcharr/"+conn.ID+"/users/"+other.ID, admin.Token, map[string]any{"authMode": "web", "username": "s", "webPassword": "x"}), 200)
	sara := e.login("sara", "password-sara", "ios")
	sp := e.pull(sara.Token, "since=0")
	if r := findRec(sp, "servers", conn.ID); r == nil || r.Deleted {
		t.Fatal("sara should have the server")
	}
	e.expect(e.do("DELETE", "/api/admin/dispatcharr/"+conn.ID, admin.Token, nil), 204)
	sp2 := e.pull(sara.Token, "since="+itoa(sp.Rev))
	if r := findRec(sp2, "servers", conn.ID); r == nil || !r.Deleted {
		t.Fatalf("delete connection: %+v", sp2)
	}
	if r := findRec(sp2, "secrets", "server:"+conn.ID); r == nil || !r.Deleted {
		t.Fatalf("delete connection secret: %+v", sp2)
	}
	var list struct{ Servers []serverView }
	if e.expect(e.do("GET", "/api/admin/dispatcharr", admin.Token, nil), 200).json(t, &list); len(list.Servers) != 0 {
		t.Fatalf("connection not deleted: %+v", list)
	}

	// Audit-logged.
	var audit struct{ Events []AuditEvent }
	e.expect(e.do("GET", "/api/audit?limit=100", admin.Token, nil), 200).json(t, &audit)
	seen := map[string]bool{}
	for _, ev := range audit.Events {
		seen[ev.Event] = true
		if strings.Contains(ev.Detail, "hunter2") {
			t.Fatal("secret in audit log")
		}
	}
	for _, ev := range []string{"admin.dispatcharr.create", "admin.dispatcharr.assign", "admin.dispatcharr.update", "admin.dispatcharr.unassign", "admin.dispatcharr.delete"} {
		if !seen[ev] {
			t.Errorf("missing audit event %s", ev)
		}
	}
}

func TestManagedRecordsEnforced(t *testing.T) {
	e := newTestEnv(t)
	admin := e.setupAdmin()
	ms := manifestServer(t, "Torrentio")
	member := e.createUser(admin.Token, "mo", nil)
	mo := e.login("mo", "password-mo", "android")

	addon := e.createAddon(admin.Token, map[string]any{"url": ms.URL + "/", "users": []string{member.ID, admin.User.ID}})
	tu := ms.URL + "/manifest.json"
	if addon.TransportURL != tu || addon.Name != "Torrentio" || addon.ManifestID != "org.test.torrentio" || addon.Version != "1.2.3" ||
		!strings.HasPrefix(addon.Logo, "data:image/png;base64,") || addon.FetchError != "" || len(addon.Users) != 2 {
		t.Fatalf("addon view: %+v", addon)
	}
	conn := e.createConnection(admin.Token, "Home", "http://dispatcharr.lan")
	e.expect(e.do("PUT", "/api/admin/dispatcharr/"+conn.ID+"/users/"+member.ID, admin.Token, map[string]any{"authMode": "xc", "username": "u", "xcPassword": "p"}), 200)

	p := e.pull(mo.Token, "since=0")
	rec0 := findRec(p, "addons", tu)
	if rec0 == nil || rec0.Deleted {
		t.Fatalf("member should have the addon: %+v", p)
	}
	d := dataMap(t, rec0)
	if d["transportUrl"] != tu || d["name"] != "Torrentio" || d["enabled"] != true || d["managed"] != true {
		t.Fatalf("addon data %s", rec0.Data)
	}

	// The member's device deletes the managed addon with a newer timestamp: stale, and the
	// server copy comes back newer than the device's delete with a higher rev.
	delTS := rec0.UpdatedAt + 60_000
	rev, res := e.push(mo.Token, rec{"collection": "addons", "id": tu, "deleted": true, "updatedAt": delTS})
	if res[0].Status != "stale" || res[0].Rev <= p.Rev || rev != res[0].Rev {
		t.Fatalf("delete of managed addon: rev %d %+v", rev, res)
	}
	p2 := e.pull(mo.Token, "since="+itoa(p.Rev))
	back := findRec(p2, "addons", tu)
	if back == nil || back.Deleted || back.UpdatedAt <= delTS || back.Rev <= p.Rev || string(back.Data) != string(rec0.Data) {
		t.Fatalf("managed addon not restored: %+v", p2)
	}
	// Same for edits (disable), for the server, and for its credentials.
	_, res = e.push(mo.Token,
		rec{"collection": "addons", "id": tu, "data": rec{"transportUrl": tu, "name": "x", "enabled": false, "order": 9}, "updatedAt": back.UpdatedAt + 5},
		rec{"collection": "servers", "id": conn.ID, "data": rec{"name": "Hacked", "url": "http://evil"}, "updatedAt": 1},
		rec{"collection": "secrets", "id": "server:" + conn.ID, "deleted": true, "updatedAt": time.Now().UnixMilli()},
	)
	for _, r := range res {
		if r.Status != "stale" {
			t.Fatalf("managed write applied: %+v", res)
		}
	}
	p3 := e.pull(mo.Token, "since="+itoa(p2.Rev))
	if a := findRec(p3, "addons", tu); a == nil || dataMap(t, a)["enabled"] != true {
		t.Fatalf("addon edit not reverted: %+v", p3)
	}
	if s := findRec(p3, "servers", conn.ID); s == nil || dataMap(t, s)["name"] != "Home" || s.UpdatedAt < 2 {
		t.Fatalf("server not restored: %+v", p3)
	}
	if s := findRec(p3, "secrets", "server:"+conn.ID); s == nil || s.Deleted || string(s.Data) != `{"xcPassword":"p","webPassword":"","apiKey":""}` {
		t.Fatalf("secret not restored: %+v", p3)
	}

	// The member's own (unmanaged) records still sync normally.
	_, res = e.push(mo.Token, rec{"collection": "addons", "id": "https://own.example/manifest.json", "data": rec{"transportUrl": "https://own.example/manifest.json", "name": "Own"}, "updatedAt": 10})
	if res[0].Status != "applied" {
		t.Fatalf("own addon: %+v", res)
	}
	_, res = e.push(mo.Token, rec{"collection": "addons", "id": "https://own.example/manifest.json", "deleted": true, "updatedAt": 11})
	if res[0].Status != "applied" {
		t.Fatalf("own addon delete: %+v", res)
	}

	// Admin devices may change managed records of their own account.
	ap := e.pull(admin.Token, "since=0")
	ar := findRec(ap, "addons", tu)
	if ar == nil || !ar.Managed {
		t.Fatalf("admin should have the managed addon: %+v", ap)
	}
	_, res = e.push(admin.Token, rec{"collection": "addons", "id": tu, "deleted": true, "updatedAt": ar.UpdatedAt + 1})
	if res[0].Status != "applied" {
		t.Fatalf("admin delete of own managed record: %+v", res)
	}

	// Unassigning removes the record cleanly; afterwards the member may re-add it as their own.
	before := e.pull(mo.Token, "since=0").Rev
	e.expect(e.do("DELETE", "/api/admin/addons/"+addon.ID+"/users/"+member.ID, admin.Token, nil), 204)
	p4 := e.pull(mo.Token, "since="+itoa(before))
	tomb := findRec(p4, "addons", tu)
	if tomb == nil || !tomb.Deleted || tomb.UpdatedAt <= back.UpdatedAt {
		t.Fatalf("unassign tombstone: %+v", p4)
	}
	_, res = e.push(mo.Token, rec{"collection": "addons", "id": tu, "data": rec{"transportUrl": tu, "name": "Mine"}, "updatedAt": tomb.UpdatedAt + 1})
	if res[0].Status != "applied" {
		t.Fatalf("re-adding a formerly managed addon: %+v", res)
	}
}

func TestAllUsersAddons(t *testing.T) {
	e := newTestEnv(t)
	admin := e.setupAdmin()
	existing := e.createUser(admin.Token, "early", nil)

	// The manifest can't be fetched: the addon is still added (with the error noted).
	dead := httptest.NewServer(http.NotFoundHandler())
	deadURL := dead.URL
	dead.Close()
	v := e.createAddon(admin.Token, map[string]any{"url": "stremio://" + strings.TrimPrefix(deadURL, "http://") + "/conf|x=1", "allUsers": true, "name": "Custom"})
	wantURL := "https://" + strings.TrimPrefix(deadURL, "http://") + "/conf%7Cx=1/manifest.json"
	if v.TransportURL != wantURL || v.FetchError == "" || v.Name != "Custom" || !v.AllUsers {
		t.Fatalf("addon: %+v", v)
	}
	// Adding the same addon again (any spelling) conflicts.
	if r := e.expect(e.do("POST", "/api/admin/addons", admin.Token, map[string]any{"url": wantURL}), 409); r.code(t) != "addon_exists" {
		t.Fatalf("duplicate: %s", r.body)
	}

	// Existing users, the admin and users created later all get it.
	later := e.createUser(admin.Token, "later", nil)
	for _, u := range []string{"early", "later"} {
		tok := e.login(u, "password-"+u, "ios").Token
		r := findRec(e.pull(tok, "since=0"), "addons", wantURL)
		if r == nil || r.Deleted || !r.Managed || dataMap(t, r)["name"] != "Custom" {
			t.Fatalf("%s didn't get the all-users addon", u)
		}
	}
	if findRec(e.pull(admin.Token, "since=0"), "addons", wantURL) == nil {
		t.Fatal("admin didn't get the all-users addon")
	}

	// Switching "all users" off keeps it only for directly assigned users.
	e.expect(e.do("PUT", "/api/admin/addons/"+v.ID+"/users/"+later.ID, admin.Token, nil), 204)
	e.expect(e.do("PATCH", "/api/admin/addons/"+v.ID, admin.Token, map[string]any{"allUsers": false}), 200)
	if r := findRec(e.pull(e.login("early", "password-early", "ios").Token, "since=0"), "addons", wantURL); r == nil || !r.Deleted {
		t.Fatalf("early should have a tombstone: %+v", r)
	}
	if r := findRec(e.pull(e.login("later", "password-later", "ios").Token, "since=0"), "addons", wantURL); r == nil || r.Deleted {
		t.Fatal("later (directly assigned) should keep it")
	}
	_ = existing

	// Deleting the library entry removes it everywhere.
	e.expect(e.do("DELETE", "/api/admin/addons/"+v.ID, admin.Token, nil), 204)
	if r := findRec(e.pull(e.login("later", "password-later", "ios").Token, "since=0"), "addons", wantURL); r == nil || !r.Deleted {
		t.Fatal("delete should tombstone")
	}
}

func TestManagedSettings(t *testing.T) {
	e := newTestEnv(t)
	admin := e.setupAdmin()
	member := e.createUser(admin.Token, "mo", nil)
	mo := e.login("mo", "password-mo", "ios")

	var meta struct {
		Keys     []settingSpec              `json:"keys"`
		Defaults map[string]json.RawMessage `json:"defaults"`
	}
	e.expect(e.do("GET", "/api/admin/settings", admin.Token, nil), 200).json(t, &meta)
	if len(meta.Keys) != 18 {
		t.Fatalf("expected the 18 synced keys, got %d", len(meta.Keys))
	}

	for _, bad := range []map[string]any{{"autoplayNext": "yes"}, {"seekStep": 0}, {"seekStep": 2.5}, {"streamSort": "random"}, {"activeServer": "x"}} {
		e.expect(e.do("PUT", "/api/admin/users/"+member.ID+"/settings", admin.Token, map[string]any{"values": bad}), 400)
	}
	e.expect(e.do("PUT", "/api/admin/users/"+member.ID+"/settings", admin.Token, map[string]any{"values": map[string]any{"autoplayNext": false, "seekStep": 30, "streamSort": "size"}}), 200)
	p := e.pull(mo.Token, "since=0")
	r := findRec(p, "settings", "seekStep")
	if r == nil || string(r.Data) != `{"value":30,"managed":true}` || !r.Managed {
		t.Fatalf("managed setting: %+v", p)
	}
	_, res := e.push(mo.Token, rec{"collection": "settings", "id": "seekStep", "data": rec{"value": 5}, "updatedAt": r.UpdatedAt + 1})
	if res[0].Status != "stale" {
		t.Fatalf("member overwrote a managed setting: %+v", res)
	}
	// Release: the value stays, but it's the member's again.
	e.expect(e.do("PUT", "/api/admin/users/"+member.ID+"/settings", admin.Token, map[string]any{"values": map[string]any{"seekStep": nil}}), 200)
	p2 := e.pull(mo.Token, "since="+itoa(p.Rev))
	r2 := findRec(p2, "settings", "seekStep")
	if r2 == nil || r2.Deleted || r2.Managed || string(r2.Data) != `{"value":30}` {
		t.Fatalf("released setting: %+v", p2)
	}
	_, res = e.push(mo.Token, rec{"collection": "settings", "id": "seekStep", "data": rec{"value": 5}, "updatedAt": r2.UpdatedAt + 1})
	if res[0].Status != "applied" {
		t.Fatalf("released setting should be writable: %+v", res)
	}

	// Defaults apply to new users, and on demand to existing ones.
	e.expect(e.do("PUT", "/api/admin/settings/defaults", admin.Token, map[string]any{"values": map[string]any{"hideAdult": true, "metadataLanguage": "fr"}}), 200).json(t, &meta)
	if string(meta.Defaults["hideAdult"]) != "true" {
		t.Fatalf("defaults: %+v", meta.Defaults)
	}
	e.createUser(admin.Token, "kid", nil)
	kp := e.pull(e.login("kid", "password-kid", "tvos").Token, "since=0")
	if r := findRec(kp, "settings", "hideAdult"); r == nil || string(r.Data) != `{"value":true,"managed":true}` {
		t.Fatalf("new user defaults: %+v", kp)
	}
	if findRec(e.pull(mo.Token, "since=0"), "settings", "hideAdult") != nil {
		t.Fatal("defaults must not reach existing users until applied")
	}
	var applied struct{ Users int }
	e.expect(e.do("POST", "/api/admin/settings/defaults/apply", admin.Token, nil), 200).json(t, &applied)
	if applied.Users != 3 {
		t.Fatalf("applied to %d users", applied.Users)
	}
	if r := findRec(e.pull(mo.Token, "since=0"), "settings", "metadataLanguage"); r == nil || string(r.Data) != `{"value":"fr","managed":true}` {
		t.Fatalf("apply defaults: %+v", r)
	}
}

func TestCopyFromUserAndUserDetail(t *testing.T) {
	e := newTestEnv(t)
	admin := e.setupAdmin()
	e.createUser(admin.Token, "mo", nil)
	target := e.createUser(admin.Token, "sara", nil)
	mo := e.login("mo", "password-mo", "ios")
	sid := "6f1c1c0e-3b0a-4c47-9a53-2d7f9a0b7e11"
	tu := "https://torrentio.strem.fun/sort=size%7Cqualityfilter=cam/manifest.json"
	e.push(mo.Token,
		rec{"collection": "addons", "id": tu, "data": rec{"transportUrl": tu, "name": "Torrentio", "enabled": true, "order": 0}, "updatedAt": 10},
		rec{"collection": "servers", "id": sid, "data": rec{"name": "Mo's IPTV", "url": "http://iptv.lan:9191", "username": "mo", "authMode": "web", "order": 0}, "updatedAt": 10},
		rec{"collection": "secrets", "id": "server:" + sid, "data": rec{"xcPassword": "", "webPassword": "web-secret", "apiKey": ""}, "updatedAt": 10},
		rec{"collection": "settings", "id": "subtitleLanguage", "data": rec{"value": "ar"}, "updatedAt": 10},
		rec{"collection": "settings", "id": "notASyncedKey", "data": rec{"value": 1}, "updatedAt": 10},
	)

	var counts map[string]int
	e.expect(e.do("POST", "/api/admin/users/"+target.ID+"/copy", admin.Token, map[string]any{"from": mo.User.ID}), 200).json(t, &counts)
	if counts["addons"] != 1 || counts["servers"] != 1 || counts["settings"] != 1 {
		t.Fatalf("copy counts: %v", counts)
	}
	sp := e.pull(e.login("sara", "password-sara", "ios").Token, "since=0")
	if r := findRec(sp, "addons", tu); r == nil || !r.Managed {
		t.Fatalf("copied addon: %+v", sp)
	}
	if r := findRec(sp, "servers", sid); r == nil || dataMap(t, r)["authMode"] != "web" || dataMap(t, r)["url"] != "http://iptv.lan:9191" {
		t.Fatalf("copied server: %+v", sp)
	}
	if r := findRec(sp, "secrets", "server:"+sid); r == nil || !strings.Contains(string(r.Data), `"webPassword":"web-secret"`) {
		t.Fatalf("copied credentials: %+v", sp)
	}
	if r := findRec(sp, "settings", "subtitleLanguage"); r == nil || string(r.Data) != `{"value":"ar","managed":true}` {
		t.Fatalf("copied setting: %+v", sp)
	}
	// The source's own records are not touched (not managed).
	if r := findRec(e.pull(mo.Token, "since=0"), "servers", sid); r == nil || r.Managed {
		t.Fatal("source records must stay the user's own")
	}

	// Create a user with assignments in one go.
	conn := e.createConnection(admin.Token, "Shared", "https://tv.example.com")
	var lib struct{ Addons []addonView }
	e.expect(e.do("GET", "/api/admin/addons", admin.Token, nil), 200).json(t, &lib)
	e.expect(e.do("POST", "/api/users", admin.Token, map[string]any{"username": "bad", "password": "password-bad", "addons": []string{"a_nope"}}), 400)
	nu := e.createUser(admin.Token, "nour", map[string]any{
		"dispatcharr": []map[string]any{{"serverId": conn.ID, "authMode": "apiKey", "username": "nour", "apiKey": "nour-key-secret"}},
		"addons":      []string{lib.Addons[0].ID},
	})
	np := e.pull(e.login("nour", "password-nour", "android").Token, "since=0")
	if findRec(np, "servers", conn.ID) == nil || findRec(np, "secrets", "server:"+conn.ID) == nil || findRec(np, "addons", tu) == nil {
		t.Fatalf("assignments at creation: %+v", np)
	}

	// Per-user detail view.
	r := e.expect(e.do("GET", "/api/admin/users/"+nu.ID, admin.Token, nil), 200)
	if bytes.Contains(r.body, []byte("nour-key-secret")) {
		t.Fatal("detail view leaked credentials")
	}
	var detail struct {
		User        User              `json:"user"`
		Devices     []Device          `json:"devices"`
		Stats       collectionStats   `json:"stats"`
		Dispatcharr []assignmentView  `json:"dispatcharr"`
		Servers     []map[string]any  `json:"servers"`
		Addons      []map[string]any  `json:"addons"`
		Settings    []userSettingView `json:"settings"`
	}
	r.json(t, &detail)
	if detail.User.Username != "nour" || len(detail.Devices) != 1 || detail.Stats.Records < 3 ||
		len(detail.Dispatcharr) != 1 || !detail.Dispatcharr[0].HasAPIKey || detail.Dispatcharr[0].AuthMode != "apiKey" ||
		len(detail.Servers) != 1 || detail.Servers[0]["managed"] != true ||
		len(detail.Addons) != 1 || detail.Addons[0]["source"] != "direct" || detail.Addons[0]["managed"] != true ||
		len(detail.Settings) != 18 {
		t.Fatalf("detail: %s", r.body)
	}
	e.expect(e.do("GET", "/api/admin/users/u_missing", admin.Token, nil), 404)
	e.expect(e.do("GET", "/api/admin/users/"+nu.ID, mo.Token, nil), 403)

	// Deleting a user drops their assignments.
	e.expect(e.do("DELETE", "/api/users/"+nu.ID, admin.Token, nil), 204)
	var n int
	if err := e.app.db.QueryRow(`SELECT COUNT(*) FROM dispatcharr_assignments WHERE user_id = ?`, nu.ID).Scan(&n); err != nil || n != 0 {
		t.Fatalf("assignments left after user delete: %d %v", n, err)
	}
}

func TestManagedMigrationIdempotent(t *testing.T) {
	e := newTestEnv(t)
	e.setupAdmin()
	if err := migrateManaged(e.app.db); err != nil {
		t.Fatalf("second migration: %v", err)
	}
	var v string
	if err := e.app.db.QueryRow(`SELECT value FROM meta WHERE key = 'schema_version'`).Scan(&v); err != nil || v != "2" {
		t.Fatalf("schema_version %q %v", v, err)
	}
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }
