# StreamForge Sync

A small self-hosted server that keeps watch progress, watched state, favourites, addons, Dispatcharr
servers, profiles, settings and (optionally) secrets in step across StreamForge on iPhone, iPad,
Apple TV and Android — with user accounts and per-device access control.

* Single static Go binary (or a ~10 MB distroless Docker image), SQLite in one data directory.
* Every app keeps working offline; sync is a background exchange of records (see [PROTOCOL.md](PROTOCOL.md)).
* Web admin at `/`: first-run setup, sign in, devices (rename / scopes / revoke), pair a TV, users
  (with a per-user page), Dispatcharr, addons, default settings, account, activity log, overview.
* Secrets (Dispatcharr passwords, API keys, PINs, Trakt token) are encrypted at rest with
  AES-256-GCM and only reach devices that have the `secrets` scope.
* Admin-managed configuration: manage Dispatcharr connections (with per-user credentials), an
  addon library and settings on the server and push them to chosen users (or everyone) — see below.

## Run it

### Docker

```sh
docker run -d --name streamforge-sync --restart unless-stopped \
  -p 8484:8484 -v streamforge-data:/data \
  ghcr.io/mohamedt1996/streamforge-sync:latest
```

Open `http://<host>:8484`, create the admin account on the setup page, done.

The image runs as an unprivileged user (uid `65532`). With a named volume (as above) permissions
are handled for you. If you bind-mount a host directory instead, make it writable for that uid:
`mkdir -p ./data && sudo chown 65532:65532 ./data`.

### Docker Compose

See [`docker-compose.yml`](docker-compose.yml):

```sh
docker compose up -d
```

### Binary

Download `streamforge-sync-<os>-<arch>` from the GitHub release (Linux amd64/arm64, macOS arm64,
Windows amd64) or build it yourself (Go 1.24+, no C compiler needed):

```sh
cd server
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=1.0.0" -o streamforge-sync .
STREAMFORGE_DATA=./data ./streamforge-sync
```

`streamforge-sync -version` prints the version; `streamforge-sync healthcheck` exits 0 when the
local server answers `/healthz` (used by the Docker `HEALTHCHECK`).

## Configuration

All configuration is via environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `STREAMFORGE_ADDR` | `:8484` | Listen address. |
| `STREAMFORGE_DATA` | `/data` | Data directory (database + encryption key). Created with mode `0700`. |
| `STREAMFORGE_NAME` | `StreamForge Sync` | Display name shown in the apps (`/api/me`) and the web admin. |
| `STREAMFORGE_ADMIN_USER` / `STREAMFORGE_ADMIN_PASSWORD` | – | Create the first admin on start-up **if the server has no users yet** (instead of the setup page). Ignored afterwards; safe to remove once set up. Password ≥ 8 characters. |
| `STREAMFORGE_OPEN_SIGNUP` | `false` | `true` lets anyone who can reach the server create a (member) account via `POST /api/auth/signup`. Otherwise admins create users. |
| `STREAMFORGE_TRUST_PROXY` | `false` | `true` = take the client IP from `X-Forwarded-For` (right-most entry, i.e. what your proxy saw). Only enable behind a reverse proxy, otherwise clients can spoof their IP (which matters for rate limiting and the activity log). |

> **First run:** until an account exists, *anyone* who can reach the server can complete the setup
> page. Do the setup right after starting it, or use `STREAMFORGE_ADMIN_USER`/`_PASSWORD`, before
> exposing it to the internet.

## Put it behind HTTPS

Keep the server on your LAN, or put a TLS-terminating reverse proxy in front before exposing it.
Tokens and passwords travel in every request, so **never expose plain HTTP to the internet**.

[Caddy](https://caddyserver.com) gets and renews certificates automatically:

```caddyfile
sync.example.com {
	reverse_proxy 127.0.0.1:8484
}
```

Then run the server with `STREAMFORGE_TRUST_PROXY=true` and, ideally, bind it to localhost only
(`-p 127.0.0.1:8484:8484` or `STREAMFORGE_ADDR=127.0.0.1:8484`). Compose with Caddy:

```yaml
services:
  streamforge-sync:
    image: ghcr.io/mohamedt1996/streamforge-sync:latest
    restart: unless-stopped
    environment:
      STREAMFORGE_TRUST_PROXY: "true"
    volumes: [ "streamforge-data:/data" ]
  caddy:
    image: caddy:2
    restart: unless-stopped
    ports: [ "80:80", "443:443" ]
    command: caddy reverse-proxy --from sync.example.com --to streamforge-sync:8484
    volumes: [ "caddy-data:/data" ]
volumes:
  streamforge-data:
  caddy-data:
```

Long polls hold requests for up to 55 s; Caddy's defaults are fine. For nginx set
`proxy_read_timeout 90s;` and `proxy_buffering off;` on the location.

## Back up

Everything lives in the data directory:

* `streamforge.db` (+ `-wal`/`-shm` while running) — users, devices, records, activity.
* `secret.key` — 32-byte AES key for the `secrets` collection (mode `0600`). **Back it up together
  with the database.** Without it, encrypted secrets can't be read (everything else still works,
  and devices simply re-upload their secrets).

The safest backup is a consistent snapshot while running:

```sh
docker run --rm -v streamforge-data:/data -v "$PWD":/backup alpine \
  sh -c 'apk add -q sqlite && sqlite3 /data/streamforge.db ".backup /backup/streamforge.db" && cp /data/secret.key /backup/'
```

or stop the container and copy the whole directory. To restore, put both files back into an empty
data directory. Devices whose `lastRev` is ahead of a restored server automatically resync.

## Connect the apps

**iPhone / iPad / Android:** in StreamForge's sync settings enter the server URL (e.g.
`https://sync.example.com` or `http://192.168.1.10:8484`), then your username and password. The
first sign-in uploads everything already on the device, then pulls what's on the server — newest
change wins per item, nothing is lost. Signing out keeps all local data.

**Apple TV / Android TV (no keyboard):** choose *pair with a code* in the TV's sync settings. The
TV shows a code like `K7Q-4MX` (valid 10 minutes). Approve it from the phone app or from the web
admin's **Pair a TV** page, choosing what the TV may do:

* **Read** — receive library, progress and settings.
* **Write** — send changes back.
* **Secrets** — receive Dispatcharr passwords, API keys, PINs and the Trakt token. Leave it off for
  shared or kids' TVs; they'll never receive a single secret.

Scopes can be changed or the device revoked at any time under **Devices**. A revoked device is
signed out immediately (its next request gets `401`) but keeps its local data.

## Manage what your users get

Admins can configure things once on the server and have them appear on every device a user signs
in to — no typing Dispatcharr URLs or addon links on a TV:

* **Dispatcharr** page — add connections (name + URL), then tick the users who should get each one.
  Every assignment has that person's own Dispatcharr account: sign-in method (XC / web account /
  API key), username and password or key. Credentials are encrypted at rest, never shown again in
  the browser (only "set"/"not set"), and only reach devices with the **Secrets** scope.
* **Addons** page — an addon library. Paste a manifest link (configured links and `stremio://`
  work); the server reads the manifest to show its name and logo. Tick users in the matrix, or
  give an addon to **all users**, including users created later.
* **Default settings** page — synced app settings (§3 of the protocol) applied to every new user;
  *Push to all existing users* applies them to everyone now.
* **Users → Manage** — one page per user: devices, Dispatcharr assignments, addons (managed vs. their
  own), current synced settings with managed overrides, record counts, and *Copy from user…* to give
  them the same addons/servers/settings as someone else. When creating a user you can pick
  connections and addons to assign right away.

Managed items are **locked** on members' devices: if a device removes or changes one, the server
refuses the change and sends the managed version back, so it reappears on the next sync. Removing
an assignment removes it from the user's devices. Admins' own devices may change managed items of
their own account. Details and the API: [PROTOCOL.md §5](PROTOCOL.md#5-admin-managed-configuration).

## Security notes

* Device tokens are 256-bit random values (`sf_…`), stored only as SHA-256 hashes. Passwords use bcrypt.
* Sign-in is rate limited: 10 failures per IP+username and 50 per IP per 15 minutes (`429` + `Retry-After`).
* Pairing codes avoid ambiguous characters, expire after 10 minutes, are single-use and the token is
  handed to the TV exactly once; wrong codes are rate limited per user.
* A device can only grant scopes it holds itself (a restricted TV can't escalate itself).
* Disabling a user revokes all of their devices; deleting a user deletes all of their data.
* Request bodies are size limited (2 MB per push, 256 KB per record, 500 records per push).
* The web admin is served with a strict Content-Security-Policy, no third-party resources, and keeps
  its token in `sessionStorage` (gone when the tab closes).
* Tombstones are purged after 180 days, activity entries after a year.

## API

The full contract is in [PROTOCOL.md](PROTOCOL.md). Additional endpoints used by the web admin:

| Endpoint | |
|---|---|
| `GET /api/setup` | `{"needsSetup", "openSignup", "name", "version"}` |
| `POST /api/setup` | `{"username", "password", "device"?}` → same as login; only while no users exist (`409` afterwards). |
| `POST /api/auth/signup` | Same body/response as login; only with `STREAMFORGE_OPEN_SIGNUP=true` (`403` otherwise). |
| `GET /api/stats[?user=]` | Record counts per collection, `rev`, `lastSyncAt`, device count. |
| `GET /api/audit[?limit=&before=&user=]` | Activity log (admins: everyone; members: own account). |
| `/api/admin/…` | Admin-managed configuration (Dispatcharr connections and assignments, addon library, managed/default settings, per-user view, copy from user) — see [PROTOCOL.md §5](PROTOCOL.md#5-admin-managed-configuration). |

## Development

```sh
cd server
go vet ./...
go test ./...
```


### Built-in backups and operations

Admins can open **Overview** for server-wide health and **Devices** for each device's
last successful sync. **Dispatcharr → Test connection** checks each saved assignment;
**Addons → Test & refresh** verifies its manifest.

**Backups** creates and downloads a consistent SQLite snapshot with its matching
`secret.key` and a version manifest. Optional daily backups run on an hourly check
(and at server startup); the seven newest completed ZIPs are kept in `/data/backups`.
Enable the schedule in the page. A manual snapshot also counts toward daily cadence.
Only admins with the Secrets scope can manage or download backups. Archives contain
credentials and device tokens; keep them private and copy one off the server.

To restore: stop the server, preserve the current data directory, extract the database
and key together into a **new empty private directory**, and point `STREAMFORGE_DATA`
(or Docker's `/data` mount) at it. Do not include old `-wal`/`-shm` files. Start the same
or a newer server version, verify `/healthz`, then check users and provider tests.
Permissions and tokens are restored too: revoke devices that no longer need access.
The web page includes these steps. There is deliberately no live database replacement.
