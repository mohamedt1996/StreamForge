package app

import (
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"strings"

	"golang.org/x/crypto/bcrypt"
	_ "modernc.org/sqlite" // pure-Go SQLite driver, registers "sqlite"
)

const schema = `
CREATE TABLE IF NOT EXISTS meta (
	key   TEXT PRIMARY KEY,
	value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS users (
	id           TEXT PRIMARY KEY,
	username     TEXT NOT NULL UNIQUE COLLATE NOCASE,
	pass_hash    TEXT NOT NULL,
	role         TEXT NOT NULL,
	disabled     INTEGER NOT NULL DEFAULT 0,
	created_at   INTEGER NOT NULL,
	rev          INTEGER NOT NULL DEFAULT 0,
	last_sync_at INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS devices (
	id           TEXT PRIMARY KEY,
	user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	name         TEXT NOT NULL,
	platform     TEXT NOT NULL,
	scopes       TEXT NOT NULL,
	token_hash   TEXT NOT NULL UNIQUE,
	created_at   INTEGER NOT NULL,
	last_seen_at INTEGER NOT NULL DEFAULT 0,
	last_ip      TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS devices_user ON devices(user_id);
CREATE TABLE IF NOT EXISTS records (
	user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
	collection TEXT NOT NULL,
	id         TEXT NOT NULL,
	data       TEXT,
	deleted    INTEGER NOT NULL DEFAULT 0,
	updated_at INTEGER NOT NULL,
	rev        INTEGER NOT NULL,
	device_id  TEXT NOT NULL DEFAULT '',
	stored_at  INTEGER NOT NULL,
	PRIMARY KEY (user_id, collection, id)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS records_rev ON records(user_id, rev);
CREATE TABLE IF NOT EXISTS audit (
	id        INTEGER PRIMARY KEY AUTOINCREMENT,
	ts        INTEGER NOT NULL,
	user_id   TEXT NOT NULL DEFAULT '',
	username  TEXT NOT NULL DEFAULT '',
	device_id TEXT NOT NULL DEFAULT '',
	event     TEXT NOT NULL,
	detail    TEXT NOT NULL DEFAULT '',
	ip        TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS audit_user ON audit(user_id, id);
`

func openDB(path string) (*sql.DB, error) {
	q := url.Values{}
	q.Add("_pragma", "busy_timeout(5000)")
	q.Add("_pragma", "journal_mode(WAL)")
	q.Add("_pragma", "synchronous(NORMAL)")
	q.Add("_pragma", "foreign_keys(1)")
	dsn := "file:" + path + "?" + q.Encode()
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open database: %w", err)
	}
	// One connection serialises all access. For a personal/household sync server this is
	// plenty, and it makes read-modify-write transactions (LWW push) trivially safe.
	// Long polls never hold the connection while they wait.
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(0)
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrate database: %w", err)
	}
	if _, err := db.Exec(`INSERT OR IGNORE INTO meta(key, value) VALUES ('schema_version', '1')`); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrate database: %w", err)
	}
	return db, nil
}

// ---- users ----------------------------------------------------------------

// User is the public user representation.
type User struct {
	ID        string `json:"id"`
	Username  string `json:"username"`
	Role      string `json:"role"`
	Disabled  bool   `json:"disabled"`
	CreatedAt int64  `json:"createdAt"`
}

var errNotFound = errors.New("not found")

const userCols = `id, username, role, disabled, created_at`

func scanUser(s interface{ Scan(...any) error }) (User, error) {
	var u User
	var disabled int
	err := s.Scan(&u.ID, &u.Username, &u.Role, &disabled, &u.CreatedAt)
	u.Disabled = disabled != 0
	if errors.Is(err, sql.ErrNoRows) {
		return u, errNotFound
	}
	return u, err
}

func (a *App) userCount() (int, error) {
	var n int
	err := a.db.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&n)
	return n, err
}

func (a *App) getUser(id string) (User, error) {
	return scanUser(a.db.QueryRow(`SELECT `+userCols+` FROM users WHERE id = ?`, id))
}

func (a *App) userByName(name string) (User, []byte, error) {
	var hash string
	var u User
	var disabled int
	err := a.db.QueryRow(`SELECT id, username, role, disabled, created_at, pass_hash FROM users WHERE username = ?`, name).
		Scan(&u.ID, &u.Username, &u.Role, &disabled, &u.CreatedAt, &hash)
	if errors.Is(err, sql.ErrNoRows) {
		return u, nil, errNotFound
	}
	u.Disabled = disabled != 0
	return u, []byte(hash), err
}

func (a *App) listUsers() ([]User, error) {
	rows, err := a.db.Query(`SELECT ` + userCols + ` FROM users ORDER BY created_at, username`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	users := []User{}
	for rows.Next() {
		u, err := scanUser(rows)
		if err != nil {
			return nil, err
		}
		users = append(users, u)
	}
	return users, rows.Err()
}

var errUsernameTaken = errors.New("username taken")

func (a *App) createUser(username, password, role string) (User, error) {
	hash, err := bcrypt.GenerateFromPassword([]byte(password), a.cfg.BcryptCost)
	if err != nil {
		return User{}, err
	}
	u := User{ID: newID("u_"), Username: username, Role: role, CreatedAt: a.nowMs()}
	_, err = a.db.Exec(`INSERT INTO users(id, username, pass_hash, role, created_at) VALUES (?, ?, ?, ?, ?)`,
		u.ID, u.Username, string(hash), u.Role, u.CreatedAt)
	if err != nil {
		if isUniqueErr(err) {
			return User{}, errUsernameTaken
		}
		return User{}, err
	}
	return u, nil
}

func (a *App) setPassword(userID, password string) error {
	hash, err := bcrypt.GenerateFromPassword([]byte(password), a.cfg.BcryptCost)
	if err != nil {
		return err
	}
	_, err = a.db.Exec(`UPDATE users SET pass_hash = ? WHERE id = ?`, string(hash), userID)
	return err
}

func (a *App) passHash(userID string) ([]byte, error) {
	var h string
	err := a.db.QueryRow(`SELECT pass_hash FROM users WHERE id = ?`, userID).Scan(&h)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, errNotFound
	}
	return []byte(h), err
}

// enabledAdminsExcluding counts enabled admins other than the given user.
func (a *App) enabledAdminsExcluding(userID string) (int, error) {
	var n int
	err := a.db.QueryRow(`SELECT COUNT(*) FROM users WHERE role = 'admin' AND disabled = 0 AND id <> ?`, userID).Scan(&n)
	return n, err
}

func isUniqueErr(err error) bool {
	return err != nil && strings.Contains(strings.ToLower(err.Error()), "unique")
}

// ---- devices --------------------------------------------------------------

// Device is the public device representation.
type Device struct {
	ID         string   `json:"id"`
	Name       string   `json:"name"`
	Platform   string   `json:"platform"`
	Scopes     []string `json:"scopes"`
	CreatedAt  int64    `json:"createdAt"`
	LastSeenAt int64    `json:"lastSeenAt"`
	LastIP     string   `json:"lastIp"`
	Current    bool     `json:"current"`

	userID string
}

func (d Device) has(scope string) bool {
	for _, s := range d.Scopes {
		if s == scope {
			return true
		}
	}
	return false
}

const deviceCols = `id, user_id, name, platform, scopes, created_at, last_seen_at, last_ip`

func scanDevice(s interface{ Scan(...any) error }) (Device, error) {
	var d Device
	var scopes string
	err := s.Scan(&d.ID, &d.userID, &d.Name, &d.Platform, &scopes, &d.CreatedAt, &d.LastSeenAt, &d.LastIP)
	if errors.Is(err, sql.ErrNoRows) {
		return d, errNotFound
	}
	d.Scopes = splitScopes(scopes)
	return d, err
}

func (a *App) getDevice(id string) (Device, error) {
	return scanDevice(a.db.QueryRow(`SELECT `+deviceCols+` FROM devices WHERE id = ?`, id))
}

func (a *App) listDevices(userID string) ([]Device, error) {
	rows, err := a.db.Query(`SELECT `+deviceCols+` FROM devices WHERE user_id = ? ORDER BY created_at`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Device{}
	for rows.Next() {
		d, err := scanDevice(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// createDevice inserts a device for the user and returns it with its plaintext token.
func (a *App) createDevice(userID, name, platform string, scopes []string, ip string) (Device, string, error) {
	token := newToken()
	now := a.nowMs()
	d := Device{ID: newID("d_"), Name: name, Platform: platform, Scopes: scopes, CreatedAt: now, LastSeenAt: now, LastIP: ip, userID: userID}
	_, err := a.db.Exec(`INSERT INTO devices(id, user_id, name, platform, scopes, token_hash, created_at, last_seen_at, last_ip) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		d.ID, userID, d.Name, d.Platform, joinScopes(scopes), hashToken(token), now, now, ip)
	if err != nil {
		return Device{}, "", err
	}
	return d, token, nil
}

func (a *App) deleteDevice(id string) error {
	_, err := a.db.Exec(`DELETE FROM devices WHERE id = ?`, id)
	return err
}

func (a *App) deleteUserDevices(userID string) (int64, error) {
	res, err := a.db.Exec(`DELETE FROM devices WHERE user_id = ?`, userID)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// ---- audit ----------------------------------------------------------------

// AuditEvent is one entry of the activity log.
type AuditEvent struct {
	ID       int64  `json:"id"`
	TS       int64  `json:"ts"`
	UserID   string `json:"userId"`
	Username string `json:"username"`
	DeviceID string `json:"deviceId"`
	Event    string `json:"event"`
	Detail   string `json:"detail"`
	IP       string `json:"ip"`
}

func (a *App) audit(userID, username, deviceID, event, detail, ip string) {
	_, err := a.db.Exec(`INSERT INTO audit(ts, user_id, username, device_id, event, detail, ip) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		a.nowMs(), userID, cleanText(username, 64), deviceID, event, cleanText(detail, 300), ip)
	if err != nil {
		a.log.Printf("audit write failed: %v", err)
	}
}
