// Package app implements the StreamForge Sync server (protocol v1, see PROTOCOL.md).
package app

import (
	"crypto/cipher"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	"golang.org/x/crypto/bcrypt"
)

// Config holds the runtime configuration. Zero values get sensible defaults.
type Config struct {
	Addr          string // listen address, e.g. ":8484" (used by main only)
	DataDir       string // directory for the database and secret key
	Name          string // server display name (STREAMFORGE_NAME)
	Version       string // build version, set via -ldflags
	AdminUser     string // bootstrap admin (only used when there are no users yet)
	AdminPassword string
	OpenSignup    bool // allow anyone to create an account
	TrustProxy    bool // use X-Forwarded-For for the client IP

	// BcryptCost overrides the bcrypt cost (tests use bcrypt.MinCost). 0 = default.
	BcryptCost int
	// Now overrides the clock (tests). nil = time.Now.
	Now func() time.Time
	// Logger; nil = log.Default().
	Logger *log.Logger
	// HTTPClient is used to fetch addon manifests; nil = a client with a short timeout.
	HTTPClient *http.Client
}

const (
	tombstoneTTL   = 180 * 24 * time.Hour
	auditTTL       = 365 * 24 * time.Hour
	pairTTL        = 10 * time.Minute
	maxPushRecords = 500
	maxRecordData  = 256 << 10
	maxPushBody    = 2 << 20
	maxSmallBody   = 64 << 10
	maxWaitSeconds = 55
	defaultLimit   = 1000
	futureSkew     = 5 * time.Minute
)

// App is the sync server. Create it with New, serve Handler(), and Close it on shutdown.
type App struct {
	cfg        Config
	db         *sql.DB
	aead       cipher.AEAD
	log        *log.Logger
	httpClient *http.Client

	hub   *hub
	pairs *pairStore

	loginLimiter *limiter // per IP+username failures
	ipLimiter    *limiter // per IP failures (username spraying)
	pairLimiter  *limiter // pair/start per IP
	codeLimiter  *limiter // wrong pairing codes per user
	pwLimiter    *limiter // wrong current password per user

	backupMu sync.Mutex
	setupMu  sync.Mutex
	handler  http.Handler

	stop     chan struct{}
	stopOnce sync.Once
	wg       sync.WaitGroup

	dummyHash []byte
}

// New opens (or creates) the data directory, database and encryption key.
func New(cfg Config) (*App, error) {
	if cfg.DataDir == "" {
		cfg.DataDir = "/data"
	}
	if cfg.Name == "" {
		cfg.Name = "StreamForge Sync"
	}
	if cfg.Version == "" {
		cfg.Version = "dev"
	}
	if cfg.BcryptCost == 0 {
		cfg.BcryptCost = bcrypt.DefaultCost
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.Logger == nil {
		cfg.Logger = log.Default()
	}
	if cfg.HTTPClient == nil {
		cfg.HTTPClient = &http.Client{Timeout: 2 * manifestTimeout}
	}
	if err := os.MkdirAll(cfg.DataDir, 0o700); err != nil {
		return nil, fmt.Errorf("create data dir: %w", err)
	}
	key, err := loadOrCreateKey(filepath.Join(cfg.DataDir, "secret.key"), cfg.Logger)
	if err != nil {
		return nil, err
	}
	aead, err := newAEAD(key)
	if err != nil {
		return nil, err
	}
	db, err := openDB(filepath.Join(cfg.DataDir, "streamforge.db"))
	if err != nil {
		return nil, err
	}
	a := &App{
		cfg:          cfg,
		db:           db,
		aead:         aead,
		log:          cfg.Logger,
		httpClient:   cfg.HTTPClient,
		hub:          newHub(),
		pairs:        newPairStore(),
		loginLimiter: newLimiter(10, 15*time.Minute, cfg.Now),
		ipLimiter:    newLimiter(50, 15*time.Minute, cfg.Now),
		pairLimiter:  newLimiter(30, 15*time.Minute, cfg.Now),
		codeLimiter:  newLimiter(10, 15*time.Minute, cfg.Now),
		pwLimiter:    newLimiter(10, 15*time.Minute, cfg.Now),
		stop:         make(chan struct{}),
	}
	a.dummyHash, _ = bcrypt.GenerateFromPassword([]byte("streamforge-timing-equaliser"), cfg.BcryptCost)
	if err := a.bootstrap(); err != nil {
		db.Close()
		return nil, err
	}
	a.handler = a.routes()
	a.wg.Add(1)
	go a.janitor()
	return a, nil
}

// Handler returns the HTTP handler for the whole server (API + web admin).
func (a *App) Handler() http.Handler { return a.handler }

// Close stops background work and closes the database.
func (a *App) Close() error {
	a.stopOnce.Do(func() { close(a.stop) })
	a.wg.Wait()
	return a.db.Close()
}

func (a *App) now() time.Time { return a.cfg.Now() }
func (a *App) nowMs() int64   { return a.cfg.Now().UnixMilli() }

// bootstrap creates the first admin from the environment when the database has no users.
func (a *App) bootstrap() error {
	if a.cfg.AdminUser == "" && a.cfg.AdminPassword == "" {
		return nil
	}
	n, err := a.userCount()
	if err != nil {
		return err
	}
	if n > 0 {
		return nil
	}
	if a.cfg.AdminUser == "" || a.cfg.AdminPassword == "" {
		return errors.New("STREAMFORGE_ADMIN_USER and STREAMFORGE_ADMIN_PASSWORD must both be set")
	}
	if msg := validateUsername(a.cfg.AdminUser); msg != "" {
		return fmt.Errorf("STREAMFORGE_ADMIN_USER: %s", msg)
	}
	if msg := validatePassword(a.cfg.AdminPassword); msg != "" {
		return fmt.Errorf("STREAMFORGE_ADMIN_PASSWORD: %s", msg)
	}
	u, err := a.createUser(a.cfg.AdminUser, a.cfg.AdminPassword, "admin")
	if err != nil {
		return err
	}
	a.audit(u.ID, u.Username, "", "setup", "admin created from environment", "")
	a.log.Printf("created admin user %q from environment", u.Username)
	return nil
}

// janitor periodically removes expired tombstones, audit entries, pairings and limiter state.
func (a *App) janitor() {
	defer a.wg.Done()
	t := time.NewTicker(time.Hour)
	defer t.Stop()
	a.cleanup()
	a.scheduledBackup()
	for {
		select {
		case <-a.stop:
			return
		case <-t.C:
			a.cleanup()
			a.scheduledBackup()
		}
	}
}

func (a *App) cleanup() {
	now := a.now()
	if res, err := a.db.Exec(`DELETE FROM records WHERE deleted = 1 AND stored_at < ?`, now.Add(-tombstoneTTL).UnixMilli()); err != nil {
		a.log.Printf("cleanup tombstones: %v", err)
	} else if n, _ := res.RowsAffected(); n > 0 {
		a.log.Printf("cleanup: removed %d expired tombstones", n)
	}
	if _, err := a.db.Exec(`DELETE FROM audit WHERE ts < ?`, now.Add(-auditTTL).UnixMilli()); err != nil {
		a.log.Printf("cleanup audit: %v", err)
	}
	a.pairs.cleanup(now)
	for _, l := range []*limiter{a.loginLimiter, a.ipLimiter, a.pairLimiter, a.codeLimiter, a.pwLimiter} {
		l.cleanup()
	}
}
