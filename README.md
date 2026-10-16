# StreamForge

A media hub for **iPhone, iPad, Apple TV, Android phones/tablets and Android TV** (native SwiftUI on Apple, Kotlin + Compose on Android):

- **Dispatcharr IPTV**: live channels, a full TV guide grid, catch-up, DVR scheduling and playback, movies and series.
- **Stremio addons**: install any addon by manifest link; catalogs, metadata, streams and subtitles.
- **Torrent streaming**: TorrServer's engine runs *inside the app* on iPhone/iPad, or use a remote TorrServer (required on Apple TV).
- **Metadata from several sources**: your IPTV provider, TMDB, Cinemeta, OMDb (IMDb/RT/Metacritic scores), Fanart.tv logos, with a user-defined priority order.
- **mpv player** (libmpv via MPVKit): Metal/MoltenVK rendering, VideoToolbox hardware decoding, HDR10/HLG/Dolby Vision, ASS subtitles, chapters, audio/subtitle delay, stats overlay.
- **Trakt**: device sign-in, scrobbling, watchlist.

### Also on Apple platforms
- Player: skip intro/recap/credits (TheIntroDB, chapter names, your own per-series markers), subtitle styling, audio boost and night mode, AirPlay, frame-rate and HDR matching on Apple TV, Picture-in-Picture (also for MKV and live TV via mpv's software renderer).
- Live TV: full XMLTV guide from Dispatcharr (cached, refreshed every few hours), multiview (2–4 channels), pause and rewind live TV, number entry and last-channel, programme reminders, sports and event highlighting.
- Movies and series: collections/franchises, Trakt Up Next with new-episode badges, person pages that show what's on your server, trailer autoplay.
- Profiles with PINs and kids mode, iCloud sync (needs a build signed with iCloud), local-network sync and backups, widgets, Apple TV Top Shelf, Siri ("Play BBC One in StreamForge"), downloads for offline viewing.

### Android
Live TV with the full guide, catch-up and DVR, the organized movie/series library, Stremio addons, on-device or remote torrent streaming with a live status tab, TMDB metadata (collections, person pages), and an mpv player with skip intro, subtitle styling, night mode and volume boost, live rewind, channel number entry / last channel, and Picture-in-Picture on phones. Profiles, sync, widgets and multiview are Apple-only for now.

## How the pieces fit

| Area | Implementation |
| --- | --- |
| Dispatcharr | Xtream Codes API (`player_api.php`) for live/EPG/VOD/series/catch-up when the user has an XC password; otherwise the REST API (`/api/channels`, `/api/vod`, `/api/epg`), `/output/epg` and the stream proxy (`/proxy/ts`, `/proxy/vod`), without catch-up. REST API (JWT / API key) for DVR recordings |
| Addons | Stremio addon protocol: `manifest`, `catalog`, `meta`, `stream`, `subtitles` |
| Torrents | `TorrServerKit.xcframework` (TorrServer built with gomobile), started on `127.0.0.1:8091`; same HTTP API for remote servers |
| Player | `MPVKit` (LGPL build), `vo=gpu-next`, `gpu-context=moltenvk`, `hwdec=videotoolbox` |
| Images | Nuke with a 600 MB disk cache |

## Setting up

1. **Dispatcharr**: Settings → Dispatcharr → Add Server and sign in with your normal Dispatcharr **username and password** (or an API key). No XC password is needed: the app reads it from your account if there is one (admins without one get one created); otherwise it streams through Dispatcharr's own API and stream proxy (everything except catch-up). The full TV guide downloads in the background and refreshes every few hours.
2. **Addons**: Cinemeta and OpenSubtitles are installed by default. Paste any other addon's manifest link in Settings → Addons, or open a `stremio://` link.
3. **Metadata**: add a free TMDB key (themoviedb.org → Settings → API) for artwork, cast, trailers and trending. OMDb and Fanart.tv keys are optional.
4. **Torrents**: iPhone/iPad work out of the box. Apple TV needs a TorrServer address (e.g. `http://192.168.1.10:8090`).

## Building

Everything builds in GitHub Actions (see `.github/workflows/build.yml`). Every green build of `main` publishes a GitHub release with unsigned `.ipa` files for iOS and tvOS (sign/sideload them with AltStore, SideStore, Sideloadly, etc.) and signed Android APKs.

Android APKs are signed with the sideload key in `android/app/streamforge-release.jks` (password in `android/app/build.gradle.kts`) so updates install over older versions. To use your own key, add `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_PASSWORD` secrets and replace the keystore.

Widgets, Top Shelf and iCloud sync rely on an App Group and iCloud entitlements; they work when the app is signed with a paid Apple Developer account that has those capabilities. Free sideloading usually strips them; everything else keeps working.

Locally (macOS with Xcode 16+, Go 1.25+, Node 20):

```bash
brew install xcodegen
bash scripts/build-torrserverkit.sh   # builds Frameworks/TorrServerKit.xcframework (~10 min, once)
xcodegen generate
open StreamForge.xcodeproj
```

If Metal API Validation crashes on HDR content in Debug, turn it off in the scheme's Run → Diagnostics (a known MoltenVK issue).

## Project layout

```
Sources/Shared/
  App/          entry point, tabs, routing, deep links
  Core/         HTTP, tolerant JSON decoding, storage, settings, shared models
  Dispatcharr/  XC + REST clients, library store (cached, deduped, grouped)
  Stremio/      addon protocol models and manager
  Metadata/     TMDB, OMDb, Fanart.tv, Trakt, merging service
  Torrent/      TorrServer client + embedded engine lifecycle
  Player/       libmpv wrapper, player model, player UI, source ranking
  Features/     Home, Live TV + Guide, Movies/Series, Detail, Search, Library, Settings
Sources/iOS, Sources/tvOS   small platform shims
```

## Licensing notes

<<<<<<< HEAD
<<<<<<< HEAD
<<<<<<< HEAD
MPVKit's LGPL build links mpv/FFmpeg dynamically-compatible static libraries; TorrServer is GPL-3.0. If you distribute builds, comply with those licenses (publish this source alongside your binaries).
<<<<<<< HEAD
=======
Download `streamforge-sync-<os>-<arch>` from the GitHub release (Linux amd64/arm64, macOS arm64,
Windows amd64) or build it yourself (Go 1.24+, no C compiler needed):
>>>>>>> parent of b79227c (Add files via upload)
=======
Download `streamforge-sync-<os>-<arch>` from the GitHub release (Linux amd64/arm64, macOS arm64,
Windows amd64) or build it yourself (Go 1.24+, no C compiler needed):
>>>>>>> parent of b79227c (Add files via upload)

```sh
cd server
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=1.0.0" -o streamforge-sync .
STREAMFORGE_DATA=./data ./streamforge-sync
```

<<<<<<< HEAD
<<<<<<< HEAD
Android My List now includes removal with Undo. Poster-grid context previews and player trailer controls use native AVPlayer on Apple platforms; direct trailer media is supported, and YouTube native previews need an Invidious instance configured in Settings. See [issue changes and device QA](docs/ISSUES-QA.md) for behavior, regression coverage and current build-verification limitations.
=======
>>>>>>> parent of 217256e (Add files via upload)
=======
=======
>>>>>>> parent of b79227c (Add files via upload)
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
<<<<<<< HEAD
>>>>>>> parent of b79227c (Add files via upload)
=======
>>>>>>> parent of b79227c (Add files via upload)
=======
MPVKit's LGPL build links mpv/FFmpeg dynamically-compatible static libraries; TorrServer is GPL-3.0. If you distribute builds, comply with those licenses (publish this source alongside your binaries).
>>>>>>> parent of 217256e (Add files via upload)
