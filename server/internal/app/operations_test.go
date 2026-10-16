package app

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestBackupSnapshotAndAccess(t *testing.T) {
	e := newTestEnv(t)
	admin := e.setupAdmin()
	limited, _ := e.pairTV(admin.Token, []string{"read", "write"})
	e.expect(e.do("POST", "/api/admin/backups", limited, map[string]any{}), 403)
	var b backupView
	e.expect(e.do("POST", "/api/admin/backups", admin.Token, map[string]any{}), 201).json(t, &b)
	r := e.expect(e.do("GET", "/api/admin/backups/"+b.Name, admin.Token, nil), 200)
	z, err := zip.NewReader(bytes.NewReader(r.body), int64(len(r.body)))
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	names := map[string]bool{}
	for _, f := range z.File {
		if f.Name != "streamforge.db" && f.Name != "secret.key" && f.Name != "manifest.json" {
			t.Fatal(f.Name)
		}
		names[f.Name] = true
		src, err := f.Open()
		if err != nil {
			t.Fatal(err)
		}
		data, err := io.ReadAll(src)
		src.Close()
		if err != nil {
			t.Fatal(err)
		}
		if err = os.WriteFile(filepath.Join(dir, f.Name), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	if len(names) != 3 {
		t.Fatal(names)
	}
	key, _ := os.ReadFile(filepath.Join(dir, "secret.key"))
	original, _ := os.ReadFile(filepath.Join(e.dir, "secret.key"))
	if !bytes.Equal(key, original) {
		t.Fatal("wrong key")
	}
	db, err := openDB(filepath.Join(dir, "streamforge.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var n int
	if err = db.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&n); err != nil || n != 1 {
		t.Fatalf("restore users %d: %v", n, err)
	}
	e.expect(e.do("GET", "/api/admin/backups/"+b.Name, limited, nil), 403)
	for i := 0; i < 8; i++ {
		if _, err := e.app.createBackup(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	list, err := e.app.backups()
	if err != nil || len(list) != 7 {
		t.Fatalf("retention %d: %v", len(list), err)
	}
}

func TestProgressConflictPreservesWinnerAndAllowsSeek(t *testing.T) {
	e := newTestEnv(t)
	a := e.setupAdmin()
	b := e.login("admin", "correct horse", "ios")
	push := func(token string, base, stamp, pos int64) int64 {
		var out struct {
			Results []pushResult `json:"results"`
		}
		e.expect(e.do("POST", "/api/sync", token, map[string]any{"records": []map[string]any{{"collection": "progress", "id": "profile|movie", "baseRev": base, "updatedAt": stamp, "data": map[string]any{"position": pos}}}}), 200).json(t, &out)
		return out.Results[0].Rev
	}
	now := e.app.nowMs()
	r1 := push(a.Token, 0, now, 100)
	r2 := push(b.Token, r1, now+1, 200)
	r3 := push(a.Token, r1, now+2, 50)
	if r3 <= r2 {
		t.Fatal("conflict must republish winner")
	}
	read := func() int {
		var data string
		if err := e.app.db.QueryRow(`SELECT data FROM records WHERE collection='progress'`).Scan(&data); err != nil {
			t.Fatal(err)
		}
		var obj struct{ Position int }
		json.Unmarshal([]byte(data), &obj)
		return obj.Position
	}
	if read() != 200 {
		t.Fatal("offline device overwrote newer session")
	}
	push(a.Token, r3, now+100, 20)
	if read() != 20 {
		t.Fatal("intentional seek with latest revision rejected")
	}
	var devs struct {
		Devices []Device `json:"devices"`
	}
	e.expect(e.do("GET", "/api/devices", a.Token, nil), 200).json(t, &devs)
	for _, d := range devs.Devices {
		if d.LastSyncAt == 0 {
			t.Fatal("missing successful sync time")
		}
	}
}

func TestProviderProbeDoesNotFollowCredentialRedirect(t *testing.T) {
	e := newTestEnv(t)
	admin := e.setupAdmin()
	followed := false
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { followed = true; w.Write([]byte(`{}`)) }))
	defer target.Close()
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, target.URL, 302) }))
	defer provider.Close()
	now := e.app.nowMs()
	_, err := e.app.db.Exec(`INSERT INTO dispatcharr_servers(id,name,url,created_at,updated_at) VALUES('probe','Test',?,?,?)`, provider.URL, now, now)
	if err != nil {
		t.Fatal(err)
	}
	sealed := e.app.sealAssignment(admin.User.ID, "probe", serverSecret{XcPassword: "never-echo-this"})
	_, err = e.app.db.Exec(`INSERT INTO dispatcharr_assignments(server_id,user_id,auth_mode,username,secret,created_at,updated_at) VALUES('probe',?,'xc','test',?,?,?)`, admin.User.ID, sealed, now, now)
	if err != nil {
		t.Fatal(err)
	}
	r := e.expect(e.do("POST", "/api/admin/dispatcharr/probe/users/"+admin.User.ID+"/test", admin.Token, map[string]any{}), 200)
	if followed || bytes.Contains(r.body, []byte("never-echo-this")) {
		t.Fatal("credential leak")
	}
	var result struct{ OK bool }
	r.json(t, &result)
	if result.OK {
		t.Fatal("redirect should not pass")
	}
}
