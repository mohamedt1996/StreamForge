StreamForge - YouTube-only trailers + Dynamic Island safe trailer

Cumulative SOURCE update on top of the cinematic titles / trailer fallback package.
Extract into the repository root with paths preserved. Not an IPA/APK; not built or deployed.

Changes:
- Removed IMDb trailers: embeds, title lookup (JSON-LD scraping), IMDb script bridge, link parsing.
- Removed direct MP4/HLS trailer links (metadata links are ignored for trailers).
- YouTube is unchanged: iOS YouTube embed, plus the optional Invidious native-video setting.
- iPhone: the detail-page trailer is kept below the top safe area, so it never runs under the
  Dynamic Island (also covers notch / status bar). The strip above the video is black, matching
  the letterbox bars. iPad and the Home hero are unchanged (they already sit clear of it).
- IMDb IDs are still used for sync, matching and the IMDb rating badge. Only trailers changed.
- Main playback "Direct" streams (live TV, catch-up, Xtream episodes) are untouched.
- Tests: PlaybackSourceTests updated for YouTube-only parsing; TrailerBridgeTests.cjs removed
  (it only tested the IMDb web bridge).

Not verified: no Xcode build, XCTest run or on-device check. Please test the detail page on a
Dynamic Island iPhone in portrait.
