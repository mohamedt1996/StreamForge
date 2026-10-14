# StreamForge

A native SwiftUI media hub for **iPhone, iPad and Apple TV**:

- **Dispatcharr IPTV**: live channels, a full TV guide grid, catch-up, DVR scheduling and playback, movies and series.
- **Stremio addons**: install any addon by manifest link; catalogs, metadata, streams and subtitles.
- **Torrent streaming**: TorrServer's engine runs *inside the app* on iPhone/iPad, or use a remote TorrServer (required on Apple TV).
- **Metadata from several sources**: your IPTV provider, TMDB, Cinemeta, OMDb (IMDb/RT/Metacritic scores), Fanart.tv logos, with a user-defined priority order.
- **mpv player** (libmpv via MPVKit): Metal/MoltenVK rendering, VideoToolbox hardware decoding, HDR10/HLG/Dolby Vision, ASS subtitles, chapters, audio/subtitle delay, stats overlay.
- **Trakt**: device sign-in, scrobbling, watchlist.

Android TV is planned as a separate native app (phase 2).

## How the pieces fit

| Area | Implementation |
| --- | --- |
| Dispatcharr | Xtream Codes API (`player_api.php`) for live/EPG/VOD/series/catch-up; REST API (JWT) for DVR recordings |
| Addons | Stremio addon protocol: `manifest`, `catalog`, `meta`, `stream`, `subtitles` |
| Torrents | `TorrServerKit.xcframework` (TorrServer built with gomobile), started on `127.0.0.1:8091`; same HTTP API for remote servers |
| Player | `MPVKit` (LGPL build), `vo=gpu-next`, `gpu-context=moltenvk`, `hwdec=videotoolbox` |
| Images | Nuke with a 600 MB disk cache |

## Setting up

1. **Dispatcharr**: Settings → Dispatcharr → Add Server. Use the Dispatcharr username and that user's **XC password** (set in Dispatcharr under Users → edit → XC Password). Add the web password too if you want DVR.
2. **Addons**: Cinemeta and OpenSubtitles are installed by default. Paste any other addon's manifest link in Settings → Addons, or open a `stremio://` link.
3. **Metadata**: add a free TMDB key (themoviedb.org → Settings → API) for artwork, cast, trailers and trending. OMDb and Fanart.tv keys are optional.
4. **Torrents**: iPhone/iPad work out of the box. Apple TV needs a TorrServer address (e.g. `http://192.168.1.10:8090`).

## Building

Everything builds in GitHub Actions on macOS (see `.github/workflows/build.yml`), which produces unsigned `.ipa` files for iOS and tvOS as workflow artifacts. Sign/sideload them with your tool of choice (AltStore, SideStore, Sideloadly, etc.).

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
