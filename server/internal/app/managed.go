package app

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"math"
	"net/url"
	"regexp"
	"sort"
	"strings"
)

// Admin-managed configuration (see PROTOCOL.md §5).
//
// The admin keeps Dispatcharr connections (+ per-user credentials), an addon library and
// managed settings on the server. For every affected user the server materialises them as
// ordinary sync records — servers/<uuid>, secrets/server:<uuid>, addons/<transportUrl>,
// settings/<key> — flagged records.managed = 1. reconcileUser is the single place that
// computes what a user should have and writes the difference (new rev, long polls woken).
// Members' devices can't overwrite or delete managed records (see handlePush).

const managedDevice = "server" // device_id stamped on records written by the server

// ---- settings schema ------------------------------------------------------------------

type settingSpec struct {
	Key     string   `json:"key"`
	Label   string   `json:"label"`
	Type    string   `json:"type"` // bool | string | int | number | enum
	Options []string `json:"options,omitempty"`
	Min     float64  `json:"min,omitempty"`
	Max     float64  `json:"max,omitempty"`
}

// syncedSettings are the settings keys of PROTOCOL.md §3 with the value types the apps accept.
var syncedSettings = []settingSpec{
	{Key: "metadataLanguage", Label: "Metadata language", Type: "string"},
	{Key: "metadataSource", Label: "Metadata source", Type: "enum", Options: []string{"provider", "tmdb", "cinemeta"}},
	{Key: "maxResolution", Label: "Max resolution", Type: "int", Min: 1, Max: 10000},
	{Key: "excludeCam", Label: "Exclude CAM releases", Type: "bool"},
	{Key: "streamSort", Label: "Stream sort", Type: "enum", Options: []string{"quality", "fastest", "size", "seeders", "addon"}},
	{Key: "autoplayNext", Label: "Autoplay next episode", Type: "bool"},
	{Key: "resumePlayback", Label: "Resume playback", Type: "bool"},
	{Key: "seekStep", Label: "Seek step (seconds)", Type: "int", Min: 1, Max: 600},
	{Key: "skipIntros", Label: "Skip intros", Type: "bool"},
	{Key: "autoSkip", Label: "Auto-skip", Type: "bool"},
	{Key: "audioLanguage", Label: "Audio language", Type: "string"},
	{Key: "subtitleLanguage", Label: "Subtitle language", Type: "string"},
	{Key: "autoSubtitles", Label: "Automatic subtitles", Type: "bool"},
	{Key: "subtitleScale", Label: "Subtitle size", Type: "number", Min: 0.1, Max: 5},
	{Key: "hideAdult", Label: "Hide adult content", Type: "bool"},
	{Key: "trailerAutoplay", Label: "Autoplay trailers", Type: "bool"},
	{Key: "torrentMode", Label: "Torrent mode", Type: "enum", Options: []string{"embedded", "remote"}},
	{Key: "remoteTorrServer", Label: "Remote TorrServer URL", Type: "string"},
}

func settingSpecFor(key string) (settingSpec, bool) {
	for _, s := range syncedSettings {
		if s.Key == key {
			return s, true
		}
	}
	return settingSpec{}, false
}

// validateSettingValue checks a value against the key's type and returns it compacted.
func validateSettingValue(key string, raw json.RawMessage) (json.RawMessage, error) {
	spec, ok := settingSpecFor(key)
	if !ok {
		return nil, fmt.Errorf("%q is not a synced settings key", key)
	}
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		return nil, fmt.Errorf("%s: invalid JSON value", key)
	}
	bad := func(want string) error { return fmt.Errorf("%s must be %s", key, want) }
	switch spec.Type {
	case "bool":
		if _, ok := v.(bool); !ok {
			return nil, bad("true or false")
		}
	case "string":
		s, ok := v.(string)
		if !ok || len(s) > 2048 {
			return nil, bad("a string")
		}
	case "enum":
		s, ok := v.(string)
		found := false
		for _, o := range spec.Options {
			found = found || (ok && s == o)
		}
		if !found {
			return nil, bad("one of " + strings.Join(spec.Options, ", "))
		}
	case "int", "number":
		f, ok := v.(float64)
		if !ok || math.IsNaN(f) || f < spec.Min || f > spec.Max || (spec.Type == "int" && f != math.Trunc(f)) {
			return nil, bad(fmt.Sprintf("a number between %g and %g", spec.Min, spec.Max))
		}
	}
	var buf bytes.Buffer
	if err := json.Compact(&buf, raw); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// ---- helpers --------------------------------------------------------------------------

var uuidRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

func newUUID() string {
	b := randBytes(16)
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

func validAuthMode(m string) bool { return m == "xc" || m == "web" || m == "apiKey" }

// normalizeServerURL validates a Dispatcharr base URL (http/https with a host).
func normalizeServerURL(raw string) (string, bool) {
	s := strings.TrimRight(strings.TrimSpace(raw), "/")
	if len(s) > 1024 {
		return "", false
	}
	u, err := url.Parse(s)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return "", false
	}
	return s, true
}

// serverSecret is the data of secrets/server:<uuid> (and the plaintext of an assignment's
// encrypted credentials).
type serverSecret struct {
	XcPassword  string `json:"xcPassword"`
	WebPassword string `json:"webPassword"`
	APIKey      string `json:"apiKey"`
}

const assignmentAAD = "dispatcharr"

func (a *App) sealAssignment(userID, serverID string, s serverSecret) string {
	b, _ := json.Marshal(s)
	return a.encrypt(userID, assignmentAAD, serverID, b)
}

func (a *App) openAssignment(userID, serverID, stored string) (serverSecret, error) {
	var s serverSecret
	if stored == "" {
		return s, nil
	}
	plain, err := a.decrypt(userID, assignmentAAD, serverID, stored)
	if err != nil {
		return s, err
	}
	err = json.Unmarshal(plain, &s)
	return s, err
}

type managedServerData struct {
	Name     string `json:"name"`
	URL      string `json:"url"`
	Username string `json:"username"`
	AuthMode string `json:"authMode"`
	Order    int    `json:"order"`
	Managed  bool   `json:"managed"`
}

type managedAddonData struct {
	TransportURL string `json:"transportUrl"`
	Name         string `json:"name"`
	Enabled      bool   `json:"enabled"`
	Order        int    `json:"order"`
	Managed      bool   `json:"managed"`
}

type managedSettingData struct {
	Value   json.RawMessage `json:"value"`
	Managed bool            `json:"managed"`
}

func recKey(collection, id string) string { return collection + "\x00" + id }

func splitRecKey(k string) (string, string) {
	c, id, _ := strings.Cut(k, "\x00")
	return c, id
}

// queryer is satisfied by *sql.DB and *sql.Tx.
type queryer interface {
	Query(query string, args ...any) (*sql.Rows, error)
	QueryRow(query string, args ...any) *sql.Row
	Exec(query string, args ...any) (sql.Result, error)
}

// addonDisplayName is the name written into records and shown in the admin.
func addonDisplayName(name, manifestName, transportURL string) string {
	if name != "" {
		return name
	}
	if manifestName != "" {
		return manifestName
	}
	if u, err := url.Parse(transportURL); err == nil && u.Host != "" {
		return u.Host
	}
	return "Addon"
}

// ---- desired state ----------------------------------------------------------------------

// desiredManaged computes the managed records a user should have. keep lists records whose
// desired state can't be computed right now (undecryptable credentials): they are left alone.
func (a *App) desiredManaged(q queryer, userID string) (desired map[string][]byte, keep map[string]bool, err error) {
	desired = map[string][]byte{}
	keep = map[string]bool{}

	type srvRow struct {
		id, name, url, mode, username, secret string
		order                                 int
	}
	var srvs []srvRow
	rows, err := q.Query(`SELECT s.id, s.name, s.url, s.sort_order, x.auth_mode, x.username, x.secret
		FROM dispatcharr_assignments x JOIN dispatcharr_servers s ON s.id = x.server_id
		WHERE x.user_id = ?`, userID)
	if err != nil {
		return nil, nil, err
	}
	for rows.Next() {
		var r srvRow
		if err := rows.Scan(&r.id, &r.name, &r.url, &r.order, &r.mode, &r.username, &r.secret); err != nil {
			rows.Close()
			return nil, nil, err
		}
		srvs = append(srvs, r)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}
	for _, r := range srvs {
		b, _ := json.Marshal(managedServerData{Name: r.name, URL: r.url, Username: r.username, AuthMode: r.mode, Order: r.order, Managed: true})
		desired[recKey("servers", r.id)] = b
		sec, err := a.openAssignment(userID, r.id, r.secret)
		if err != nil {
			a.log.Printf("decrypt dispatcharr credentials %s for %s: %v", r.id, userID, err)
			keep[recKey(secretsCollection, "server:"+r.id)] = true
			continue
		}
		sb, _ := json.Marshal(sec)
		desired[recKey(secretsCollection, "server:"+r.id)] = sb
	}

	rows, err = q.Query(`SELECT transport_url, name, manifest_name, sort_order FROM addon_library l
		WHERE l.all_users = 1 OR EXISTS (SELECT 1 FROM addon_assignments x WHERE x.addon_id = l.id AND x.user_id = ?)`, userID)
	if err != nil {
		return nil, nil, err
	}
	for rows.Next() {
		var tu, name, mname string
		var order int
		if err := rows.Scan(&tu, &name, &mname, &order); err != nil {
			rows.Close()
			return nil, nil, err
		}
		b, _ := json.Marshal(managedAddonData{TransportURL: tu, Name: addonDisplayName(name, mname, tu), Enabled: true, Order: order, Managed: true})
		desired[recKey("addons", tu)] = b
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}

	rows, err = q.Query(`SELECT key, value FROM managed_settings WHERE user_id = ?`, userID)
	if err != nil {
		return nil, nil, err
	}
	for rows.Next() {
		var key, value string
		if err := rows.Scan(&key, &value); err != nil {
			rows.Close()
			return nil, nil, err
		}
		b, _ := json.Marshal(managedSettingData{Value: json.RawMessage(value), Managed: true})
		desired[recKey("settings", key)] = b
	}
	rows.Close()
	return desired, keep, rows.Err()
}

// ---- reconcile ----------------------------------------------------------------------------

type existingRec struct {
	data      sql.NullString
	deleted   bool
	managed   bool
	updatedAt int64
}

type recWrite struct {
	collection, id string
	data           []byte // plaintext JSON; nil = tombstone
	managed        bool
	prevUpdatedAt  int64
}

// ---- dismissals ---------------------------------------------------------------------------
//
// A user may remove a managed item from their account ("Continue without it" in the apps).
// Their device pushes dismissed/<collection>|<id> {"collection","id","dismissedAt"}; while that
// record exists (not deleted) reconcile leaves the item out for this user: servers (+ their
// secrets) and addons are tombstoned, settings are released. Tombstoning the dismissal (the
// app's "Restore from sync", or the admin's "Push again") brings the item back.

const dismissedCollection = "dismissed"

// dismissible lists the collections whose managed records a user may dismiss.
func dismissible(collection string) bool {
	return collection == "servers" || collection == "addons" || collection == "settings"
}

// parseDismissedID splits a dismissal id "<collection>|<id>". Addon ids never contain a raw
// "|" (it is percent-encoded), server ids are UUIDs and settings keys are plain words.
func parseDismissedID(id string) (collection, itemID string, ok bool) {
	c, item, found := strings.Cut(id, "|")
	if !found || item == "" || !dismissible(c) {
		return "", "", false
	}
	if c == "servers" {
		item = strings.ToLower(item)
	}
	return c, item, true
}

// dismissalIDFor returns the dismissal id that covers a record ("" if none can): secrets of a
// Dispatcharr server are covered by the server's dismissal.
func dismissalIDFor(collection, id string) string {
	if collection == secretsCollection {
		if sid, ok := strings.CutPrefix(id, "server:"); ok {
			return "servers|" + strings.ToLower(sid)
		}
		return ""
	}
	if !dismissible(collection) {
		return ""
	}
	if collection == "servers" {
		id = strings.ToLower(id)
	}
	return collection + "|" + id
}

type dismissalRow struct {
	id          string // "<collection>|<itemId>" as stored
	updatedAt   int64
	dismissedAt int64
}

// activeDismissals returns the user's dismissals that are in effect, keyed by record key of
// the dismissed item.
func activeDismissals(q queryer, userID string) (map[string]dismissalRow, error) {
	rows, err := q.Query(`SELECT id, data, updated_at FROM records WHERE user_id = ? AND collection = ? AND deleted = 0`, userID, dismissedCollection)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]dismissalRow{}
	for rows.Next() {
		var d dismissalRow
		var data sql.NullString
		if err := rows.Scan(&d.id, &data, &d.updatedAt); err != nil {
			return nil, err
		}
		c, item, ok := parseDismissedID(d.id)
		if !ok {
			continue
		}
		if data.Valid {
			var m struct {
				DismissedAt int64 `json:"dismissedAt"`
			}
			_ = json.Unmarshal([]byte(data.String), &m)
			d.dismissedAt = m.DismissedAt
		}
		if d.dismissedAt == 0 {
			d.dismissedAt = d.updatedAt
		}
		out[recKey(c, item)] = d
	}
	return out, rows.Err()
}

// reconcileUser brings the user's managed records in line with the admin configuration and
// returns how many records were written. Records that stop being managed are tombstoned
// (servers, secrets, addons) or released — kept with their value but no longer locked
// (settings).
func (a *App) reconcileUser(userID string) (int, error) {
	return a.reconcileUserClearing(userID, nil)
}

// reconcileUserClearing is reconcileUser that first lifts the given dismissals (ids
// "<collection>|<itemId>"), so those items are written for the user again.
func (a *App) reconcileUserClearing(userID string, clear []string) (int, error) {
	tx, err := a.db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()

	desired, keep, err := a.desiredManaged(tx, userID)
	if err != nil {
		return 0, err
	}
	dismissals, err := activeDismissals(tx, userID)
	if err != nil {
		return 0, err
	}
	clearSet := map[string]bool{}
	for _, id := range clear {
		if c, item, ok := parseDismissedID(id); ok {
			clearSet[recKey(c, item)] = true
		}
	}
	// Dismissals: lifted ones and those whose item is no longer assigned are tombstoned (a
	// later assignment then reaches the user again); the others take the item out of desired.
	var writes []recWrite
	for _, k := range sortedKeys(dismissals) {
		d := dismissals[k]
		if _, assigned := desired[k]; !assigned || clearSet[k] {
			writes = append(writes, recWrite{collection: dismissedCollection, id: d.id, prevUpdatedAt: d.updatedAt})
			continue
		}
		delete(desired, k)
		if c, id := splitRecKey(k); c == "servers" {
			sk := recKey(secretsCollection, "server:"+id)
			delete(desired, sk)
			delete(keep, sk)
		}
	}
	existing := map[string]existingRec{}
	rows, err := tx.Query(`SELECT collection, id, data, deleted, managed, updated_at FROM records
		WHERE user_id = ? AND collection IN ('servers', 'secrets', 'addons', 'settings')`, userID)
	if err != nil {
		return 0, err
	}
	for rows.Next() {
		var c, id string
		var e existingRec
		var del, man int
		if err := rows.Scan(&c, &id, &e.data, &del, &man, &e.updatedAt); err != nil {
			rows.Close()
			return 0, err
		}
		e.deleted, e.managed = del != 0, man != 0
		existing[recKey(c, id)] = e
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}

	for _, k := range sortedKeys(desired) {
		want := desired[k]
		c, id := splitRecKey(k)
		ex, ok := existing[k]
		if ok && ex.managed && !ex.deleted && a.storedEquals(userID, c, id, ex.data, want) {
			continue
		}
		writes = append(writes, recWrite{collection: c, id: id, data: want, managed: true, prevUpdatedAt: ex.updatedAt})
	}
	exKeys := make([]string, 0, len(existing))
	for k := range existing {
		exKeys = append(exKeys, k)
	}
	sort.Strings(exKeys)
	for _, k := range exKeys {
		ex := existing[k]
		if _, want := desired[k]; want || keep[k] || !ex.managed {
			continue
		}
		c, id := splitRecKey(k)
		if ex.deleted {
			// An admin deleted their own managed copy: just drop the flag.
			if _, err := tx.Exec(`UPDATE records SET managed = 0 WHERE user_id = ? AND collection = ? AND id = ?`, userID, c, id); err != nil {
				return 0, err
			}
			continue
		}
		w := recWrite{collection: c, id: id, prevUpdatedAt: ex.updatedAt}
		if c == "settings" {
			w.data = releasedSetting(ex.data.String)
		}
		writes = append(writes, w)
	}
	if len(writes) == 0 {
		return 0, tx.Commit()
	}

	var rev int64
	if err := tx.QueryRow(`SELECT rev FROM users WHERE id = ?`, userID).Scan(&rev); err != nil {
		return 0, err
	}
	now := a.nowMs()
	for _, w := range writes {
		rev++
		var data any
		deleted, managed := 0, 0
		switch {
		case w.data == nil:
			deleted = 1
		case w.collection == secretsCollection:
			data = a.encrypt(userID, w.collection, w.id, w.data)
		default:
			data = string(w.data)
		}
		if w.managed {
			managed = 1
		}
		ua := max(now, w.prevUpdatedAt+1)
		if _, err := tx.Exec(`INSERT INTO records(user_id, collection, id, data, deleted, updated_at, rev, device_id, stored_at, managed)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(user_id, collection, id) DO UPDATE SET
				data = excluded.data, deleted = excluded.deleted, updated_at = excluded.updated_at,
				rev = excluded.rev, device_id = excluded.device_id, stored_at = excluded.stored_at,
				managed = excluded.managed`,
			userID, w.collection, w.id, data, deleted, ua, rev, managedDevice, now, managed); err != nil {
			return 0, err
		}
	}
	if _, err := tx.Exec(`UPDATE users SET rev = ? WHERE id = ?`, rev, userID); err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	a.hub.notify(userID)
	return len(writes), nil
}

func (a *App) storedEquals(userID, collection, id string, stored sql.NullString, want []byte) bool {
	if !stored.Valid {
		return false
	}
	if collection == secretsCollection {
		plain, err := a.decrypt(userID, collection, id, stored.String)
		return err == nil && bytes.Equal(plain, want)
	}
	return stored.String == string(want)
}

// releasedSetting drops the "managed" marker from a settings record, keeping its value.
func releasedSetting(stored string) []byte {
	var m map[string]json.RawMessage
	if err := json.Unmarshal([]byte(stored), &m); err != nil || m == nil {
		return []byte(`{"value":null}`)
	}
	delete(m, "managed")
	b, _ := json.Marshal(m)
	return b
}

func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// reconcileUsers reconciles each user, returning the first error (after trying all).
func (a *App) reconcileUsers(ids []string) error {
	var first error
	seen := map[string]bool{}
	for _, id := range ids {
		if seen[id] {
			continue
		}
		seen[id] = true
		if _, err := a.reconcileUser(id); err != nil {
			a.log.Printf("reconcile managed records for %s: %v", id, err)
			if first == nil {
				first = err
			}
		}
	}
	return first
}

func (a *App) allUserIDs() ([]string, error) {
	return a.queryStrings(`SELECT id FROM users ORDER BY created_at`)
}

func (a *App) queryStrings(query string, args ...any) ([]string, error) {
	rows, err := a.db.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// provisionUser applies "all users" configuration to a freshly created user: the default
// managed settings and the addons assigned to everyone.
func (a *App) provisionUser(userID string) error {
	if _, err := a.db.Exec(`INSERT OR IGNORE INTO managed_settings(user_id, key, value, updated_at)
		SELECT ?, key, value, ? FROM default_settings`, userID, a.nowMs()); err != nil {
		return err
	}
	_, err := a.reconcileUser(userID)
	return err
}
