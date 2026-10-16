StreamForge mobile UI update

Includes the earlier playback improvements plus this iOS/Android UI pass.
Extract into the repository root, preserving Sources/, android/ and Tests/.
Replace matching files. Do not upload the Swift/Kotlin files at the repository root.
Based on main commit 5490151; review against any newer edits before replacing files.

Changes: separate artwork/title on mobile detail pages; full-width Play/Resume;
labelled secondary actions; Audio/Subtitles/More player toolbar; additional
playback actions retained in More; responsive side panels; charcoal/violet styling;
shorter iOS Home banner; iOS Library filters; Android Home My List view.
Earlier controls, source recovery, Continue Watching and diagnostics changes included.

Not compiled or visually tested on devices. Xcode unavailable; Gradle distribution
download blocked by network. Build both platforms before distributing.
These UI changes have not been pushed to GitHub.
