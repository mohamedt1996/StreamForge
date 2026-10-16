StreamForge — Android: separate TV app, Chromecast with Google TV performance

TV APP: SYNC SERVER PRE-FILLED
- The Android TV app (tv flavor) opens Settings → Sync server with http://192.168.8.209:8484
  already in the address field (BuildConfig.DEFAULT_SYNC_SERVER; editable). Press
  "Get a pairing code" and approve it from the phone. The phone/tablet app is unchanged.

BUILT-IN TMDB / OMDb KEYS (iOS, tvOS, Android)
- Add two repository secrets (GitHub → Settings → Secrets and variables → Actions → New
  repository secret): TMDB_API_KEY and OMDB_API_KEY. CI builds them into every app; they are
  not in the source code. Without the secrets the apps build exactly as before.
- iOS/tvOS: Info.plist keys StreamForgeTMDBKey / StreamForgeOMDbKey ← build settings
  SF_TMDB_KEY / SF_OMDB_KEY (scripts/xcbuild.sh, project.yml). AppSettings.effectiveTMDBKey /
  effectiveOMDbKey: a key typed in Settings wins, else the built-in one (BuiltInKeys).
- Android: BuildConfig.TMDB_KEY / OMDB_KEY from the same env vars; Settings.effectiveTmdbKey /
  effectiveOmdbKey. New OMDb support on Android (metadata/Omdb.kt): IMDb score, Rotten Tomatoes,
  Metacritic and the age rating on detail pages; new "OMDb API key" field in Settings.
- Built-in keys are never synced to the sync server or other devices; only keys typed in
  Settings sync, as before.

IMDB RATINGS (iOS + Android)
- Every title with an IMDb id now gets its IMDb rating from Cinemeta, Stremio's free public
  metadata service (https://v3-cinemeta.strem.io/meta/{movie|series}/{tt…}.json, field
  imdbRating). No API key needed; results are cached; a failed lookup just shows no badge.
- iOS: used when OMDb isn't set up and no addon already supplied the rating (OMDb, when set,
  still adds Rotten Tomatoes / Metacritic). Shown with the existing yellow IMDb badge.
  CinemetaRating in Metadata/ExtraProviders.swift; XCTest for the JSON parsing.
- Android: new yellow "IMDb 8.8" badge (ImdbBadge in ui/Components.kt) on the phone/tablet and
  TV detail pages and on the TV home billboard; the separate ★ score is hidden when the IMDb
  badge shows. Details.imdbRating, filled in Metadata.details (also from addon metas).

TRAILER FIX (iOS + Android)
- YouTube trailers stopped playing on iOS once IMDb/direct links were removed: the embedded
  player page claimed to be youtube-nocookie.com (baseURL + origin), and YouTube answers such
  pages with "Video unavailable" (error 152; no origin at all gives 153). Earlier builds hid this
  because IMDb or direct MP4 links played first.
- Fix, per YouTube's Required Minimum Functionality docs: the page now identifies the app,
  https://com.mohamedt.streamforge (iOS: https://<bundle id>), as baseURL, player origin and
  Referer, with referrer policy strict-origin-when-cross-origin. Same change on Android.
- iOS Trailer sheet: if YouTube still refuses a particular video, a "Watch on YouTube" button
  opens it in the YouTube app/site instead of a dead end.
- Dispatcharr: no Dispatcharr code was changed in any of these updates. Its youtube_trailer
  values (bare ids or YouTube links) still reach the player unchanged.

ANDROID (this update)
- Two apps from one codebase (Gradle product flavors in android/app/build.gradle.kts):
  - tv: Android TV / Google TV. Always the 10-foot remote interface (it can no longer fall into
    the tablet layout), appears in the Google TV launcher (LEANBACK_LAUNCHER, src/tv manifest).
    No Interface setting.
  - mobile: phones and tablets. Touch interface, phone or tablet layout by screen size. The old
    "a D-pad press switches to TV" behaviour is gone; TV only if chosen in Settings → Interface.
  - Same application id and signing key: either APK updates an existing install in place.
  - Width checks (isWide / isMediumWidth / isExpandedWidth) are always false on TV, so no tablet
    rail or two-pane layout can appear on a TV screen.
- Smaller APKs: ARM only (x86 / x86_64 copies of mpv/ffmpeg dropped). CI now publishes
  StreamForge-tv-armeabi-v7a.apk  <- Chromecast with Google TV 4K (its Android is 32-bit)
  StreamForge-tv-arm64-v8a.apk, StreamForge-tv-universal.apk,
  StreamForge-mobile-arm64-v8a.apk, StreamForge-mobile-armeabi-v7a.apk, StreamForge-mobile-universal.apk
- Less lag on low-end devices (Perf.lowEnd: low-RAM, under ~3 GB RAM or 32-bit only, which
  includes the Chromecast with Google TV):
  - Home (TV): the billboard follows focus only after it rests on a card (280 ms) instead of
    decoding and crossfading a full-screen backdrop on every D-pad press; shorter crossfade.
  - Focused cards: no coloured elevation glow (white border only), faster scale animation.
  - Images: smaller in-memory cache and RGB_565 for opaque artwork (logos keep transparency).
  - Player: mpv "gpu" renderer with bilinear scaling and no debanding/dithering/peak detection
    instead of gpu-next with high-quality scalers; decoding stays hardware (MediaCodec).
- Trailers autoplay on detail pages exactly as before, on every device (setting unchanged).
- TV detail page no longer scrolls up by itself when it opens. Compose's default on TV moves
  the focused element to ~30 % from the top, so focusing Play (low on the page) pushed the title
  off screen. The page now scrolls only when focus goes to a row that is off screen (MinimalScroll
  in ui/Tv.kt), and moving back to the buttons returns to the top with the whole title visible.
- Chromecast remote (no play/pause key): in the player, OK pauses and shows the controls with
  focus on Play; OK again resumes. Left/Right still skip, Up/Down show controls (or change
  channel / open the channel list on live TV). Media keys from CEC remotes still work.
- Validation here: tree-sitter Kotlin parse of every changed file (HomeScreen.kt shows the same
  parser-only errors as the original). Gradle could not run in this workspace (Google Maven is
  blocked), so the GitHub Actions build is the first compile.

StreamForge — cinematic titles and trailer fallback

LATEST CHANGES (on top of the notes below)
- Trailers are YouTube only. IMDb embeds/title lookups and direct MP4/HLS trailer links are
  removed from the hero, the Trailer sheet and the player's trailer view. The YouTube embed is
  unchanged. The optional Invidious setting still plays the YouTube trailer natively (and is
  still the only trailer route on tvOS).
- iPhone: the detail hero runs edge to edge under the status bar, but the trailer picture
  (and YouTube's own top overlay) now starts below the status bar / Dynamic Island; the
  artwork still fills that strip. Landscape keeps the video inside the side safe areas.
- Stremio-style title header: large left-aligned logo in a fixed box, one meta row
  (year · runtime · certification · ratings) and genre chips.
- Titles no longer feel sluggish:
  - logos are decoded at display size at high priority (studio PNGs are often 2000+ px);
  - the logo box has a fixed size, so nothing jumps when it loads, and text→logo is a quick
    0.18 s crossfade (text only shows if the logo takes over 0.25 s or there is none);
  - the trailer shrink is a small 0.3 s spring instead of a slow 0.8 s ease; crossfade 0.5 s;
  - the home hero fetches the visible slide after 0.2 s (was 0.8 s) and pre-loads the next and
    previous slides' logos so they're already there when they slide in; tapping a hero passes
    the enriched title (with logo) to the detail page.
- Device detection (DeviceProfile in Theme.swift): reads the hardware model ("iPhone16,1"; the
  simulator's simulated model) and classifies Dynamic Island / notch / Touch ID iPhones, iPad,
  Mac and Apple TV, with a safe-area fallback for phones newer than the table. It sizes the
  hero and title logo per device (SE/mini, standard, Plus/Pro Max/Air, iPad) and keeps the
  trailer at least 59 pt below the top on Dynamic Island phones in portrait.
- iPhone detail trailer is pinned to the top: an exact 16:9 picture starting right under the
  Dynamic Island / notch (no black gap above it); the title sits over the dark area below.
  iPad keeps the centred fit; landscape fills the hero height.
- Per-device layout (HeroMetrics in Theme.swift), driven by DeviceProfile:
  - DeviceProfile now names every iPhone from 8/X to the 17 family (Dynamic Island / notch /
    Home button), classifies screens as compact (SE, mini, 375 pt), regular (390–402 pt) or
    large (Plus, Pro Max, Air), and logs e.g. "iPhone 16 Pro [iPhone17,1] …" in debug builds.
  - The trailer starts under the window's own status bar / Dynamic Island inset, not the
    page's safe area (which also counts the navigation bar and pushed it below the back button).
  - Phone detail header height = island clearance + exact 16:9 trailer + room for the title,
    meta row and genre chips, so the title only overlaps the bottom edge of the video and the
    Play button stays on the first screen on every iPhone. The fade-to-page gradient starts
    where the picture ends. Tagline is shown on iPad/Apple TV only.
  - Title box, text-title font size and line count per device (compact 240×84 / 30 pt,
    regular 290×100 / 36 pt, large 320×112 / 40 pt; landscape one line).
  - Home billboard: 16:9 trailer pinned to the top, height from the live width; small phones
    hide the overview line. iPad keeps its centred layout.
  - XCTest checks the header math for SE, 13 mini, 15 Pro and 16 Pro Max, portrait and landscape.
- Title shadow: a soft, wide dark halo plus a tight contact shadow on the logo/text (drawn once
  on the flattened title so it follows the logo's shape), and a light shadow on the meta row.
- Tests updated: YouTube-only source tests; Tests/TrailerBridgeTests.cjs now exercises the
  YouTube bridge (inactive start, pause, mute, end fade, replay, id fallback).
- Validation here: tree-sitter Swift syntax parse of every changed file and the node bridge
  test. Xcode build and on-device testing (iPhone with Dynamic Island) are still required.

EARLIER NOTES

Cumulative SOURCE update over commit 5490151. Includes the earlier server/mobile improvements.
Extract into the repository root with paths preserved. Review differences before overwriting
newer work. This ZIP is not an IPA/APK and has not been pushed to GitHub or deployed.

This update:
- Restores the cinematic iOS detail header, title-logo artwork and animated shrink during trailers.
- Home hero loads enriched title logos; missing logos fall back to readable title text.
- Plays supplied direct MP4/HLS links first, then IMDb embeds, then YouTube.
- Retains the user's optional Invidious native-video setting.
- Matches IMDb by the title's IMDb ID and its public JSON-LD trailer link, or uses an IMDb video
  link supplied by metadata. Does not pick unrelated videos from the generic trailers feed.
- IMDb lookup is best-effort. HTTP blocks, missing metadata, consent or playback failures
  fall back to YouTube. No IMDb access credentials are required or bypassed.
- IMDb/YouTube may show their branding or ads. There is no promise of overlay-free playback.
- The iOS Trailer button opens an in-app preview using the same fallback chain.
- iPhone/iPad fit sizing, mute/replay and background pause remain in place.
- tvOS continues to use native/direct trailers; Android changes from the preceding package
  are included, but this new IMDb/title update targets the Apple client.

Validation:
- Swift syntax parsing and git diff checks passed.
- node Tests/TrailerBridgeTests.cjs passed (simulated media lifecycle, pause/mute/replay/events).
- Added XCTest cases for provider ordering, URL validation and IMDb JSON-LD extraction.
- Xcode build, XCTest execution and live iPhone/iPad/IMDb playback testing remain required.
- Earlier server tests/race tests/vet passed in the preceding update; server code is unchanged here.

Build the Apple app after applying the ZIP. Updating the server container alone will not
change the iOS interface or trailer player.
