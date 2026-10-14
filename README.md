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
| Dispatcharr | Xtream Codes API (`player_api.php`) for live/EPG/VOD/series/catch-up; REST API (JWT) for DVR recordings |
| Addons | Stremio addon protocol: `manifest`, `catalog`, `meta`, `stream`, `subtitles` |
| Torrents | `TorrServerKit.xcframework` (TorrServer built with gomobile), started on `127.0.0.1:8091`; same HTTP API for remote servers |
| Player | `MPVKit` (LGPL build), `vo=gpu-next`, `gpu-context=moltenvk`, `hwdec=videotoolbox` |
| Images | Nuke with a 600 MB disk cache |

## Setting up

1. **Dispatcharr**: Settings → Dispatcharr → Add Server and sign in with your normal Dispatcharr **username and password** (or an API key). The app reads your XC streaming password from your account automatically (admins without one get one created). The full TV guide downloads in the background and refreshes every few hours.
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

MPVKit's LGPL build links mpv/FFmpeg dynamically-compatible static libraries; TorrServer is GPL-3.0. If you distribute builds, comply with those licenses (publish this source alongside your binaries).
