import Foundation
import Observation

enum TorrentMode: String, Codable, CaseIterable, Identifiable {
    case embedded, remote
    var id: String { rawValue }
    var label: String { self == .embedded ? "On this device" : "Remote TorrServer" }
}

enum MetadataSource: String, Codable, CaseIterable, Identifiable {
    case provider, tmdb, cinemeta
    var id: String { rawValue }
    var label: String {
        switch self {
        case .provider: return "IPTV provider"
        case .tmdb: return "TMDB"
        case .cinemeta: return "Cinemeta"
        }
    }
}

enum HardwareDecoding: String, Codable, CaseIterable, Identifiable {
    case videotoolbox, videotoolboxCopy = "videotoolbox-copy", software = "no"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .videotoolbox: return "Hardware (fastest)"
        case .videotoolboxCopy: return "Hardware + copy (compatible)"
        case .software: return "Software"
        }
    }
}

enum StreamSort: String, Codable, CaseIterable, Identifiable {
    case quality, fastest, size, seeders, addon
    var id: String { rawValue }
    var label: String { self == .fastest ? "Fastest start" : rawValue.capitalized }
}

/// Every user-facing preference. Persisted as one JSON document; secrets go to the Keychain.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    struct Values: Codable {
        // Torrents
        var torrentMode: TorrentMode = {
            #if os(tvOS)
            return .remote
            #else
            return .embedded
            #endif
        }()
        var remoteTorrServerURL: String = ""
        var torrServerUser: String = ""
        var embeddedCacheMB: Int = 256
        var preloadPercent: Int = 5

        // Metadata
        var metadataPriority: [MetadataSource] = [.tmdb, .provider, .cinemeta]
        var metadataLanguage: String = Locale.current.language.languageCode?.identifier ?? "en"
        var enrichPosters: Bool = true
        var hideAdult: Bool = true

        // Player
        var hwdec: HardwareDecoding = .videotoolbox
        var hdrPassthrough: Bool = true
        var preferredAudioLanguage: String = Locale.current.language.languageCode?.identifier ?? "en"
        var preferredSubtitleLanguage: String = Locale.current.language.languageCode?.identifier ?? "en"
        var autoSubtitles: Bool = false
        var subtitleScale: Double = 1.0
        var seekStep: Int = 10
        var longSeekStep: Int = 60
        var autoplayNext: Bool = true
        var demuxerCacheMB: Int = 150
        var liveBufferSeconds: Int = 4
        var customUserAgent: String = ""
        var resumePlayback: Bool = true

        // Streams
        var streamSort: StreamSort = .quality
        var maxStreamResolution: Int = 2160
        var excludeCam: Bool = true

        // Live TV
        var startOnLastChannel: Bool = false
        var showChannelNumbers: Bool = true

        // Added after 1.0. Stored as optionals so settings files written by older builds still
        // decode (synthesized Codable ignores default values for missing keys); use the
        // non-optional accessors below.
        var guideDaysStored: Int?
        var trailerAutoplayStored: Bool?
        var refreshGuideAutomaticallyStored: Bool?
        var invidiousInstanceStored: String?

        /// Days of programme guide to download from Dispatcharr's XMLTV (1–14).
        var guideDays: Int {
            get { min(14, max(1, guideDaysStored ?? 3)) }
            set { guideDaysStored = min(14, max(1, newValue)) }
        }
        /// iOS: play a muted trailer behind the detail page header (never on cellular / Low Data Mode).
        var trailerAutoplay: Bool {
            get { trailerAutoplayStored ?? true }
            set { trailerAutoplayStored = newValue }
        }
        /// tvOS (no WebKit): an Invidious instance used to stream trailers as MP4. Empty = off.
        var invidiousInstance: String {
            get { invidiousInstanceStored ?? "" }
            set { invidiousInstanceStored = newValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        /// Re-download the bulk guide every 6 hours.
        var refreshGuideAutomatically: Bool {
            get { refreshGuideAutomaticallyStored ?? true }
            set { refreshGuideAutomaticallyStored = newValue }
        }
    }

    var values: Values {
        didSet {
            FileStore.save(values, "settings.json", mirrorToDefaults: true)
            CloudSync.shared.schedulePush()
            ServerSync.shared.noteLocalChange()
        }
    }

    private init() {
        values = FileStore.load(Values.self, "settings.json") ?? Values()
    }

    // MARK: Secrets

    /// Keys the user typed in Settings win; otherwise the ones built into the app by CI.
    var effectiveTMDBKey: String { tmdbKey.isEmpty ? BuiltInKeys.tmdb : tmdbKey }
    var effectiveOMDbKey: String { omdbKey.isEmpty ? BuiltInKeys.omdb : omdbKey }

    var tmdbKey: String {
        get { Keychain.get("tmdb.key") ?? "" }
        set {
            Keychain.set(newValue.trimmed, for: "tmdb.key")
            ServerSync.shared.noteLocalChange()
        }
    }
    var omdbKey: String {
        get { Keychain.get("omdb.key") ?? "" }
        set {
            Keychain.set(newValue.trimmed, for: "omdb.key")
            ServerSync.shared.noteLocalChange()
        }
    }
    var fanartKey: String {
        get { Keychain.get("fanart.key") ?? "" }
        set {
            Keychain.set(newValue.trimmed, for: "fanart.key")
            ServerSync.shared.noteLocalChange()
        }
    }
    var traktClientID: String {
        get { Keychain.get("trakt.client") ?? "" }
        set { Keychain.set(newValue.trimmed, for: "trakt.client") }
    }
    var traktClientSecret: String {
        get { Keychain.get("trakt.secret") ?? "" }
        set { Keychain.set(newValue.trimmed, for: "trakt.secret") }
    }
    var torrServerPassword: String {
        get { Keychain.get("torrserver.password") ?? "" }
        set { Keychain.set(newValue, for: "torrserver.password") }
    }
}


/// TMDB / OMDb keys built into the app at compile time (CI injects them from the repository
/// secrets TMDB_API_KEY / OMDB_API_KEY into Info.plist). Empty when the build had none, so they
/// never live in the source code. Never synced: only keys typed in Settings sync.
enum BuiltInKeys {
    static let tmdb = value("StreamForgeTMDBKey")
    static let omdb = value("StreamForgeOMDbKey")

    private static func value(_ key: String) -> String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // An unset build setting can leave the literal "$(SF_…)" behind.
        return raw.hasPrefix("$(") ? "" : raw
    }
}
