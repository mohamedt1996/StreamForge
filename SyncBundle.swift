import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Everything needed to set up another device: servers and their secrets, addons, settings,
/// API keys, profiles (with PINs) and every profile's library. Used by local-network sync and
/// by backup files. Contains secrets in plain text — treat backup files like passwords.
struct SyncBundle: Codable {
    struct Server: Codable {
        var server: DispatcharrServer
        var xcPassword: String
        var webPassword: String
        var apiKey: String
    }
    struct Profile: Codable {
        var profile: UserProfile
        var pin: String
    }

    var format = "streamforge-backup"
    var version = 1
    var createdAt: Date
    var deviceName: String
    var servers: [Server]
    var activeServerID: UUID?
    var addons: [InstalledAddon]
    var settings: AppSettings.Values
    var keys: [String: String]
    var profiles: [Profile]
    var parentPIN: String?
    var activeProfileID: UUID?
    var libraries: [String: Data]
    var reminders: [ProgrammeReminder]?
    var traktToken: String?

    var summary: String {
        var parts: [String] = []
        if !servers.isEmpty { parts.append("\(servers.count) server\(servers.count == 1 ? "" : "s")") }
        if !addons.isEmpty { parts.append("\(addons.count) addon\(addons.count == 1 ? "" : "s")") }
        if !profiles.isEmpty { parts.append("\(profiles.count) profile\(profiles.count == 1 ? "" : "s")") }
        if traktToken != nil { parts.append("Trakt sign-in") }
        return parts.isEmpty ? "settings" : parts.joined(separator: ", ") + " and settings"
    }
}

@MainActor
enum SyncService {
    static var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return "StreamForge"
        #endif
    }

    static func makeBundle() -> SyncBundle {
        let store = DispatcharrStore.shared
        let settings = AppSettings.shared
        let profiles = ProfileStore.shared
        let keys: [String: String] = [
            "tmdb": settings.tmdbKey, "omdb": settings.omdbKey, "fanart": settings.fanartKey,
            "traktClient": settings.traktClientID, "traktSecret": settings.traktClientSecret,
            "torrServerPassword": settings.torrServerPassword,
        ].filter { !$0.value.isEmpty }
        return SyncBundle(
            createdAt: Date(),
            deviceName: deviceName,
            servers: store.servers.map { SyncBundle.Server(server: $0, xcPassword: $0.xcPassword, webPassword: $0.webPassword, apiKey: $0.apiKey) },
            activeServerID: store.activeServer?.id,
            addons: AddonManager.shared.addons,
            settings: settings.values,
            keys: keys,
            profiles: profiles.profiles.map { SyncBundle.Profile(profile: $0, pin: $0.pin) },
            parentPIN: profiles.parentPIN.nilIfEmpty,
            activeProfileID: profiles.activeProfileID,
            libraries: LibraryStore.shared.exportLibraries(profileIDs: profiles.profiles.map(\.id)),
            reminders: ReminderCenter.shared.reminders,
            traktToken: TraktService.shared.exportedToken)
    }

    static func encode(_ bundle: SyncBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }

    static func decode(_ data: Data) throws -> SyncBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(SyncBundle.self, from: data)
        guard bundle.format == "streamforge-backup" else { throw HTTPError.decoding("Not a StreamForge backup") }
        return bundle
    }

    /// Applies a bundle from another device or a backup file.
    static func apply(_ b: SyncBundle) async {
        let settings = AppSettings.shared
        // Settings: keep this device's TorrServer setup when the sender has none (iPhone → Apple TV).
        var values = b.settings
        if values.remoteTorrServerURL.isEmpty { values.remoteTorrServerURL = settings.values.remoteTorrServerURL }
        if values.torrServerUser.isEmpty { values.torrServerUser = settings.values.torrServerUser }
        settings.values = values
        if let v = b.keys["tmdb"] { settings.tmdbKey = v }
        if let v = b.keys["omdb"] { settings.omdbKey = v }
        if let v = b.keys["fanart"] { settings.fanartKey = v }
        if let v = b.keys["traktClient"] { settings.traktClientID = v }
        if let v = b.keys["traktSecret"] { settings.traktClientSecret = v }
        if let v = b.keys["torrServerPassword"] { settings.torrServerPassword = v }

        AddonManager.shared.importAddons(b.addons)
        ProfileStore.shared.importProfiles(b.profiles.map { (profile: $0.profile, pin: $0.pin) }, parentPIN: b.parentPIN, activeID: b.activeProfileID)
        LibraryStore.shared.importLibraries(b.libraries)
        if let reminders = b.reminders { ReminderCenter.shared.importReminders(reminders) }
        DispatcharrStore.shared.importServers(b.servers.map { (server: $0.server, xcPassword: $0.xcPassword, webPassword: $0.webPassword, apiKey: $0.apiKey) }, activeID: b.activeServerID)
        if let token = b.traktToken, !TraktService.shared.isSignedIn { await TraktService.shared.importToken(token) }
        SnapshotPublisher.schedule()
    }

    /// Writes a backup file to the temporary directory (for ShareLink / Files).
    static func exportFile() throws -> URL {
        let data = try encode(makeBundle())
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StreamForge-Backup-\(f.string(from: Date())).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func importFile(_ url: URL) async throws -> String {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let bundle = try decode(data)
        await apply(bundle)
        return bundle.summary
    }
}
