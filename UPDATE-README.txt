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
