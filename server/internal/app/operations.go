package app

import (
	"archive/zip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"time"
)

// Backups are private, consistent SQLite snapshots with the matching encryption key.
// Only a secrets-scoped admin can create or download one.
var backupName = regexp.MustCompile(`^streamforge-[0-9]{8}T[0-9]{6}-[0-9]+\.zip$`)

type backupView struct {
	Name      string `json:"name"`
	Size      int64  `json:"size"`
	CreatedAt int64  `json:"createdAt"`
}

func (a *App) backupDir() string { return filepath.Join(a.cfg.DataDir, "backups") }
func (a *App) backups() ([]backupView, error) {
	entries, err := os.ReadDir(a.backupDir())
	if os.IsNotExist(err) {
		return []backupView{}, nil
	}
	if err != nil {
		return nil, err
	}
	out := []backupView{}
	for _, e := range entries {
		if !backupName.MatchString(e.Name()) || !e.Type().IsRegular() {
			continue
		}
		info, err := e.Info()
		if err != nil {
			return nil, err
		}
		out = append(out, backupView{e.Name(), info.Size(), info.ModTime().UnixMilli()})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt > out[j].CreatedAt })
	return out, nil
}
func (a *App) createBackup(ctx context.Context) (backupView, error) {
	a.backupMu.Lock()
	defer a.backupMu.Unlock()
	if err := os.MkdirAll(a.backupDir(), 0700); err != nil {
		return backupView{}, err
	}
	temp, err := os.MkdirTemp(a.backupDir(), "snapshot-")
	if err != nil {
		return backupView{}, err
	}
	defer os.RemoveAll(temp)
	dbPath := filepath.Join(temp, "streamforge.db")
	if _, err = a.db.ExecContext(ctx, `VACUUM INTO ?`, dbPath); err != nil {
		return backupView{}, err
	}
	name := fmt.Sprintf("streamforge-%s-%d.zip", a.now().UTC().Format("20060102T150405"), time.Now().UnixNano())
	tmpZip := filepath.Join(temp, name)
	f, err := os.OpenFile(tmpZip, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return backupView{}, err
	}
	z := zip.NewWriter(f)
	for _, item := range []struct{ name, path string }{{"streamforge.db", dbPath}, {"secret.key", filepath.Join(a.cfg.DataDir, "secret.key")}} {
		src, e := os.Open(item.path)
		if e != nil {
			z.Close()
			f.Close()
			return backupView{}, e
		}
		h := &zip.FileHeader{Name: item.name, Method: zip.Deflate}
		h.SetMode(0600)
		dst, e := z.CreateHeader(h)
		if e == nil {
			_, e = io.Copy(dst, src)
		}
		src.Close()
		if e != nil {
			z.Close()
			f.Close()
			return backupView{}, e
		}
	}
	manifest, _ := json.Marshal(map[string]any{"format": 1, "version": a.cfg.Version, "createdAt": a.nowMs()})
	dst, err := z.Create("manifest.json")
	if err == nil {
		_, err = dst.Write(manifest)
	}
	if e := z.Close(); err == nil {
		err = e
	}
	if e := f.Sync(); err == nil {
		err = e
	}
	if e := f.Close(); err == nil {
		err = e
	}
	if err != nil {
		return backupView{}, err
	}
	if err = os.Rename(tmpZip, filepath.Join(a.backupDir(), name)); err != nil {
		return backupView{}, err
	}
	list, err := a.backups()
	if err != nil {
		return backupView{}, err
	}
	// Keep the seven newest completed snapshots; an incomplete archive is never listed.
	for i := 7; i < len(list); i++ {
		if err := os.Remove(filepath.Join(a.backupDir(), list[i].Name)); err != nil {
			a.log.Printf("backup retention: %v", err)
		}
	}
	for _, b := range list {
		if b.Name == name {
			return b, nil
		}
	}
	return backupView{}, fmt.Errorf("backup missing")
}
func (a *App) scheduledBackup() {
	var enabled string
	if a.db.QueryRow(`SELECT value FROM meta WHERE key='daily_backups'`).Scan(&enabled) != nil || enabled != "true" {
		return
	}
	list, err := a.backups()
	if err != nil {
		a.log.Printf("backup list: %v", err)
		return
	}
	if len(list) > 0 && a.nowMs()-list[0].CreatedAt < 24*time.Hour.Milliseconds() {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	if _, err := a.createBackup(ctx); err != nil {
		a.log.Printf("scheduled backup failed: %v", err)
	}
}
func backupAccess(w http.ResponseWriter, p *principal) bool {
	if !p.device.has("secrets") {
		writeErr(w, 403, "scope_missing", "backups require the secrets scope")
		return false
	}
	return true
}
func (a *App) handleBackups(w http.ResponseWriter, r *http.Request, p *principal) {
	if !backupAccess(w, p) {
		return
	}
	list, err := a.backups()
	if err != nil {
		writeInternal(w, a, "list backups", err)
		return
	}
	var enabled string
	_ = a.db.QueryRow(`SELECT value FROM meta WHERE key='daily_backups'`).Scan(&enabled)
	writeJSON(w, 200, map[string]any{"backups": list, "daily": enabled == "true", "retention": 7})
}
func (a *App) handleBackupSchedule(w http.ResponseWriter, r *http.Request, p *principal) {
	if !backupAccess(w, p) {
		return
	}
	var req struct {
		Daily bool `json:"daily"`
	}
	if !decodeJSON(w, r, maxSmallBody, &req) {
		return
	}
	_, err := a.db.Exec(`INSERT INTO meta(key,value) VALUES('daily_backups',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value`, fmt.Sprint(req.Daily))
	if err != nil {
		writeInternal(w, a, "backup schedule", err)
		return
	}
	a.auditAdmin(p, "backup_schedule", fmt.Sprint(req.Daily))
	writeJSON(w, 200, map[string]bool{"daily": req.Daily})
}
func (a *App) handleCreateBackup(w http.ResponseWriter, r *http.Request, p *principal) {
	if !backupAccess(w, p) {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), time.Minute)
	defer cancel()
	b, err := a.createBackup(ctx)
	if err != nil {
		writeInternal(w, a, "create backup", err)
		return
	}
	a.auditAdmin(p, "backup_create", b.Name)
	writeJSON(w, 201, b)
}
func (a *App) handleDownloadBackup(w http.ResponseWriter, r *http.Request, p *principal) {
	if !backupAccess(w, p) {
		return
	}
	name := r.PathValue("name")
	if !backupName.MatchString(name) {
		writeErr(w, 404, "not_found", "backup not found")
		return
	}
	path := filepath.Join(a.backupDir(), name)
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() {
		writeErr(w, 404, "not_found", "backup not found")
		return
	}
	a.auditAdmin(p, "backup_download", name)
	w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)
	w.Header().Set("Content-Type", "application/zip")
	http.ServeFile(w, r, path)
}
func (a *App) touchDeviceSync(p *principal) {
	a.touchSync(p.user.ID)
	if _, err := a.db.Exec(`INSERT INTO device_health(device_id,last_sync_at) VALUES(?,?) ON CONFLICT(device_id) DO UPDATE SET last_sync_at=excluded.last_sync_at`, p.device.ID, a.nowMs()); err != nil {
		a.log.Printf("device sync health: %v", err)
	}
}
func (a *App) handleOperations(w http.ResponseWriter, r *http.Request, p *principal) {
	if err := a.db.PingContext(r.Context()); err != nil {
		writeInternal(w, a, "health", err)
		return
	}
	var users, devices, recent, records int
	for _, q := range []struct {
		sql  string
		dest *int
	}{{`SELECT COUNT(*) FROM users`, &users}, {`SELECT COUNT(*) FROM devices`, &devices}, {`SELECT COUNT(*) FROM records WHERE deleted=0`, &records}} {
		if err := a.db.QueryRow(q.sql).Scan(q.dest); err != nil {
			writeInternal(w, a, "health counts", err)
			return
		}
	}
	if err := a.db.QueryRow(`SELECT COUNT(*) FROM devices WHERE last_seen_at>?`, a.now().Add(-15*time.Minute).UnixMilli()).Scan(&recent); err != nil {
		writeInternal(w, a, "health recent", err)
		return
	}
	var size int64
	for _, name := range []string{"streamforge.db", "streamforge.db-wal"} {
		if info, err := os.Stat(filepath.Join(a.cfg.DataDir, name)); err == nil {
			size += info.Size()
		}
	}
	list, err := a.backups()
	if err != nil {
		writeInternal(w, a, "health backups", err)
		return
	}
	var last int64
	if len(list) > 0 {
		last = list[0].CreatedAt
	}
	writeJSON(w, 200, map[string]any{"database": "healthy", "version": a.cfg.Version, "users": users, "devices": devices, "recentDevices": recent, "records": records, "databaseBytes": size, "lastBackupAt": last})
}
