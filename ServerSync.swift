import Foundation
import Observation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

/// Client for a self-hosted StreamForge sync server (server/PROTOCOL.md).
///
/// Local-first: every store keeps working from its own files. This class mirrors them as
/// *records*. Local changes are found by fingerprinting every record and comparing it with the
/// last state this device knows the server has (`state.known`); differences go to a persisted
/// outbox that is pushed ~3 s later. A long-poll loop pulls other devices' records while the app
/// is in the foreground; applying them never re-queues them (the fingerprints are rebased right
/// after applying).
@MainActor
@Observable
final class ServerSync {
    static let shared = ServerSync()

    enum Phase: Equatable {
        case signedOut
        case idle
        case syncing
        case offline(String)
        case error(String)
    }

    struct Pairing: Equatable {
        var code: String
        var pairId: String
        var serverURL: String
        var expiresAt: Date
        var expired: Bool
    }

    // MARK: Observable state

    private(set) var isSignedIn = false
    /// Normalized server base URL (kept after sign-out to prefill the form).
    private(set) var serverURL: String
    private(set) var username: String?
    private(set) var userRole: String?
    private(set) var deviceID: String?
    private(set) var deviceName: String?
    private(set) var scopes: [String]
    private(set) var serverName: String?
    private(set) var phase: Phase = .signedOut
    private(set) var lastSync: Date?
    /// Why this device was signed out (revoked token…).
    private(set) var signOutReason: String?
    private(set) var pendingCount = 0
    private(set) var pairing: Pairing?
    private(set) var pairingError: String?
    private(set) var devices: [SyncDevice] = []
    private(set) var isSyncingNow = false
    /// Admin-managed items the user removed on this device that sync brought back: the app asks
    /// "Restore from sync" / "Continue without it" (see ManagedConfig.swift).
    var restorePrompt: [ManagedItem] = []
    /// Admin-managed settings the user just changed: the app asks before taking them over.
    var settingPrompt: [ManagedItem] = []
    /// The restore prompt was dismissed without an answer; asked again when sync brings news.
    var restorePromptSnoozed = false
    /// Managed items this account continues without (restorable from Settings → Sync Server).
    var dismissedItems: [ManagedItem] = []

    // MARK: Persistent sync state

    struct Known: Codable {
        /// Fingerprint of the record data ("" for tombstones).
        var h: String
        /// updatedAt (ms) of the version this device has.
        var t: Int64
        /// Deleted.
        var d: Bool
    }

    struct PendingAddon: Codable {
        var enabled: Bool
        var order: Int?
    }

    /// A managed record held back from the stores until the user answers the restore prompt.
    struct HeldRecord: Codable {
        var collection: String
        var id: String
        var data: SyncJSON?
        var updatedAt: Int64
        var rev: Int64
    }

    struct State: Codable {
        var initialized = false
        var lastRev: Int64 = 0
        var known: [String: Known] = [:]
        /// "<profileUUID>|<local watched key>" → canonical key, for watched marks made before
        /// canonical keys were stored (resolved once so the record id never changes).
        var legacyWatched: [String: String] = [:]
        /// Addons received from the server that couldn't be installed yet (offline…).
        var pendingAddons: [String: PendingAddon] = [:]
        /// Dispatcharr server whose favorite channels the known map describes.
        var channelServer: String?
        /// Record keys (collection + "\n" + id) the server admin manages for this user.
        var managed: Set<String> = []
        /// Values of managed settings (to put back when the user keeps the managed value).
        var managedSettings: [String: SyncJSON] = [:]
        /// Active dismissals: "<collection>|<id>" → dismissedAt (ms). Synced as `dismissed` records.
        var dismissed: [String: Int64] = [:]
        /// Managed servers/addons removed on this device without a dismissal (record keys).
        var locallyRemoved: Set<String> = []
        /// Managed records sync brought back after a local removal, waiting for the user's answer.
        var held: [String: HeldRecord] = [:]
        /// The managed set is complete (false for state saved before it existed: pull again from 0).
        var managedTracked = false
        /// Display names of managed items (record key → name), for prompts and dismissed items.
        var managedNames: [String: String] = [:]

        init() {}

        enum CodingKeys: String, CodingKey {
            case initialized, lastRev, known, legacyWatched, pendingAddons, channelServer
            case managed, managedSettings, dismissed, locallyRemoved, held, managedTracked, managedNames
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            initialized = (try? c.decodeIfPresent(Bool.self, forKey: .initialized)) ?? false
            lastRev = (try? c.decodeIfPresent(Int64.self, forKey: .lastRev)) ?? 0
            known = (try? c.decodeIfPresent([String: Known].self, forKey: .known)) ?? [:]
            legacyWatched = (try? c.decodeIfPresent([String: String].self, forKey: .legacyWatched)) ?? [:]
            pendingAddons = (try? c.decodeIfPresent([String: PendingAddon].self, forKey: .pendingAddons)) ?? [:]
            channelServer = try? c.decodeIfPresent(String.self, forKey: .channelServer)
            managed = (try? c.decodeIfPresent(Set<String>.self, forKey: .managed)) ?? []
            managedSettings = (try? c.decodeIfPresent([String: SyncJSON].self, forKey: .managedSettings)) ?? [:]
            dismissed = (try? c.decodeIfPresent([String: Int64].self, forKey: .dismissed)) ?? [:]
            locallyRemoved = (try? c.decodeIfPresent(Set<String>.self, forKey: .locallyRemoved)) ?? []
            held = (try? c.decodeIfPresent([String: HeldRecord].self, forKey: .held)) ?? [:]
            managedTracked = (try? c.decodeIfPresent(Bool.self, forKey: .managedTracked)) ?? false
            managedNames = (try? c.decodeIfPresent([String: String].self, forKey: .managedNames)) ?? [:]
        }
    }

    @ObservationIgnored var state = State()
    @ObservationIgnored var outbox: [String: OutboxEntry] = [:]
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var pairTask: Task<Void, Never>?
    @ObservationIgnored private var pushing = false
    /// True while server records are written into the stores (their change callbacks aren't edits).
    @ObservationIgnored var applyingRemote = false

    private static let tokenKey = "serversync.token"
    private static let stateFile = "serversync-state.json"
    private static let outboxFile = "serversync-outbox.json"
    private let defaults = UserDefaults.standard

    private init() {
        let defaults = UserDefaults.standard
        serverURL = defaults.string(forKey: "serversync.url") ?? ""
        username = defaults.string(forKey: "serversync.username")
        userRole = defaults.string(forKey: "serversync.role")
        deviceID = defaults.string(forKey: "serversync.deviceID")
        deviceName = defaults.string(forKey: "serversync.deviceName")
        serverName = defaults.string(forKey: "serversync.serverName")
        scopes = defaults.stringArray(forKey: "serversync.scopes") ?? []
        let last = defaults.double(forKey: "serversync.lastSync")
        lastSync = last > 0 ? Date(timeIntervalSince1970: last) : nil
        token = Keychain.get(Self.tokenKey)
        isSignedIn = token != nil && !serverURL.isEmpty
        if isSignedIn {
            // A missing state file (e.g. tvOS purged its caches) simply means a fresh first sync.
            state = FileStore.load(State.self, Self.stateFile) ?? State()
            outbox = FileStore.load([String: OutboxEntry].self, Self.outboxFile) ?? [:]
            pendingCount = outbox.count
            phase = .idle
        }
    }

    // MARK: Derived

    var canRead: Bool { scopes.isEmpty || scopes.contains("read") }
    var canWrite: Bool { scopes.isEmpty || scopes.contains("write") }
    var hasSecretsScope: Bool { scopes.isEmpty || scopes.contains("secrets") }

    var serverHost: String {
        guard let url = URL(string: serverURL), let host = url.host else { return serverURL }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    var statusText: String {
        switch phase {
        case .signedOut: return signOutReason ?? "Not signed in"
        case .syncing: return "Syncing…"
        case .idle:
            if pendingCount > 0, !canWrite { return "Read-only device" }
            if pendingCount > 0 { return "\(pendingCount) change\(pendingCount == 1 ? "" : "s") waiting to upload" }
            return lastSync == nil ? "Connecting…" : "Up to date"
        case .offline(let why): return "Can't reach the server — \(why)"
        case .error(let why): return why
        }
    }

    static var platform: String {
        #if os(tvOS)
        return "tvos"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
        #endif
    }

    private func api() -> SyncServerAPI? {
        guard let token, let base = URL(string: serverURL) else { return nil }
        return SyncServerAPI(base: base, token: token)
    }

    static func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

    static func recordKey(_ collection: String, _ id: String) -> String { collection + "\n" + id }

    static func splitKey(_ key: String) -> (collection: String, id: String) {
        guard let nl = key.firstIndex(of: "\n") else { return (key, "") }
        return (String(key[..<nl]), String(key[key.index(after: nl)...]))
    }

    static func fingerprint(_ value: SyncJSON) -> String {
        let digest = SHA256.hash(data: Data(value.canonicalString.utf8))
        return Data(digest.prefix(15)).base64EncodedString()
    }

    // MARK: Lifecycle

    /// Called at launch. Starts syncing when signed in; otherwise does nothing.
    func start() {
        guard isSignedIn else {
            phase = .signedOut
            return
        }
        CloudSync.shared.pauseForServerSync()
        prepareFirstSyncIfNeeded()
        if state.initialized, !state.managedTracked {
            // State from before managed records were tracked: pull everything once more to learn
            // which records are managed (records already applied are skipped by their updatedAt).
            state.lastRev = 0
            state.managedTracked = true
            saveNow()
        }
        refreshManagedPrompts()
        Task { await refreshMe() }
        if foreground { startLoop() }
        if !outbox.isEmpty { schedulePush(delay: 1) }
        installPendingAddons()
    }

    /// scenePhase changes: long-poll only while the app is active.
    func setForeground(_ active: Bool) {
        foreground = active
        guard isSignedIn else { return }
        if active {
            startLoop()
        } else {
            loopTask?.cancel()
            loopTask = nil
            scan()
            saveNow()
            Task { await pushNow() }
        }
    }

    /// Any store changed; scans and pushes about 3 s later (throttled, not reset by further changes).
    func noteLocalChange() {
        guard isSignedIn else { return }
        checkManagedSettingEdits()
        guard scanTask == nil else { return }
        scanTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self else { return }
            self.scanTask = nil
            guard self.isSignedIn else { return }
            self.scan()
            await self.pushNow()
        }
    }

    func syncNow() async {
        guard isSignedIn else { return }
        isSyncingNow = true
        defer { isSyncingNow = false }
        loopTask?.cancel()
        loopTask = nil
        scan()
        await pushNow()
        do {
            _ = try await pullOnce(wait: 0)
        } catch is CancellationError {
        } catch {
            _ = handle(error)
        }
        await pushNow()
        if isSignedIn, foreground { startLoop() }
    }

    private func startLoop() {
        loopTask?.cancel()
        guard isSignedIn else { return }
        loopTask = Task { [weak self] in
            await self?.loop()
        }
    }

    private func loop() async {
        var backoff: Double = 5
        var wait = 0
        while !Task.isCancelled, isSignedIn, foreground {
            do {
                let started = Date()
                let received = try await pullOnce(wait: wait)
                // A server that answers a long poll instantly with nothing must not be hammered.
                if wait > 0, received == 0, Date().timeIntervalSince(started) < 2 {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
                wait = 50
                backoff = 5
            } catch is CancellationError {
                return
            } catch {
                guard handle(error) else { return }
                var delay = backoff
                if let e = error as? SyncServerError, case .rateLimited(let s) = e { delay = max(1, s) }
                backoff = min(60, backoff * 2)
                wait = 0
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// First sign-in (or lost state): queue every local record, then pull everything from rev 0.
    private func prepareFirstSyncIfNeeded(previous: [String: Known] = [:]) {
        guard isSignedIn, !state.initialized else { return }
        let old = state
        state = State()
        // Resolutions that keep record ids stable, addons still waiting to be installed, and what
        // this device knows about managed records and dismissals.
        state.legacyWatched = old.legacyWatched
        state.pendingAddons = old.pendingAddons
        state.managed = old.managed
        state.managedSettings = old.managedSettings
        state.dismissed = old.dismissed
        state.locallyRemoved = old.locallyRemoved
        state.held = old.held
        state.managedNames = old.managedNames
        state.managedTracked = true
        outbox = [:]
        scan(baseline: true, previous: previous)
        state.initialized = true
        saveNow()
    }

    /// Handles an error from a server call. Returns false when this device got signed out.
    @discardableResult
    private func handle(_ error: Error) -> Bool {
        guard let e = error as? SyncServerError else {
            phase = .offline(error.localizedDescription)
            return true
        }
        switch e {
        case .unauthorized:
            signOutLocally(reason: "This device was signed out by the server. Everything on it is still here — sign in again to resume syncing.")
            return false
        case .forbidden(let message):
            phase = .error(message ?? "This device doesn't have permission for that.")
            // Permissions may have changed on the server: refresh them.
            Task { await refreshMe() }
            return true
        case .rateLimited:
            phase = .offline("too many requests, retrying")
            return true
        case .transport(let message):
            phase = .offline(message)
            return true
        case .badURL, .gone, .status, .decoding:
            phase = .error(e.localizedDescription)
            return true
        }
    }

    // MARK: Pull

    /// Pulls until the server has nothing more; returns how many records arrived.
    @discardableResult
    private func pullOnce(wait: Int) async throws -> Int {
        guard isSignedIn, let api = api() else { return 0 }
        prepareFirstSyncIfNeeded()
        guard canRead else {
            // Write-only device: nothing to pull; just keep pushing.
            scan()
            if !outbox.isEmpty { await pushNow() }
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return 0
        }
        if scan() > 0 || !outbox.isEmpty { schedulePush(delay: 1) }
        var waitSeconds = wait
        var received = 0
        if wait == 0 { phase = .syncing }
        while true {
            let since = state.lastRev
            let res = try await api.pull(since: since, wait: waitSeconds)
            waitSeconds = 0
            received += res.records.count
            if res.rev < since {
                // The server lost its data (restored / recreated, possibly to rev 0): upload
                // everything again. Keep the timestamps of the versions this device already has so
                // an older backup doesn't beat newer local data.
                scan()
                let previous = state.known
                state.initialized = false
                prepareFirstSyncIfNeeded(previous: previous)
                schedulePush(delay: 0)
                return received
            }
            if !res.records.isEmpty {
                scan() // capture local edits made during the long poll before applying
                apply(res.records)
                // Make the applied records durable before lastRev moves past them.
                LibraryStore.shared.flush()
            }
            if res.rev > state.lastRev { state.lastRev = res.rev }
            markSynced()
            if res.records.isEmpty { saveSoon() } else { saveNow() }
            if !res.more || res.rev <= since { break }
        }
        if !outbox.isEmpty { schedulePush(delay: 1) }
        return received
    }

    private func markSynced() {
        guard isSignedIn else { return }
        lastSync = Date()
        defaults.set(lastSync?.timeIntervalSince1970 ?? 0, forKey: "serversync.lastSync")
        phase = .idle
        pendingCount = outbox.count
    }

    // MARK: Push

    func schedulePush(delay: Double) {
        guard isSignedIn, pushTask == nil else { return }
        pushTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self else { return }
            self.pushTask = nil
            await self.pushNow()
        }
    }

    func pushNow() async {
        guard isSignedIn, canWrite, !pushing, !outbox.isEmpty, let api = api() else {
            pendingCount = outbox.count
            return
        }
        pushing = true
        defer { pushing = false }
        while isSignedIn, !outbox.isEmpty {
            let batch = nextBatch()
            if batch.isEmpty { break }
            do {
                let res = try await api.push(batch)
                var sent: [String: Int64] = [:]
                for e in batch { sent[Self.recordKey(e.collection, e.id)] = e.updatedAt }
                var removed = 0
                for r in res.results {
                    let key = Self.recordKey(r.collection, r.id)
                    // "applied" / "stale" (and any per-record rejection) are final for that version;
                    // a newer local edit made while the request was in flight stays queued.
                    if let entry = outbox[key], entry.updatedAt == sent[key] {
                        outbox[key] = nil
                        removed += 1
                    }
                }
                markSynced()
                saveSoon()
                if removed == 0 { break }
            } catch is CancellationError {
                break
            } catch {
                handle(error)
                break
            }
        }
        pendingCount = outbox.count
    }

    /// Up to 500 records and ~1.5 MB, oldest first.
    private func nextBatch() -> [OutboxEntry] {
        let sorted = outbox.values.sorted { $0.updatedAt < $1.updatedAt }
        var out: [OutboxEntry] = []
        var bytes = 0
        for entry in sorted {
            let size = (entry.data?.canonicalString.utf8.count ?? 0) + entry.id.utf8.count + 80
            if size > 250_000 {
                // Over the per-record limit: drop it rather than block the queue.
                outbox[Self.recordKey(entry.collection, entry.id)] = nil
                continue
            }
            if out.count >= 500 || bytes + size > 1_500_000 { break }
            out.append(entry)
            bytes += size
        }
        return out
    }

    // MARK: Change detection

    /// Compares every local record with what the server is known to have and queues differences.
    /// `baseline` (first sign-in): queue everything with its own timestamp, or 1 when it has
    /// none, so records already on the server win and records it lacks are added.
    @discardableResult
    func scan(baseline: Bool = false, previous: [String: Known] = [:]) -> Int {
        guard isSignedIn else { return 0 }
        let local = buildLocalRecords()
        let now = Self.nowMs()
        var queued = 0

        // Switching the active Dispatcharr server must not push the old favorites as the new
        // server's: adopt the current list silently.
        let activeServer = DispatcharrStore.shared.activeServer?.id.uuidString.lowercased()
        if state.channelServer != activeServer {
            if !baseline {
                for (key, rec) in local where rec.collection == "channels" {
                    let h = Self.fingerprint(rec.data)
                    let t = state.known[key]?.t ?? 0
                    state.known[key] = Known(h: h, t: t, d: false)
                }
                // The newly active server's favorites that other devices synced aren't in this
                // device's (single) list: that is not a removal, so never turn them into tombstones.
                if let activeServer {
                    for (key, known) in state.known where !known.d && local[key] == nil {
                        let parts = Self.splitKey(key)
                        guard parts.collection == "channels" else { continue }
                        let p = parts.id.split(separator: "|", omittingEmptySubsequences: false)
                        if p.count == 3, String(p[1]) == activeServer {
                            state.known[key] = Known(h: "", t: known.t, d: true)
                        }
                    }
                }
            }
            state.channelServer = activeServer
        }

        for (key, rec) in local {
            let h = Self.fingerprint(rec.data)
            let known = state.known[key]
            if let known, !known.d, known.h == h { continue }
            // A changed managed setting waits for the user's answer (settingPrompt); the server
            // would refuse it anyway.
            if !baseline, rec.collection == "settings", isManagedForUser(key), known != nil { continue }
            if state.locallyRemoved.contains(key) { state.locallyRemoved.remove(key) }
            var t: Int64
            if baseline {
                t = rec.stamp ?? 1
                // Server reset: the version this device already had keeps its own timestamp.
                if let prev = previous[key], !prev.d, prev.h == h, prev.t > t { t = prev.t }
            } else {
                t = rec.stamp ?? now
                if let known, t <= known.t { t = known.t + 1 }
            }
            state.known[key] = Known(h: h, t: t, d: false)
            outbox[key] = OutboxEntry(collection: rec.collection, id: rec.id, data: rec.data, deleted: false, updatedAt: t)
            queued += 1
        }
        if !baseline {
            for (key, known) in state.known where !known.d && local[key] == nil && owns(key) {
                let t = max(now, known.t + 1)
                state.known[key] = Known(h: "", t: t, d: true)
                let parts = Self.splitKey(key)
                // Removed here without "Remove from this account": if sync brings it back, ask.
                if parts.collection == "servers" || parts.collection == "addons", isManagedForUser(key) {
                    state.locallyRemoved.insert(key)
                }
                outbox[key] = OutboxEntry(collection: parts.collection, id: parts.id, data: nil, deleted: true, updatedAt: t)
                queued += 1
            }
        }
        pendingCount = outbox.count
        if queued > 0 { saveSoon() }
        return queued
    }

    /// After applying server records: adopt the resulting local state as "known" so nothing that
    /// came from the server is queued again. Pending local edits keep their timestamps.
    func rebaseline(only collections: Set<String>? = nil) {
        let local = buildLocalRecords()
        for (key, rec) in local {
            if let collections, !collections.contains(rec.collection) { continue }
            let h = Self.fingerprint(rec.data)
            if var known = state.known[key] {
                if known.h != h || known.d {
                    known.h = h
                    known.d = false
                    state.known[key] = known
                }
            } else {
                state.known[key] = Known(h: h, t: 0, d: false)
            }
            if var pending = outbox[key] {
                pending.data = rec.data
                pending.deleted = false
                outbox[key] = pending
            }
        }
        for (key, known) in state.known where !known.d && local[key] == nil && owns(key) {
            if let collections, !collections.contains(Self.splitKey(key).collection) { continue }
            state.known[key] = Known(h: "", t: known.t, d: true)
            if var pending = outbox[key] {
                pending.data = nil
                pending.deleted = true
                outbox[key] = pending
            }
        }
        pendingCount = outbox.count
        saveSoon()
    }

    /// Records this device is responsible for. Others (secrets without the scope, favorite
    /// channels of a Dispatcharr server that isn't active here, settings this platform doesn't
    /// sync) are never turned into tombstones just because they're missing locally.
    private func owns(_ key: String) -> Bool {
        let parts = Self.splitKey(key)
        switch parts.collection {
        case "secrets":
            return hasSecretsScope
        case "channels":
            let p = parts.id.split(separator: "|", omittingEmptySubsequences: false)
            guard p.count == 3, let active = DispatcharrStore.shared.activeServer?.id.uuidString.lowercased() else { return false }
            return String(p[1]) == active
        case "settings":
            return Self.syncedSettingKeys.contains(parts.id)
        default:
            return true
        }
    }

    // MARK: Persistence

    func saveSoon() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }
            self.saveTask = nil
            self.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard isSignedIn else { return }
        FileStore.save(state, Self.stateFile)
        FileStore.save(outbox, Self.outboxFile)
    }

    private func persistConfig() {
        defaults.set(serverURL, forKey: "serversync.url")
        defaults.set(username, forKey: "serversync.username")
        defaults.set(userRole, forKey: "serversync.role")
        defaults.set(deviceID, forKey: "serversync.deviceID")
        defaults.set(deviceName, forKey: "serversync.deviceName")
        defaults.set(serverName, forKey: "serversync.serverName")
        defaults.set(scopes, forKey: "serversync.scopes")
    }

    // MARK: Account

    func signIn(serverURL raw: String, username user: String, password: String) async throws {
        guard let base = SyncServerAPI.normalize(raw) else { throw SyncServerError.badURL }
        let api = SyncServerAPI(base: base, token: nil)
        let auth = try await api.login(username: user.trimmingCharacters(in: .whitespacesAndNewlines), password: password,
                                       deviceName: SyncService.deviceName, platform: Self.platform)
        completeSignIn(base: base, auth: auth)
    }

    private func completeSignIn(base: URL, auth: SyncAuthResponse) {
        cancelPairing()
        loopTask?.cancel()
        Keychain.set(auth.token, for: Self.tokenKey)
        token = auth.token
        serverURL = base.absoluteString
        username = auth.user.username
        userRole = auth.user.role
        deviceID = auth.device.id
        deviceName = auth.device.name
        scopes = auth.device.scopes
        persistConfig()
        // Every sign-in starts from scratch: upload everything, then take the server's newer copies.
        state = State()
        outbox = [:]
        FileStore.remove(Self.stateFile)
        FileStore.remove(Self.outboxFile)
        signOutReason = nil
        isSignedIn = true
        phase = .syncing
        start()
    }

    /// Signs out on the server and locally. Local data stays.
    func signOut() async {
        if let api = api() {
            scan()
            await pushNow()
            try? await api.logout()
        }
        signOutLocally(reason: nil)
    }

    func signOutLocally(reason: String?) {
        loopTask?.cancel(); loopTask = nil
        scanTask?.cancel(); scanTask = nil
        pushTask?.cancel(); pushTask = nil
        saveTask?.cancel(); saveTask = nil
        Keychain.set(nil, for: Self.tokenKey)
        token = nil
        isSignedIn = false
        state = State()
        outbox = [:]
        FileStore.remove(Self.stateFile)
        FileStore.remove(Self.outboxFile)
        pendingCount = 0
        restorePrompt = []
        settingPrompt = []
        dismissedItems = []
        restorePromptSnoozed = false
        devices = []
        deviceID = nil
        scopes = []
        persistConfig()
        phase = .signedOut
        signOutReason = reason
        CloudSync.shared.resumeAfterServerSync()
    }

    func refreshMe() async {
        guard let api = api() else { return }
        do {
            let me = try await api.me()
            username = me.user.username
            userRole = me.user.role
            deviceID = me.device.id
            deviceName = me.device.name
            scopes = me.device.scopes
            serverName = me.server?.name
            persistConfig()
        } catch is CancellationError {
        } catch {
            handle(error)
        }
    }

    func changePassword(current: String, new: String) async throws {
        guard let api = api() else { throw SyncServerError.unauthorized(nil) }
        do {
            try await api.changePassword(current: current, new: new)
        } catch SyncServerError.unauthorized(let message) {
            // Wrong current password is reported as 401 by some servers; don't sign out for it.
            throw SyncServerError.status(401, message ?? "The current password is wrong")
        }
    }

    // MARK: Devices

    func loadDevices() async throws {
        guard let api = api() else { return }
        do {
            devices = try await api.devices().sorted { a, b in
                if a.current != b.current { return a.current }
                return a.lastSeenAt > b.lastSeenAt
            }
        } catch {
            if let e = error as? SyncServerError, case .unauthorized = e { handle(error) }
            throw error
        }
    }

    func renameDevice(_ device: SyncDevice, to name: String) async throws {
        guard let api = api() else { return }
        let updated = try await api.updateDevice(device.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), scopes: nil)
        replaceDevice(updated)
        if updated.id == deviceID { deviceName = updated.name; persistConfig() }
    }

    func setScopes(_ device: SyncDevice, _ scopes: [String]) async throws {
        guard let api = api() else { return }
        let updated = try await api.updateDevice(device.id, name: nil, scopes: scopes)
        replaceDevice(updated)
        if updated.id == deviceID {
            self.scopes = updated.scopes
            persistConfig()
        }
    }

    private func replaceDevice(_ device: SyncDevice) {
        var d = device
        if let i = devices.firstIndex(where: { $0.id == device.id }) {
            d.current = devices[i].current || device.current
            devices[i] = d
        }
    }

    func revokeDevice(_ device: SyncDevice) async throws {
        guard let api = api() else { return }
        try await api.deleteDevice(device.id)
        devices.removeAll { $0.id == device.id }
        if device.current || device.id == deviceID {
            signOutLocally(reason: "You removed this device from your account.")
        }
    }

    // MARK: TV pairing

    func startPairing(serverURL raw: String) async {
        cancelPairing()
        pairingError = nil
        guard let base = SyncServerAPI.normalize(raw) else {
            pairingError = SyncServerError.badURL.localizedDescription
            return
        }
        do {
            let res = try await SyncServerAPI(base: base, token: nil).pairStart(deviceName: SyncService.deviceName, platform: Self.platform)
            serverURL = base.absoluteString
            defaults.set(serverURL, forKey: "serversync.url")
            let pairId = res.pairId
            pairing = Pairing(code: res.code, pairId: pairId, serverURL: base.absoluteString,
                              expiresAt: Date().addingTimeInterval(TimeInterval(res.expiresIn ?? 600)), expired: false)
            pairTask = Task { [weak self] in
                await self?.pollPairing(base: base, pairId: pairId)
            }
        } catch {
            pairingError = error.localizedDescription
        }
    }

    func cancelPairing() {
        pairTask?.cancel()
        pairTask = nil
        pairing = nil
    }

    private func pollPairing(base: URL, pairId: String) async {
        let api = SyncServerAPI(base: base, token: nil)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let current = pairing, current.pairId == pairId else { return }
            if Date() > current.expiresAt {
                pairing?.expired = true
                return
            }
            do {
                switch try await api.pairPoll(pairId) {
                case .pending:
                    pairingError = nil
                case .approved(let auth):
                    guard pairing?.pairId == pairId else { return }
                    completeSignIn(base: base, auth: auth)
                    return
                case .expired:
                    pairing?.expired = true
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                // Transient (Wi-Fi blip): keep polling until the code expires.
                pairingError = error.localizedDescription
            }
        }
    }

    /// A signed-in phone approves the code shown on a TV.
    func approvePairing(code: String, scopes: [String]) async throws -> SyncDevice {
        guard let api = api() else { throw SyncServerError.unauthorized(nil) }
        let cleaned = code.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return try await api.approvePair(code: cleaned, scopes: scopes)
        } catch SyncServerError.status(let status, let message) where status == 400 || status == 404 || status == 410 {
            throw SyncServerError.status(status, message ?? "That code is wrong or has expired")
        }
    }
}
