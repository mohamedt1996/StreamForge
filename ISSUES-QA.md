# Issue fixes and verification — 16 October 2026

Base: `feature/wave2`, commit `57e2c730120cf99f5bd24ef1cc7ac12ff1fd18a8`.
Includes the previous unpushed 20-file bug-fix commit `5ca7bde`.

## Changes

- Android My List shelves: swipe removal on touch devices; explicit Remove button for touch, accessibility and TV remotes. Changes use existing persisted/synced Library storage. A theme-owned snackbar keeps Undo alive after the removed card disappears. Undo uses an explicit saved state rather than a blind toggle.
- Android shared typography and artwork fallback for missing/loading/failed artwork. Existing rounded cards, focus effects and responsive spacing are retained.
- Android compile/target SDK 37, minSdk 26 unchanged. Added Android 17 local-network runtime permission request, denial guidance, and catalog refresh after grant or returning from Settings. Existing network security configuration retains user-configured HTTP server compatibility. Reference: https://developer.android.com/privacy-and-security/local-network-permission
- iOS poster-grid long-press previews and pointer-hover previews: muted, looping AVPlayer; obey existing autoplay/data/kids policy. Existing context-menu actions remain available. Hover previews are suppressed during main playback.
- iOS/tvOS player: Play Trailer overlay and Back to Full, preserving main playback position and pause state. Trailer playback is separate from watch history and progress. Player controls appear after main playback starts, outside kids mode.
- Optional direct trailer URL metadata on MediaItem and PlaybackSource; older saved data remains compatible. Provider/addon direct MP4/M4V/MOV/HLS URLs are separated from YouTube IDs. YouTube URLs are not sent to AVPlayer: native playback resolves through the user's configured Invidious instance, otherwise shows an unavailable message. Existing detail-page web trailers remain intact.
- Preview cleanup on disappearance, background pause, failure/timeout display, cancelled artwork lookup protection.
- Source reload generation guards and subtitle reset; stale subtitle results and cancelled resolution errors cannot mutate a newer playback session. Stop invalidates pending loads.
- Stream text size parsing rejects numeric overflow instead of trapping on Int64 conversion.
- Previous fixes: profile PIN gates, kids download visibility, server-specific resume/playback, HLS download completion, download pause/resume races, PiP pause state, duplicate multiview slots, Android sub-second seek bounds.

## Automated verification

`git diff --check`, project YAML/manifest parsing and cumulative patch application verification are run locally. This Linux environment has no Xcode/Swift or Android SDK. The Gradle wrapper download is blocked by network restrictions, so Android compilation and Apple XCTest execution are **not verified** here.

Five XCTest cases cover size/quality parsing, overflow, direct trailer URL selection, mixed trailer metadata and backwards-compatible MediaItem decoding. Generate the Xcode project with `xcodegen generate`, then select the StreamForge scheme and run Product > Test on an iOS simulator/device with the required framework slices installed. Tests are wired into the scheme in `project.yml`.

The last upstream successful Actions run is 38713251904, for the base commit only. It does not validate these changes. New changes must pass iOS, tvOS and Android builds after upload. GitHub connector branch creation returned HTTP 403; no remote changes or issue closures were made.

## Device QA

1. Android: add multiple items, remove the first/middle/last item, Undo, navigate away/back, restart and check persisted state. Repeat removal rapidly and use TV D-pad to reach Remove and Undo. Confirm swiping an item versus horizontally scrolling its shelf is usable.
2. Check phone portrait/landscape, tablet/foldable and Android TV, with large font scale and failing artwork URLs.
3. Android 17: grant and deny Nearby devices access, reconnect to local Dispatcharr/TorrServer, then grant via system Settings and return. Also test a remote HTTPS server with permission denied. Test min-supported API 26.
4. iOS: long-press a poster in a grid; check the muted loop and context actions. Hover with an iPad pointer. Verify previews stop on dismissal/background and do not autoplay with Low Data Mode, cellular policy restrictions, kids mode or during main playback.
5. With direct trailer metadata or a configured Invidious instance: start a movie, seek, choose Play Trailer, then Back to Full. Repeat while main playback is paused. Position and paused/playing intent must be retained; trailer progress must not enter Continue Watching. Test missing, offline and invalid trailers.
6. tvOS: use the trailer controls with a remote and Menu to return to full playback. Verify focus and that no two audio streams play simultaneously.
7. Rapidly switch playback/source/episode, then close while resolving; check no stale subtitle list or loading error appears on a newer session. Profile with Instruments for main-thread warnings and retained players after repeated preview opens.
8. Regression: protected profile switching/deletion, kids downloads, cancelled/paused downloads, interrupted HLS download, PiP pause, multiview duplicates, same media IDs on different servers, and seeks on clips shorter than one second.

## Apply

Use a clean checkout of the base above. From that checkout:

```sh
git apply --check /path/to/StreamForge-all-fixes.patch
git apply /path/to/StreamForge-all-fixes.patch
```

The patch includes the old fixes; do not apply the old patch first. If your branch has advanced, check/reconcile the diff before applying. The source archive contains the same resulting code.
