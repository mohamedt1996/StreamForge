import Foundation
import Observation
import Security
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

/// iCloud sync between iPhone, iPad and Apple TV.
///
/// - Settings, addons, servers, profiles and libraries go to the iCloud key-value store
///   (compressed, without any secrets).
/// - Passwords, API keys and PINs go to one iCloud Keychain item, so they stay end-to-end
///   encrypted by Apple and never sit in the key-value store.
///
/// Needs the app to be signed with an Apple Developer team that has iCloud enabled; sideloading
/// tools that strip the iCloud entitlement leave this inactive (local-network sync still works).
@MainActor
@Observable
final class CloudSync {
    static let shared = CloudSync()

    enum Status: Equatable {
        case off
        case unavailable(String)
        case idle
        case syncing
        case synced(Date)
        case failed(String)

        var text: String {
            switch self {
            case .off: return "Off"
            case .unavailable(let why): return why
            case .idle: return "Waiting"
            case .syncing: return "Syncing…"
            case .synced(let d): return "Synced \(d.formatted(date: .omitted, time: .shortened))"
            case .failed(let e): return e
            }
        }
    }

    private(set) var status: Status = .off
    private(set) var lastRemoteDevice: String?

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "cloud.enabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "cloud.enabled")
            if newValue { start() } else { stop() }
        }
    }

    private let store = NSUbiquitousKeyValueStore.default
    private let bundleKey = "streamforge.bundle.v1"
    private let metaKey = "streamforge.meta.v1"
    private let secretsAccount = "streamforge.cloud.secrets.v1"
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    /// Saves triggered by applying a download must not bounce straight back up.
    @ObservationIgnored private var suppressUntil = Date.distantPast

    private var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "cloud.deviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "cloud.deviceID")
        return id
    }

    /// When this device last uploaded (used to decide whether remote lists are newer).
    private var lastPush: Date {
        get { Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "cloud.lastPush")) }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: "cloud.lastPush") }
    }
    private var lastApplied: Date {
        get { Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "cloud.lastApplied")) }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: "cloud.lastApplied") }
    }

    /// `ubiquityIdentityToken` is only set for apps with an iCloud container; a key-value-store-only
    /// app relies on `synchronize()`, which returns false when the entitlement or account is missing.
    var iCloudAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil || store.synchronize() }

    private init() {}

    // MARK: Lifecycle

    func start() {
        guard isEnabled else { status = .off; return }
        guard iCloudAvailable else {
            status = .unavailable("Sign in to iCloud, and install a build signed with iCloud enabled")
            return
        }
        if !started {
            started = true
            observer = NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.pull() }
            }
        }
        store.synchronize()
        status = .idle
        Task { await pull(); schedulePush(delay: 5) }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        started = false
        pushTask?.cancel()
        status = .off
    }

    /// Debounced upload after local changes (and when the app goes to the background).
    func schedulePush(delay: Double = 20) {
        guard isEnabled, iCloudAvailable, Date() > suppressUntil else { return }
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            push()
        }
    }

    func syncNow() async {
        await pull()
        push()
    }

    // MARK: Upload

    private struct Meta: Codable {
        var updatedAt: Date
        var deviceID: String
        var deviceName: String
        var size: Int
    }

    private var lastPushedHash: String {
        get { UserDefaults.standard.string(forKey: "cloud.lastHash") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "cloud.lastHash") }
    }

    /// Content fingerprint that ignores per-device fields, so identical data is never re-uploaded.
    private func fingerprint(_ bundle: SyncBundle) -> String {
        var b = bundle
        b.createdAt = Date(timeIntervalSince1970: 0)
        b.deviceName = ""
        b.activeServerID = nil
        b.activeProfileID = nil
        guard let data = try? SyncService.encode(b) else { return UUID().uuidString }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func push() {
        guard isEnabled, iCloudAvailable else { return }
        status = .syncing
        var bundle = SyncService.makeBundle()
        bundle.libraries = LibraryStore.shared.exportLibrariesForCloud(profileIDs: ProfileStore.shared.profiles.map(\.id))

        // Secrets → iCloud Keychain; the key-value copy carries none.
        var secrets = Secrets()
        for s in bundle.servers {
            secrets.servers[s.server.id.uuidString] = Secrets.Server(xc: s.xcPassword, web: s.webPassword, apiKey: s.apiKey)
        }
        secrets.keys = bundle.keys
        for p in bundle.profiles where !p.pin.isEmpty { secrets.pins[p.profile.id.uuidString] = p.pin }
        secrets.parentPIN = bundle.parentPIN
        secrets.traktToken = bundle.traktToken
        writeSecrets(secrets)

        bundle.servers = bundle.servers.map { SyncBundle.Server(server: $0.server, xcPassword: "", webPassword: "", apiKey: "") }
        bundle.keys = [:]
        bundle.profiles = bundle.profiles.map { SyncBundle.Profile(profile: $0.profile, pin: "") }
        bundle.parentPIN = nil
        bundle.traktToken = nil

        let hash = fingerprint(bundle)
        if hash == lastPushedHash, store.data(forKey: bundleKey) != nil {
            status = .synced(max(lastPush, lastApplied))
            return
        }

        do {
            let raw = try SyncService.encode(bundle)
            var payload = try (raw as NSData).compressed(using: .zlib) as Data
            if payload.count > 900_000 {
                // Too big for the key-value store: drop libraries rather than fail entirely.
                bundle.libraries = [:]
                payload = try (try SyncService.encode(bundle) as NSData).compressed(using: .zlib) as Data
            }
            let now = Date()
            let meta = Meta(updatedAt: now, deviceID: deviceID, deviceName: SyncService.deviceName, size: payload.count)
            store.set(payload, forKey: bundleKey)
            store.set(try JSONEncoder().encode(meta), forKey: metaKey)
            store.synchronize()
            lastPush = now
            lastApplied = max(lastApplied, now)
            lastPushedHash = hash
            status = .synced(now)
        } catch {
            status = .failed("Couldn't upload: \(error.localizedDescription)")
        }
    }

    // MARK: Download

    func pull() async {
        guard isEnabled, iCloudAvailable else { return }
        guard let metaData = store.data(forKey: metaKey), let meta = try? JSONDecoder().decode(Meta.self, from: metaData) else { return }
        lastRemoteDevice = meta.deviceName
        guard meta.deviceID != deviceID, meta.updatedAt > lastApplied else {
            if case .syncing = status {} else { status = .synced(max(lastPush, lastApplied)) }
            return
        }
        guard let payload = store.data(forKey: bundleKey),
              let raw = try? (payload as NSData).decompressed(using: .zlib) as Data,
              var bundle = try? SyncService.decode(raw) else {
            status = .failed("The iCloud copy couldn't be read")
            return
        }
        status = .syncing
        suppressUntil = Date().addingTimeInterval(8)
        let remoteIsNewer = meta.updatedAt > lastPush
        fillSecrets(&bundle)

        // Each device keeps its own active server and profile.
        bundle.activeServerID = DispatcharrStore.shared.activeServer?.id
        bundle.activeProfileID = ProfileStore.shared.activeProfileID
        let libraries = bundle.libraries
        bundle.libraries = [:]
        let profiles = ProfileStore.shared
        let selecting = profiles.needsSelection

        if remoteIsNewer {
            await SyncService.apply(bundle)
        } else {
            // Our own changes are newer: only bring in positions / watched marks.
            AddonManager.shared.importAddons(bundle.addons.filter { a in !AddonManager.shared.addons.contains { $0.id == a.id } })
        }
        LibraryStore.shared.mergeLibraries(libraries, remoteIsNewer: remoteIsNewer)
        profiles.needsSelection = selecting
        lastApplied = meta.updatedAt
        status = .synced(Date())
    }

    // MARK: Secrets (iCloud Keychain)

    private struct Secrets: Codable {
        struct Server: Codable { var xc: String; var web: String; var apiKey: String }
        var servers: [String: Server] = [:]
        var keys: [String: String] = [:]
        var pins: [String: String] = [:]
        var parentPIN: String?
        var traktToken: String?
    }

    /// Missing secrets never wipe local ones: anything iCloud Keychain didn't deliver is taken
    /// from this device.
    private func fillSecrets(_ bundle: inout SyncBundle) {
        let secrets = readSecrets() ?? Secrets()
        let localServers = DispatcharrStore.shared.servers
        bundle.servers = bundle.servers.map { entry in
            let local = localServers.first { $0.id == entry.server.id }
            let s = secrets.servers[entry.server.id.uuidString]
            return SyncBundle.Server(server: entry.server,
                         xcPassword: s?.xc.nilIfEmpty ?? local?.xcPassword ?? "",
                         webPassword: s?.web.nilIfEmpty ?? local?.webPassword ?? "",
                         apiKey: s?.apiKey.nilIfEmpty ?? local?.apiKey ?? "")
        }
        bundle.keys = secrets.keys
        let localProfiles = ProfileStore.shared.profiles
        bundle.profiles = bundle.profiles.map { entry in
            let pin = secrets.pins[entry.profile.id.uuidString] ?? localProfiles.first { $0.id == entry.profile.id }?.pin ?? ""
            return SyncBundle.Profile(profile: entry.profile, pin: pin)
        }
        bundle.parentPIN = secrets.parentPIN ?? ProfileStore.shared.parentPIN.nilIfEmpty
        bundle.traktToken = secrets.traktToken
    }

    private var secretsQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.mohamedt.streamforge.cloud",
            kSecAttrAccount as String: secretsAccount,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
        ]
    }

    private func writeSecrets(_ secrets: Secrets) {
        guard let data = try? JSONEncoder().encode(secrets) else { return }
        SecItemDelete(secretsQuery as CFDictionary)
        var add = secretsQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private func readSecrets() -> Secrets? {
        var query = secretsQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Secrets.self, from: data)
    }
}
