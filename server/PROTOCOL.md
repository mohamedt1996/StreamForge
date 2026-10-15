# StreamForge Sync — protocol v1

A self-hosted server that keeps watch progress, library, addons, Dispatcharr servers and settings
in step across iPhone, iPad, Apple TV and Android, with accounts and per-device access control.

**Local-first.** Every app keeps working from its own on-device data. Sync is a background
exchange of *records*; a device that is offline simply catches up later. Nothing in the app ever
waits on the server.

All bodies are JSON (`Content-Type: application/json`). Times are **milliseconds since the Unix
epoch**. Authenticated calls send `Authorization: Bearer <device token>`.

Errors: `{"error": "human readable message", "code": "machine_code"}` with a 4xx/5xx status.
`401` = token missing/revoked (client signs out locally but **keeps its data**), `403` = scope
missing, `429` = rate limited (honour `Retry-After`).

---

## 1. Accounts, devices and access control

* **Users** have a role: `admin` or `member`. Each user has their own completely separate data.
  The first account is created by the setup page (or `STREAMFORGE_ADMIN_USER` /
  `STREAMFORGE_ADMIN_PASSWORD` env on first start). Admins create other users; open sign-up is
  off unless `STREAMFORGE_OPEN_SIGNUP=true`.
* **Devices.** Every sign-in creates a device with its own random token (stored hashed with
  SHA-256 on the server). Devices can be listed, renamed, restricted and revoked at any time.
* **Scopes** (per device):
  * `read` — may pull records.
  * `write` — may push records.
  * `secrets` — may pull/push the `secrets` collection (Dispatcharr passwords, API keys, PINs,
    Trakt token). A device without it never receives a single secret.
  Default for a password sign-in: all three. Pairing approval can grant fewer.

### Sign in with password
`POST /api/auth/login`
```json
{"username": "mo", "password": "…", "device": {"name": "Mo's iPhone", "platform": "ios"}}
```
→ `200 {"token": "sf_…", "user": User, "device": Device}`
`platform` ∈ `ios`, `ipados`, `tvos`, `android`, `androidtv`, `web`.

### Pair a TV (no keyboard needed)
1. TV: `POST /api/auth/pair/start` `{"device": {...}}` → `{"pairId": "…", "code": "K7Q-4MX", "expiresIn": 600}`
   The TV shows the code (and the server URL).
2. Any signed-in device (phone app or the web admin):
   `POST /api/pair/approve` `{"code": "K7Q-4MX", "scopes": ["read","write","secrets"]}` → `200 {"device": Device}`
   (the new device belongs to the approver's user).
3. TV polls `GET /api/auth/pair/{pairId}` every 2 s:
   `202 {"status": "pending"}` · `200 {"status": "approved", "token": "…", "user": User, "device": Device}` · `410` expired/denied.

### Me / sign out
* `GET /api/me` → `{"user": User, "device": Device, "server": {"name": "...", "version": "1.0.0"}}`
* `POST /api/auth/logout` → revokes the calling device.

### Devices
* `GET /api/devices` → `{"devices": [Device]}` (own user's; admins may pass `?user=<id>`)
* `PATCH /api/devices/{id}` `{"name"?: "...", "scopes"?: [...]}` → `Device`
* `DELETE /api/devices/{id}` → `204` (token stops working immediately)

### Users (admin only)
* `GET /api/users` → `{"users": [User]}`
* `POST /api/users` `{"username", "password", "role"}` → `User`
* `PATCH /api/users/{id}` `{"password"?, "role"?, "disabled"?}` → `User` (disabling revokes all its devices)
* `DELETE /api/users/{id}` → `204` (deletes the user's data)
* Any user: `POST /api/me/password` `{"current", "new"}` → `204`

```
User   = {"id": "u_…", "username": "mo", "role": "admin", "disabled": false, "createdAt": 0}
Device = {"id": "d_…", "name": "Living room TV", "platform": "tvos", "scopes": ["read","write"],
          "createdAt": 0, "lastSeenAt": 0, "lastIp": "…", "current": true}
```

---

## 2. Sync

### Record
```json
{
  "collection": "progress",
  "id": "default|movie:tt0111161",
  "data": { ... } ,
  "deleted": false,
  "updatedAt": 1739999999999,
  "rev": 1234,
  "device": "d_…"
}
```
* `(collection, id)` identifies a record. `data` is collection-specific JSON (below); `null` when deleted.
* **Conflict rule: last writer wins by `updatedAt`** (the client's clock when the user made the
  change). The server stores a pushed record only if its `updatedAt` is greater than the stored
  one (ties: keep stored). The server clamps `updatedAt` to at most `now + 5 min`.
* `rev` is a server-wide, per-user monotonically increasing counter assigned when a record is stored.
* Deletions are tombstones (`deleted: true`), kept 180 days.

### Pull
`GET /api/sync?since=<rev>&limit=1000&wait=<0..55>`
→ `200 {"rev": 1300, "records": [Record], "more": false}`
* Returns records with `rev > since`, ordered by `rev`. `more: true` → call again with the returned `rev`.
* `wait` > 0 = long poll: if nothing is newer the server holds the request up to `wait` seconds and
  answers as soon as any device of the same user pushes.
* Records the device pushed itself are included (harmless; clients compare `updatedAt`).
* Without the `secrets` scope the `secrets` collection is filtered out.

### Push
`POST /api/sync` `{"records": [ {collection, id, data, deleted, updatedAt} ]}` (≤ 500 per call)
→ `200 {"rev": 1310, "results": [{"collection","id","status": "applied"|"stale", "rev": 1309}]}`
* `stale` = server already has a newer version; the client should take the server copy on its next pull.
* Max 256 KB per record `data`, 2 MB per request.

### Client algorithm (both platforms)
1. Keep `lastRev` and an **outbox** of local changes (collection, id, data, deleted, updatedAt) on disk.
2. Every local change → upsert into the outbox (replacing an older entry for the same key) → push
   debounced ~3 s. Remove outbox entries that came back `applied` or `stale`.
3. Pull loop while the app is in the foreground: `GET /api/sync?since=lastRev&wait=50`; apply each
   record only if its `updatedAt` > the local copy's `updatedAt` (keep a per-record `updatedAt` map
   locally); save `lastRev`. On network errors back off 5 s → 60 s.
4. **First sign-in on a device:** queue *every* local record into the outbox (so nothing on this
   device is lost), then pull from `since=0`; LWW decides each record.
5. Applying remote records must not re-queue them in the outbox.
6. Sign-out keeps all local data.

---

## 3. Collections

`profile` is the local profile UUID (lowercase) or `"default"` for single-profile setups.

### Canonical item key (shared by both platforms)
* Movie/series with an IMDb id: `movie:tt0111161`, `series:tt0944947`
* else TMDB: `movie:tmdb:278`
* else Dispatcharr: `movie:dispatcharr:<serverUUID>:<streamId>`, `series:dispatcharr:<serverUUID>:<seriesId>`
* else addon meta id: `series:meta:<metaId>`
* Episode: series key + `:s<season>e<episode>` e.g. `series:tt0944947:s1e2`

### Item (embedded so another device can show the card without fetching anything)
```json
{"key": "movie:tt0111161", "type": "movie"|"series", "title": "…", "year": 1994,
 "poster": "https://…", "backdrop": "https://…", "logo": "https://…",
 "imdbId": "tt0111161", "tmdbId": 278, "runtimeMinutes": 142,
 "origin": {"kind": "dispatcharrMovie"|"dispatcharrSeries"|"addon"|"tmdb"|"other",
            "serverId": "uuid", "streamId": 12, "ext": "mkv", "addonId": "…", "metaId": "…", "metaType": "movie"}}
```
Unknown fields are ignored; missing optional fields are fine.

| collection | id | data |
|---|---|---|
| `progress` | `<profile>\|<itemKey or episodeKey>` | `{"profile", "item": Item, "episode": {"season", "episode", "title", "still", "dispatcharrEpisodeId", "ext"}?, "position": secs, "duration": secs}` |
| `watched` | `<profile>\|<itemKey or episodeKey>` | `{"profile", "key"}` — delete = unwatched |
| `favorites` | `<profile>\|<itemKey>` | `{"profile", "item": Item, "addedAt": ms}` — delete = removed |
| `channels` | `<profile>\|<serverUUID>\|<channelId>` | `{"profile", "serverId", "channelId", "favorite": true}` — delete = unfavourited |
| `addons` | transport (manifest) URL | `{"transportUrl", "name", "enabled": true, "order": 0}` — clients fetch the manifest themselves |
| `servers` | Dispatcharr server UUID (lowercase) | `{"name", "url", "username", "authMode": "xc"|"web"|"apiKey", "order": 0}` |
| `profiles` | profile UUID | `{"name", "avatar", "color", "kids": false}` |
| `settings` | key below | `{"value": any}` |
| `secrets` | `server:<uuid>`, `key:tmdb`, `key:omdb`, `key:fanart`, `trakt`, `pin:<profile>`, `parentPin` | `{"xcPassword","webPassword","apiKey"}` / `{"value": "…"}` / Trakt token object |

Synced `settings` keys (each client maps those it has; others are ignored):
`metadataLanguage`, `metadataSource`, `maxResolution`, `excludeCam`, `streamSort`, `autoplayNext`,
`resumePlayback`, `seekStep`, `skipIntros`, `autoSkip`, `audioLanguage`, `subtitleLanguage`,
`autoSubtitles`, `subtitleScale`, `hideAdult`, `trailerAutoplay`, `torrentMode`, `remoteTorrServer`.
Device-specific things (active server, active profile, hardware decoding, last channel) never sync.

---

## 4. Server

* Single Go binary / Docker image `ghcr.io/mohamedt1996/streamforge-sync`, SQLite in `/data`.
* Env: `STREAMFORGE_ADDR` (`:8484`), `STREAMFORGE_DATA` (`/data`), `STREAMFORGE_ADMIN_USER`,
  `STREAMFORGE_ADMIN_PASSWORD`, `STREAMFORGE_OPEN_SIGNUP`, `STREAMFORGE_NAME`,
  `STREAMFORGE_TRUST_PROXY` (use `X-Forwarded-For`).
* The `secrets` collection is encrypted at rest (AES-256-GCM, key in `/data/secret.key`).
* Web admin at `/`: sign in, approve TV pairing codes, manage devices/scopes, users (with a per-user
  detail page), Dispatcharr connections, the addon library, default settings (§5), change password.
* Dispatcharr credentials of admin assignments are encrypted at rest like the `secrets` collection.
* `GET /healthz` → `ok`. Put it behind HTTPS (reverse proxy) when exposed outside your LAN.

---

## 5. Admin-managed configuration

Admins can manage Dispatcharr connections, addons and settings centrally on the server and push
them to specific users. The server materialises them as **ordinary records** in each affected
user's store, so clients need no new endpoints: they pull them like anything else.

| what the admin manages | records written into the user's store |
|---|---|
| Dispatcharr connection assigned to the user | `servers/<uuid>` `{"name","url","username","authMode","order","managed":true}` and `secrets/server:<uuid>` `{"xcPassword","webPassword","apiKey"}` (the user's own credentials for that connection) |
| Addon from the library (assigned to the user, or to all users) | `addons/<transportUrl>` `{"transportUrl","name","enabled":true,"order","managed":true}` |
| Managed setting | `settings/<key>` `{"value": any, "managed": true}` |

* Every write gets `updatedAt = max(now, stored updatedAt + 1)`, a new `rev` and wakes the user's
  long polls; `device` is `"server"`.
* Pulled records that are managed also carry a top-level `"managed": true` (clients may use it to
  hide delete/edit controls). The `secrets` collection is still filtered for devices without the
  `secrets` scope.
* **Removal.** Unassigning a connection or addon, deleting it, or switching an addon off "all
  users" writes **tombstones** (`servers` + `secrets`, or `addons`) for the affected users. Releasing
  a managed setting re-writes `settings/<key>` as `{"value": …}` (same value, no longer managed).
  Afterwards the user owns those ids again.
* **Enforcement.** A push to a managed record from a device whose user is not an admin is not
  stored. Instead the server re-stamps the stored copy (`updatedAt = max(now, incoming.updatedAt + 1,
  stored.updatedAt + 1)`, new `rev`) and answers `stale`; the device then pulls the managed version
  back (it is newer than its local change) and restores it. Admins' own devices may change managed
  records of their own account normally (the next admin change to that configuration overwrites them).
* **Addon ids** are normalised exactly like the apps do: trim; `stremio://` → `https://`; add
  `https://` when there is no scheme; strip trailing `/` and `/manifest.json`; append
  `/manifest.json`; percent-encode (UTF-8, upper-case hex) every character that is not an ASCII
  letter/digit or one of ``-._~!$&'()*+,;=:@/?#%[]`` — e.g.
  `stremio://torrentio.strem.fun/sort=size|qualityfilter=cam` →
  `https://torrentio.strem.fun/sort=size%7Cqualityfilter=cam/manifest.json`.
* "All users" addons and the default settings are applied to users created later (setup, admin
  creation, open sign-up). Default settings reach existing users only via *apply*.

### Endpoints (admin only, every change is written to the activity log)

Credentials are write-only: responses only say whether each is set
(`hasXcPassword`, `hasWebPassword`, `hasApiKey`).

**Dispatcharr connections**
* `GET /api/admin/dispatcharr` → `{"servers": [Server]}`
* `POST /api/admin/dispatcharr` `{"name", "url", "id"?: uuid, "order"?}` → `Server`
* `PATCH /api/admin/dispatcharr/{id}` `{"name"?, "url"?, "order"?}` → `Server` (rewrites records of assigned users)
* `DELETE /api/admin/dispatcharr/{id}` → `204` (tombstones for assigned users)
* `PUT /api/admin/dispatcharr/{id}/users/{userId}` `{"authMode"?: "xc"|"web"|"apiKey", "username"?, "xcPassword"?, "webPassword"?, "apiKey"?}` → `Assignment`.
  Creates or updates the assignment; omitted fields keep their value, `""` clears a credential.
* `DELETE /api/admin/dispatcharr/{id}/users/{userId}` → `204`

```
Server     = {"id": "uuid", "name", "url", "order", "createdAt", "updatedAt", "assignments": [Assignment]}
Assignment = {"serverId", "serverName", "serverUrl", "userId", "user": "<username>", "authMode",
              "username": "<Dispatcharr account>", "hasXcPassword", "hasWebPassword", "hasApiKey", "updatedAt"}
```

**Addon library**
* `GET /api/admin/addons` → `{"addons": [Addon]}`
* `POST /api/admin/addons` `{"url", "name"?, "allUsers"?, "order"?, "users"?: [userId]}` → `Addon`.
  The manifest is fetched server-side (5 s timeout) for name/logo/description; failure is recorded
  in `fetchError` and doesn't block. `409 addon_exists` (with `id`) if the normalised URL is already in the library.
* `PATCH /api/admin/addons/{id}` `{"name"?, "allUsers"?, "order"?}` → `Addon`
* `POST /api/admin/addons/{id}/refresh` → `Addon` (fetch the manifest again)
* `DELETE /api/admin/addons/{id}` → `204`
* `PUT` / `DELETE /api/admin/addons/{id}/users/{userId}` → `204`

```
Addon = {"id": "a_…", "transportUrl", "name", "customName", "manifestName", "manifestId", "version",
         "description", "logo": "data:image/…" | "", "allUsers", "order", "fetchedAt", "fetchError",
         "createdAt", "updatedAt", "users": [{"id", "username"}]}
```

**Settings** (keys and value types: §3)
* `GET /api/admin/settings` → `{"keys": [{"key","label","type","options"?,"min"?,"max"?}], "defaults": {key: value}}`
* `PUT /api/admin/settings/defaults` `{"values": {key: value | null}}` → same as GET (`null` removes a default)
* `POST /api/admin/settings/defaults/apply` `{"users"?: [userId]}` → `{"users": n}` — writes the
  defaults as managed settings of existing users (all users when omitted)
* `PUT /api/admin/users/{id}/settings` `{"values": {key: value | null}}` → `{"settings": [UserSetting]}` (`null` releases)

**Per user**
* `GET /api/admin/users/{id}` → `{"user", "devices", "stats", "dispatcharr": [Assignment], "servers": [...],
  "addons": [{"transportUrl","name","enabled","order","managed","libraryId","logo","source": "all"|"direct"|""}],
  "libraryAddons": [...], "settings": [UserSetting]}` where
  `UserSetting = {key, label, type, …, "value": <synced value>|null, "managed", "managedValue"|null}`
* `POST /api/admin/users/{id}/copy` `{"from": userId, "addons"?: true, "servers"?: true, "settings"?: true}`
  → `{"addons": n, "servers": n, "settings": n}` — assigns the other user's current addons,
  Dispatcharr servers (with their credentials; connections are created for servers the library
  doesn't know yet, keeping their UUID) and synced settings as managed configuration.
* `POST /api/users` additionally accepts `"dispatcharr": [{"serverId","authMode","username","xcPassword"?,"webPassword"?,"apiKey"?}]`
  and `"addons": ["a_…"]` to assign right away.
