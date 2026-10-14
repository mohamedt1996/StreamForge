package app

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"time"
	"unicode/utf8"
)

const secretsCollection = "secrets"

// Record is a synced record as sent to clients.
type Record struct {
	Collection string          `json:"collection"`
	ID         string          `json:"id"`
	Data       json.RawMessage `json:"data"`
	Deleted    bool            `json:"deleted"`
	UpdatedAt  int64           `json:"updatedAt"`
	Rev        int64           `json:"rev"`
	Device     string          `json:"device"`
}

type pullResponse struct {
	Rev     int64    `json:"rev"`
	Records []Record `json:"records"`
	More    bool     `json:"more"`
}

var collectionRe = regexp.MustCompile(`^[a-z][a-zA-Z0-9_.-]{0,63}$`)

// ---- pull --------------------------------------------------------------------------------

func (a *App) handlePull(w http.ResponseWriter, r *http.Request, p *principal) {
	if !p.device.has("read") {
		writeErr(w, http.StatusForbidden, "scope_missing", "this device does not have the read scope")
		return
	}
	q := r.URL.Query()
	since, err := parseIntParam(q.Get("since"), 0)
	if err != nil || since < 0 {
		writeErr(w, http.StatusBadRequest, "bad_request", "since must be a non-negative integer")
		return
	}
	limit, err := parseIntParam(q.Get("limit"), defaultLimit)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "limit must be an integer")
		return
	}
	if limit < 1 {
		limit = 1
	}
	if limit > defaultLimit {
		limit = defaultLimit
	}
	wait, err := parseIntParam(q.Get("wait"), 0)
	if err != nil || wait < 0 {
		writeErr(w, http.StatusBadRequest, "bad_request", "wait must be 0..55")
		return
	}
	if wait > maxWaitSeconds {
		wait = maxWaitSeconds
	}
	a.touchSync(p.user.ID)

	ctx := r.Context()
	var timer *time.Timer
	if wait > 0 {
		timer = time.NewTimer(time.Duration(wait) * time.Second)
		defer timer.Stop()
	}
	for {
		// Subscribe before querying so a push between the query and the wait is never missed.
		wake := a.hub.subscribe(p.user.ID)
		res, err := a.pull(p.user.ID, since, int(limit), p.device.has("secrets"))
		if err != nil {
			writeInternal(w, a, "pull", err)
			return
		}
		// Answer right away when there is anything new (including filtered-out secrets, so the
		// client's rev advances), when the client is ahead of us (e.g. restored backup), or when
		// this is not a long poll.
		if len(res.Records) > 0 || res.Rev != since || timer == nil {
			writeJSON(w, http.StatusOK, res)
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
			writeJSON(w, http.StatusOK, res)
			return
		case <-wake:
			// Something changed for this user: re-validate the device (it may have been revoked
			// or re-scoped while we were waiting), then query again.
			fresh, err := a.lookupToken(p.tokenHash)
			if err != nil {
				if errors.Is(err, errUnauthorized) {
					writeErr(w, http.StatusUnauthorized, "unauthorized", "missing, invalid or revoked token")
				} else {
					writeInternal(w, a, "pull revalidate", err)
				}
				return
			}
			if !fresh.device.has("read") {
				writeErr(w, http.StatusForbidden, "scope_missing", "this device does not have the read scope")
				return
			}
			p.device.Scopes = fresh.device.Scopes
		}
	}
}

func parseIntParam(s string, def int64) (int64, error) {
	if s == "" {
		return def, nil
	}
	return strconv.ParseInt(s, 10, 64)
}

func (a *App) pull(userID string, since int64, limit int, includeSecrets bool) (pullResponse, error) {
	var userRev int64
	if err := a.db.QueryRow(`SELECT rev FROM users WHERE id = ?`, userID).Scan(&userRev); err != nil {
		return pullResponse{}, err
	}
	res := pullResponse{Rev: userRev, Records: []Record{}}
	if since >= userRev {
		return res, nil
	}
	// Bounding by userRev (read first) guarantees we never skip a rev that is assigned but
	// committed after this query: everything <= users.rev is committed in the same transaction.
	query := `SELECT collection, id, data, deleted, updated_at, rev, device_id FROM records
		WHERE user_id = ? AND rev > ? AND rev <= ?`
	if !includeSecrets {
		query += ` AND collection <> 'secrets'`
	}
	query += ` ORDER BY rev LIMIT ?`
	rows, err := a.db.Query(query, userID, since, userRev, limit+1)
	if err != nil {
		return res, err
	}
	defer rows.Close()
	// Paging is decided on rows scanned, not records returned: a skipped (undecryptable) secret
	// must not make us report "no more" while unread rows remain beyond the LIMIT.
	scanned := 0
	var lastScanned int64
	for rows.Next() {
		var rec Record
		var data sql.NullString
		var deleted int
		if err := rows.Scan(&rec.Collection, &rec.ID, &data, &deleted, &rec.UpdatedAt, &rec.Rev, &rec.Device); err != nil {
			return res, err
		}
		if scanned == limit {
			res.More = true
			break
		}
		scanned++
		lastScanned = rec.Rev
		rec.Deleted = deleted != 0
		rec.Data = json.RawMessage("null")
		if !rec.Deleted && data.Valid {
			if rec.Collection == secretsCollection {
				plain, err := a.decrypt(userID, rec.Collection, rec.ID, data.String)
				if err != nil {
					// Wrong/rotated key or corruption: never send garbage, skip the record.
					a.log.Printf("decrypt %s/%s for %s: %v", rec.Collection, rec.ID, userID, err)
					continue
				}
				rec.Data = json.RawMessage(plain)
			} else {
				rec.Data = json.RawMessage(data.String)
			}
		}
		res.Records = append(res.Records, rec)
	}
	if err := rows.Err(); err != nil {
		return res, err
	}
	if res.More {
		res.Rev = lastScanned
	}
	return res, nil
}

// touchSync records the user's last sync time (throttled).
func (a *App) touchSync(userID string) {
	now := a.nowMs()
	if _, err := a.db.Exec(`UPDATE users SET last_sync_at = ? WHERE id = ? AND last_sync_at < ?`, now, userID, now-10_000); err != nil {
		a.log.Printf("touch sync: %v", err)
	}
}

// ---- push --------------------------------------------------------------------------------

type pushRecord struct {
	Collection string          `json:"collection"`
	ID         string          `json:"id"`
	Data       json.RawMessage `json:"data"`
	Deleted    bool            `json:"deleted"`
	UpdatedAt  int64           `json:"updatedAt"`
}

type pushResult struct {
	Collection string `json:"collection"`
	ID         string `json:"id"`
	Status     string `json:"status"`
	Rev        int64  `json:"rev"`
}

func (a *App) handlePush(w http.ResponseWriter, r *http.Request, p *principal) {
	if !p.device.has("write") {
		writeErr(w, http.StatusForbidden, "scope_missing", "this device does not have the write scope")
		return
	}
	var req struct {
		Records []pushRecord `json:"records"`
	}
	if !decodeJSON(w, r, maxPushBody, &req) {
		return
	}
	if len(req.Records) > maxPushRecords {
		writeErr(w, http.StatusBadRequest, "too_many_records", fmt.Sprintf("at most %d records per push", maxPushRecords))
		return
	}
	for i := range req.Records {
		rec := &req.Records[i]
		if !collectionRe.MatchString(rec.Collection) {
			writeErr(w, http.StatusBadRequest, "invalid_record", fmt.Sprintf("records[%d]: invalid collection", i))
			return
		}
		if rec.ID == "" || len(rec.ID) > 512 || !utf8.ValidString(rec.ID) {
			writeErr(w, http.StatusBadRequest, "invalid_record", fmt.Sprintf("records[%d]: id must be 1–512 bytes of UTF-8", i))
			return
		}
		if rec.UpdatedAt <= 0 {
			writeErr(w, http.StatusBadRequest, "invalid_record", fmt.Sprintf("records[%d]: updatedAt must be a positive ms timestamp", i))
			return
		}
		if rec.Deleted {
			rec.Data = nil
			continue
		}
		trimmed := bytes.TrimSpace(rec.Data)
		if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
			writeErr(w, http.StatusBadRequest, "invalid_record", fmt.Sprintf("records[%d]: data is required unless deleted", i))
			return
		}
		if len(trimmed) > maxRecordData {
			writeErr(w, http.StatusRequestEntityTooLarge, "record_too_large", fmt.Sprintf("records[%d]: data exceeds 256 KB", i))
			return
		}
		rec.Data = trimmed
	}
	a.touchSync(p.user.ID)

	canSecrets := p.device.has("secrets")
	nowMs := a.nowMs()
	maxTS := a.now().Add(futureSkew).UnixMilli()

	tx, err := a.db.Begin()
	if err != nil {
		writeInternal(w, a, "push begin", err)
		return
	}
	defer tx.Rollback()
	var rev int64
	if err := tx.QueryRow(`SELECT rev FROM users WHERE id = ?`, p.user.ID).Scan(&rev); err != nil {
		writeInternal(w, a, "push rev", err)
		return
	}
	startRev := rev
	results := make([]pushResult, 0, len(req.Records))
	for _, rec := range req.Records {
		res := pushResult{Collection: rec.Collection, ID: rec.ID}
		if rec.Collection == secretsCollection && !canSecrets {
			// Without the secrets scope a device can neither read nor write secrets. Reported as
			// "stale" so protocol-conforming clients drop it from their outbox.
			res.Status = "stale"
			results = append(results, res)
			continue
		}
		ua := rec.UpdatedAt
		if ua > maxTS {
			ua = maxTS
		}
		var storedUA, storedRev int64
		err := tx.QueryRow(`SELECT updated_at, rev FROM records WHERE user_id = ? AND collection = ? AND id = ?`,
			p.user.ID, rec.Collection, rec.ID).Scan(&storedUA, &storedRev)
		switch {
		case err == nil && ua <= storedUA:
			res.Status, res.Rev = "stale", storedRev
			results = append(results, res)
			continue
		case err != nil && !errors.Is(err, sql.ErrNoRows):
			writeInternal(w, a, "push lookup", err)
			return
		}
		rev++
		var data any // NULL for tombstones
		deleted := 0
		if rec.Deleted {
			deleted = 1
		} else if rec.Collection == secretsCollection {
			data = a.encrypt(p.user.ID, rec.Collection, rec.ID, rec.Data)
		} else {
			data = string(rec.Data)
		}
		if _, err := tx.Exec(`INSERT INTO records(user_id, collection, id, data, deleted, updated_at, rev, device_id, stored_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(user_id, collection, id) DO UPDATE SET
				data = excluded.data, deleted = excluded.deleted, updated_at = excluded.updated_at,
				rev = excluded.rev, device_id = excluded.device_id, stored_at = excluded.stored_at`,
			p.user.ID, rec.Collection, rec.ID, data, deleted, ua, rev, p.device.ID, nowMs); err != nil {
			writeInternal(w, a, "push upsert", err)
			return
		}
		res.Status, res.Rev = "applied", rev
		results = append(results, res)
	}
	if rev != startRev {
		if _, err := tx.Exec(`UPDATE users SET rev = ? WHERE id = ?`, rev, p.user.ID); err != nil {
			writeInternal(w, a, "push rev update", err)
			return
		}
	}
	if err := tx.Commit(); err != nil {
		writeInternal(w, a, "push commit", err)
		return
	}
	if rev != startRev {
		a.hub.notify(p.user.ID)
	}
	writeJSON(w, http.StatusOK, map[string]any{"rev": rev, "results": results})
}
