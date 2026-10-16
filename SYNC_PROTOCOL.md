# StreamForge Sync — protocol v1

A self-hosted server (`server/`) that keeps watch progress, library, addons, Dispatcharr servers,
shared settings and profiles in sync across iOS, iPadOS, tvOS, Android and Android TV.

**Local-first.** Every app keeps reading and writing its own on-device stores exactly as before. Sync
runs in the background: when the server is reachable the device pushes its changes and pulls everyone
else's; when it isn't, nothing breaks and changes queue until it is.

## Records

All data travels as small, platform-neutral records. A record is one thing (one title's progress, one
addon, one server), so two devices editing different things never conflict.

```json
{
  "collection": "progress",
  "id": "default|movie:tt0111161",
  "data": { "...": "collection-specific JSON object" },
  "updatedAt": 1760440000000,
  "deleted": false,
  "deviceId": "8F1C…",
  "seq": 4182
}
```

- `updatedAt` — Unix **milliseconds** of the change on the device that made it.
- `deleted` — tombstone; `data` is `null` when deleted.
- `seq` — set by the server only: a per-user, strictly increasing change number used for incremental pulls.
- **Conflict rule (last writer wins, per record):** the server keeps an incoming record only when
  `incoming.updatedAt > stored.updatedAt`, or they are equal and `incoming.deviceId > stored.deviceId`
  (string compare). Clients apply pulled records with the same rule against their local copy.
- Unknown collections, unknown `data` fields and unknown settings keys must be ignored (forward compatible).

### Media keys

Progress and library records refer to titles by a key both platforms can derive:

| Title | Key |
|---|---|
| Movie with IMDb id | `movie:tt0111161` |
| Movie with TMDB id only | `movie:tmdb:278` |
| Episode | `episode:<series key without "series:">:<season>:<episode>` e.g. `episode:tt0903747:1:2` |
| Series | `series:tt0903747` / `series:tmdb:1396` |
| Anything else | `<type>:id:<app item id>` (only that platform's own id; may not match across platforms) |

### Profiles

Profile id `default` is the main profile (Android, which has no profiles, always uses it; on Apple the
first/owner profile maps to `default`, other profiles use their UUID string).

### Collections

| collection | id | data |
|---|---|---|
| `progress` | `<profile>\|<mediaKey>` | `{ "profile", "position": seconds, "duration": seconds, "watched": bool, "item": MediaRef, "episode": {"season","episode","title"}? }` |
| `library` | `<profile>\|<list>\|<mediaKey>` | `{ "profile", "list": "watchlist"\|"favorites", "item": MediaRef, "addedAt": ms }` |
| `channels` | `<profile>\|<serverId>:<channelId>` | `{ "profile", "serverId", "channelId": int, "name", "logo"? }` (favorite live channels) |
| `addons` | manifest URL | `{ "url", "name"?, "enabled": bool, "order": int }` |
| `servers` | server UUID (lowercase) | `{ "name", "url", "username", "xcPassword", "webPassword", "apiKey", "authMode"? }` (Dispatcharr) |
| `settings` | setting key | `{ "value": any JSON }` |
| `profiles` | profile id | `{ "name", "avatar"?, "kids": bool, "pin"? }` |

`MediaRef` = `{ "key", "type": "movie"|"series"|"episode"|"channel", "title", "year"?, "poster"?, "backdrop"?, "imdbId"?, "tmdbId"?, "appId"? }`

Shared `settings` keys (each platform syncs those it has): `tmdbKey`, `omdbKey`, `fanartKey`,
`metadataLanguage`, `audioLanguage`, `subtitleLanguage`, `autoSubtitles`, `maxResolution`, `excludeCam`,
`autoplayNext`, `seekStep`, `skipIntros`, `autoSkip`, `torrentMode`, `remoteTorrServer`, `hideAdult`.

## HTTP API

Base: `https://your-host/api/v1`. JSON in and out. Auth: `Authorization: Bearer <token>`.
Errors: `{ "error": "message" }` with a 4xx/5xx status.

### Auth and devices
- `POST /auth/login` `{ "username", "password", "device": { "id", "name", "platform" } }`
  → `{ "token", "user": User, "device": Device }`
- `POST /auth/logout` → revokes the calling device's token.
- `GET /me` → `{ "user": User, "device": Device }`
- `POST /auth/password` `{ "current", "new" }`
- `GET /devices` → `{ "devices": [Device] }` · `DELETE /devices/{id}` → revoke (signs that device out)

### TV-style pairing (no typing passwords on a TV)
1. TV: `POST /pair/request` `{ "device": {...} }` (no auth) → `{ "code": "K7M-4QX", "pollToken", "expiresAt" }`
2. Signed-in phone or the web admin: `POST /pair/approve` `{ "code" }` (auth)
3. TV polls `POST /pair/poll` `{ "pollToken" }` every 3 s → `202 {"status":"pending"}` until approved, then
   `{ "token", "user", "device" }`. Codes expire after 10 minutes.

### Sync
- `POST /sync` `{ "records": [Record…] }` (≤ 1000 per call)
  → `{ "seq", "accepted": int, "rejected": [{ "collection", "id", "reason" }], "newer": [Record…] }`
  (`newer` = records the server kept because its copy was newer; apply them.)
- `GET /sync?since=<seq>&limit=<n>&wait=<seconds>` → `{ "seq", "records": [Record…], "more": bool }`
  Records with `seq > since`, oldest first. `wait` (≤ 30) long-polls: the call returns as soon as
  something changes, or empty after `wait` seconds. Records pushed by the calling device are included
  (clients ignore ones that aren't newer).

### Access control
- Roles: `admin` (manages users) and `member`.
- `User` = `{ "id", "username", "role", "disabled", "permissions": { "<collection>": "rw"|"r"|"none" } }`.
  Missing collections default to `rw`. The server rejects writes to collections without `w` and leaves
  collections without `r` out of pulls. Typical use: give a family member `servers: "r"` so they receive
  your Dispatcharr setup but can't change it, or `servers: "none"` so they never see its passwords.
- Every device has its own revocable token (stored hashed). Disabling a user or deleting a device signs it
  out immediately.
- Admin: `GET/POST /admin/users`, `PATCH/DELETE /admin/users/{id}` (`role`, `disabled`, `permissions`,
  `password`), `GET /admin/users/{id}/devices`, `DELETE /admin/devices/{id}`.
- Record data is encrypted at rest (AES-256-GCM, key in `SF_SECRET` or `data/secret.key`). Serve it over
  HTTPS (reverse proxy) — Dispatcharr passwords travel inside `servers` records.

## Client behaviour

1. Sign in (password or pairing). Store the token in the Keychain / encrypted prefs.
2. **First sync:** push a full snapshot of local records, then pull from `since=0`.
3. **Change tracking:** build the record set from local stores, compare each record's content hash with
   the last synced hash, and push only the changed ones (with `updatedAt` = the domain timestamp when one
   exists, e.g. last-watched time, otherwise now). Debounce ~3 s after local changes.
4. **Pull:** on launch, on foreground, every few minutes, and via long-poll while the app is active. Apply
   only records newer than the local copy, then remember their hashes so applying them doesn't echo back.
5. Offline or server errors: keep working from local data and retry later with backoff.
6. Secrets (`servers` passwords, API keys) never wipe local values with empty strings.
