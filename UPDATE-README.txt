StreamForge server and mobile update

Extract into the repository root, preserving Sources/, android/, server/, and Tests/ paths.
This is a cumulative source update over commit 5490151. It includes the earlier playback
and UI fixes plus the server operations and progress-conflict update. It is not an APK/IPA.
Do not flatten directories. Review differences if your checkout has newer edits.

Included:
- Server health dashboard and last successful sync per device.
- Saved Dispatcharr credential tests and addon Test & refresh.
- Manual/daily backups, seven-snapshot retention, private downloads and offline restore steps.
- Revision-aware progress conflict protection in server, Apple and Android clients.
- Android featured home card, Discover/Continue/My List sections and 48dp mobile buttons.
- Previous responsive trailer/details, playback touch controls and library improvements.

Deploy the updated server and clients together to enable progress revision protection.
Daily backups default off: enable under Backups. Secrets-scoped admin access is required.

Validation: Go test ./..., Go race tests, Go vet, JavaScript syntax and git diff checks passed.
Swift/Kotlin received syntax checks; existing Kotlin parser limitations remain unchanged.
No Xcode or Android SDK is available here: mobile builds and on-device testing remain required.
These changes are committed locally, not pushed or deployed.
