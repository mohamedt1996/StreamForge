import SwiftUI

// Admin-managed configuration on the client (server/PROTOCOL.md §5).
//
// Records the server admin set up for this user (Dispatcharr servers, addons, settings) carry
// `managed: true`. The app remembers which they are, and:
// * asks before the user removes one (or changes a managed setting): "Keep it" changes nothing,
//   "Remove from this account" dismisses it for the whole account (a `dismissed` record);
// * when sync brings back a managed item the user had removed on this device anyway, holds it and
//   asks once: "Restore from sync" or "Continue without it".

/// An admin-managed item shown in a prompt or in the list of items this account continues without.
struct ManagedItem: Identifiable, Equatable, Sendable {
    /// Record key (collection + "\n" + id).
    var id: String
    var collection: String
    var itemID: String
    var name: String
}

/// A removal the user asked for that needs confirmation because the item is managed.
struct ManagedRemoval: Identifiable {
    var item: ManagedItem
    /// Removes the item locally (only called after "Remove from this account").
    var perform: @MainActor () -> Void
    var id: String { item.id }
}

extension ServerSync {
    static let dismissedCollection = "dismissed"

    private static let settingLabels: [String: String] = [
        "metadataLanguage": "Metadata language", "metadataSource": "Metadata source", "maxResolution": "Maximum quality",
        "excludeCam": "Hide CAM releases", "streamSort": "Stream sorting", "autoplayNext": "Autoplay next episode",
        "resumePlayback": "Resume playback", "seekStep": "Skip interval", "skipIntros": "Skip intros", "autoSkip": "Auto-skip",
        "audioLanguage": "Audio language", "subtitleLanguage": "Subtitle language", "autoSubtitles": "Automatic subtitles",
        "subtitleScale": "Subtitle size", "hideAdult": "Hide adult content", "trailerAutoplay": "Autoplay trailers",
        "torrentMode": "Torrent engine", "remoteTorrServer": "Remote TorrServer",
    ]

    /// Dismissal id ("<collection>|<id>") for a record key.
    static func dismissalID(forKey key: String) -> String {
        let parts = splitKey(key)
        return parts.collection + "|" + parts.id
    }

    /// The record is managed by the admin and this account hasn't dismissed it.
    func isManagedForUser(_ key: String) -> Bool {
        state.managed.contains(key) && state.dismissed[Self.dismissalID(forKey: key)] == nil
    }

    /// Whether removing/changing this item needs the "Set up by your server" confirmation.
    func isManaged(_ collection: String, _ id: String) -> Bool {
        isSignedIn && isManagedForUser(Self.recordKey(collection, id))
    }

    func managedRemoval(_ collection: String, _ id: String, name: String, perform: @escaping @MainActor () -> Void) -> ManagedRemoval? {
        guard isManaged(collection, id) else { return nil }
        return ManagedRemoval(item: ManagedItem(id: Self.recordKey(collection, id), collection: collection, itemID: id, name: name),
                              perform: perform)
    }

    // MARK: Dismissals

    /// "Remove from this account": the item stays removed on all of this user's devices until it
    /// is restored here or the admin pushes it again. Call before removing the item locally.
    func dismiss(_ collection: String, _ id: String) {
        guard isSignedIn else { return }
        let key = Self.recordKey(collection, id)
        state.dismissed[Self.dismissalID(forKey: key)] = Self.nowMs()
        state.locallyRemoved.remove(key)
        refreshManagedPrompts()
        saveSoon()
        noteLocalChange()
    }

    /// "Restore": ends a dismissal; the server sends the item again.
    func restoreDismissed(_ item: ManagedItem) {
        guard isSignedIn else { return }
        state.dismissed[Self.dismissalID(forKey: item.id)] = nil
        refreshManagedPrompts()
        scan()
        saveNow()
        schedulePush(delay: 0)
    }

    /// Local records for the active dismissals (pushed like any other record).
    func dismissedLocalRecords() -> [LocalRecord] {
        state.dismissed.map { did, at in
            let bar = did.firstIndex(of: "|") ?? did.endIndex
            let collection = String(did[..<bar])
            let id = bar < did.endIndex ? String(did[did.index(after: bar)...]) : ""
            return LocalRecord(collection: Self.dismissedCollection, id: did, data: .object([
                "collection": .string(collection), "id": .string(id), "dismissedAt": .number(Double(at)),
            ]), stamp: at)
        }
    }

    // MARK: Applying server records

    /// Tracks the managed flag of a pulled record (any version, so the newest rev wins).
    func trackManaged(_ r: SyncRecord) {
        switch r.collection {
        case "servers", "addons", "settings", "secrets":
            let key = Self.recordKey(r.collection, r.id)
            if r.managed, !r.deleted {
                state.managed.insert(key)
                if r.collection == "settings", let v = r.data?["value"] { state.managedSettings[r.id] = v }
                if r.collection != "secrets" { state.managedNames[key] = Self.managedName(r.collection, r.id, r.data) }
            } else {
                state.managed.remove(key)
                if r.collection == "settings" { state.managedSettings[r.id] = nil }
            }
            if r.deleted {
                state.locallyRemoved.remove(key)
                state.held[key] = nil
            }
        default:
            break
        }
    }

    /// A `dismissed` record from another device (or the server) that is newer than this device's.
    func applyDismissal(_ r: SyncRecord) {
        if r.deleted {
            state.dismissed[r.id] = nil
        } else {
            state.dismissed[r.id] = r.data?["dismissedAt"]?.doubleValue.map { Int64($0) } ?? r.updatedAt
        }
    }

    /// A managed server/addon (or a server's credentials) the user removed on this device comes
    /// back: hold it for the restore prompt instead of re-adding it. Returns true when held.
    func holdIfLocallyRemoved(_ r: SyncRecord) -> Bool {
        guard !r.deleted, r.managed else { return false }
        let key = Self.recordKey(r.collection, r.id)
        switch r.collection {
        case "servers", "addons":
            guard state.locallyRemoved.contains(key), state.dismissed[Self.dismissalID(forKey: key)] == nil else { return false }
            let present = r.collection == "servers"
                ? DispatcharrStore.shared.servers.contains { $0.id.uuidString.lowercased() == r.id.lowercased() }
                : AddonManager.shared.addons.contains { $0.manifestURL.absoluteString == r.id }
            if present {
                state.locallyRemoved.remove(key)
                return false
            }
        case "secrets":
            guard r.id.hasPrefix("server:") else { return false }
            let serverKey = Self.recordKey("servers", String(r.id.dropFirst("server:".count)).lowercased())
            guard state.locallyRemoved.contains(serverKey) || state.held[serverKey] != nil else { return false }
        default:
            return false
        }
        state.held[key] = HeldRecord(collection: r.collection, id: r.id, data: r.data, updatedAt: r.updatedAt, rev: r.rev)
        // This device still doesn't have it: don't queue a tombstone, don't apply it as older.
        state.known[key] = Known(h: "", t: r.updatedAt, d: true)
        outbox[key] = nil
        return true
    }

    static func managedName(_ collection: String, _ id: String, _ data: SyncJSON?) -> String {
        switch collection {
        case "settings":
            return settingLabels[id] ?? id
        case "addons":
            if let n = data?["name"]?.stringValue, !n.isEmpty { return n }
            return URL(string: id)?.host ?? "Addon"
        case "servers":
            if let n = data?["name"]?.stringValue, !n.isEmpty { return n }
            return "Dispatcharr server"
        default:
            return id
        }
    }

    private func itemName(_ key: String) -> String {
        if let n = state.managedNames[key] { return n }
        let parts = Self.splitKey(key)
        return Self.managedName(parts.collection, parts.id, nil)
    }

    /// Recomputes the observable prompt lists from the persisted state.
    func refreshManagedPrompts() {
        // Credentials whose server isn't held (or locally removed) any more have nothing to wait for.
        for (key, h) in state.held where h.collection == "secrets" {
            let serverKey = Self.recordKey("servers", String(h.id.dropFirst("server:".count)).lowercased())
            if state.held[serverKey] == nil, !state.locallyRemoved.contains(serverKey) { state.held[key] = nil }
        }
        let restore = state.held.values
            .filter { $0.collection != "secrets" }
            .map { h -> ManagedItem in
                let key = Self.recordKey(h.collection, h.id)
                return ManagedItem(id: key, collection: h.collection, itemID: h.id, name: Self.managedName(h.collection, h.id, h.data))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if restore != restorePrompt {
            restorePrompt = restore
            restorePromptSnoozed = false
        }
        let dismissed = state.dismissed.keys.compactMap { did -> ManagedItem? in
            guard let bar = did.firstIndex(of: "|") else { return nil }
            let collection = String(did[..<bar]), id = String(did[did.index(after: bar)...])
            let key = Self.recordKey(collection, id)
            return ManagedItem(id: key, collection: collection, itemID: id, name: itemName(key))
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if dismissed != dismissedItems { dismissedItems = dismissed }
        // A pending setting question is moot once the setting has the managed value again (or
        // isn't managed any more).
        if !settingPrompt.isEmpty {
            let values = settingsValues(AppSettings.shared.values)
            let still = settingPrompt.filter { item in
                guard isManagedForUser(item.id), let managed = state.managedSettings[item.itemID], let local = values[item.itemID] else { return false }
                return managed.canonicalString != local.canonicalString
            }
            if still != settingPrompt { settingPrompt = still }
        }
    }

    // MARK: Restore prompt

    /// "Restore from sync": put the held items back.
    func restoreHeld() {
        let held = Array(state.held.values)
        guard !held.isEmpty else { return }
        state.held = [:]
        var records: [SyncRecord] = []
        for h in held {
            let key = Self.recordKey(h.collection, h.id)
            state.known[key] = nil
            state.locallyRemoved.remove(key)
            if h.collection == "secrets" {
                state.locallyRemoved.remove(Self.recordKey("servers", String(h.id.dropFirst("server:".count)).lowercased()))
            }
            records.append(SyncRecord(collection: h.collection, id: h.id, data: h.data, deleted: false,
                                      updatedAt: h.updatedAt, rev: h.rev, managed: true))
        }
        apply(records)
        LibraryStore.shared.flush()
        refreshManagedPrompts()
        saveNow()
    }

    /// "Continue without it": dismiss the held items for this account.
    func continueWithoutHeld() {
        let held = Array(state.held.values)
        guard !held.isEmpty else { return }
        state.held = [:]
        let now = Self.nowMs()
        for h in held {
            let key = Self.recordKey(h.collection, h.id)
            state.locallyRemoved.remove(key)
            if h.collection != "secrets" { state.dismissed[Self.dismissalID(forKey: key)] = now }
            if h.collection == "secrets", !hasSecretsScope { continue }
            // The removal itself (the server tombstones it anyway once it has the dismissal).
            let t = max(now, h.updatedAt + 1)
            state.known[key] = Known(h: "", t: t, d: true)
            outbox[key] = OutboxEntry(collection: h.collection, id: h.id, data: nil, deleted: true, updatedAt: t)
        }
        scan()
        refreshManagedPrompts()
        saveNow()
        schedulePush(delay: 0)
    }

    // MARK: Managed settings

    /// Called on every local change: notices edits of managed settings right away.
    func checkManagedSettingEdits() {
        guard isSignedIn, !applyingRemote, !state.managedSettings.isEmpty else { return }
        let values = settingsValues(AppSettings.shared.values)
        var prompt = settingPrompt
        for (k, v) in values {
            let key = Self.recordKey("settings", k)
            guard isManagedForUser(key), let known = state.known[key], !known.d,
                  known.h != Self.fingerprint(.object(["value": v])),
                  !prompt.contains(where: { $0.id == key }) else { continue }
            prompt.append(ManagedItem(id: key, collection: "settings", itemID: k, name: itemName(key)))
        }
        if prompt != settingPrompt { settingPrompt = prompt }
    }

    /// "Keep it": put the managed values back.
    func keepManagedSettings() {
        let items = settingPrompt
        settingPrompt = []
        var values = AppSettings.shared.values
        for item in items {
            if let v = state.managedSettings[item.itemID] { _ = applySetting(item.itemID, v, to: &values) }
        }
        applyingRemote = true
        AppSettings.shared.values = values
        applyingRemote = false
        rebaseline(only: ["settings"])
    }

    /// "Remove from this account": the user's own values replace the managed ones on all devices.
    func releaseManagedSettings() {
        let items = settingPrompt
        settingPrompt = []
        let now = Self.nowMs()
        let values = settingsValues(AppSettings.shared.values)
        for item in items {
            state.dismissed[Self.dismissalID(forKey: item.id)] = now
            guard let v = values[item.itemID] else { continue }
            let data: SyncJSON = .object(["value": v])
            let t = max(now, (state.known[item.id]?.t ?? 0) + 1)
            state.known[item.id] = Known(h: Self.fingerprint(data), t: t, d: false)
            outbox[item.id] = OutboxEntry(collection: "settings", id: item.itemID, data: data, deleted: false, updatedAt: t)
        }
        scan()
        refreshManagedPrompts()
        saveNow()
        schedulePush(delay: 0)
    }
}

// MARK: - UI

extension ManagedItem {
    static func joinedNames(_ items: [ManagedItem]) -> String {
        let names = items.map { "“\($0.name)”" }
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return names[0] + " and " + names[1]
        default: return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
    }
}

/// App-wide prompts: items sync brought back after a local removal, and changed managed settings.
@MainActor
struct ManagedSyncPrompts: ViewModifier {
    enum Prompt {
        case settings([ManagedItem])
        case restore([ManagedItem])
    }

    private var sync: ServerSync { .shared }

    private var prompt: Prompt? {
        if !sync.settingPrompt.isEmpty { return .settings(sync.settingPrompt) }
        if !sync.restorePrompt.isEmpty, !sync.restorePromptSnoozed { return .restore(sync.restorePrompt) }
        return nil
    }

    func body(content: Content) -> some View {
        // One alert for both questions (a view can present only one alert at a time).
        let current = prompt
        return content.alert("Set up by your server", isPresented: Binding(
            get: { current != nil },
            set: { shown in
                guard !shown, let current else { return }
                // Dismissed without an answer (the buttons empty their list first): a setting keeps
                // the server's value, the restore question waits for the next sync.
                switch current {
                case .settings:
                    if !sync.settingPrompt.isEmpty { sync.keepManagedSettings() }
                case .restore:
                    if !sync.restorePrompt.isEmpty { sync.restorePromptSnoozed = true }
                }
            }
        ), presenting: current) { p in
            switch p {
            case .settings:
                Button("Keep it", role: .cancel) { sync.keepManagedSettings() }
                Button("Remove from this account", role: .destructive) { sync.releaseManagedSettings() }
            case .restore:
                Button("Restore from sync") { sync.restoreHeld() }
                Button("Continue without it", role: .destructive) { sync.continueWithoutHeld() }
            }
        } message: { p in
            switch p {
            case .settings(let items):
                Text("\(ManagedItem.joinedNames(items)) \(items.count == 1 ? "was" : "were") set for you by your StreamForge server admin. Keep the server's value, or remove it from this account and use your own on all your devices?")
            case .restore(let items):
                Text("\(ManagedItem.joinedNames(items)) \(items.count == 1 ? "was" : "were") added for you by your StreamForge server admin. You removed \(items.count == 1 ? "it" : "them") on this device: restore \(items.count == 1 ? "it" : "them") from sync, or continue without \(items.count == 1 ? "it" : "them") on all your devices?")
            }
        }
    }
}

/// "Set up by your server" confirmation for removing a managed addon or Dispatcharr server.
@MainActor
struct ManagedRemovalAlert: ViewModifier {
    @Binding var removal: ManagedRemoval?

    func body(content: Content) -> some View {
        content.alert("Set up by your server", isPresented: Binding(
            get: { removal != nil },
            set: { if !$0 { removal = nil } }
        ), presenting: removal) { r in
            Button("Keep it", role: .cancel) { removal = nil }
            Button("Remove from this account", role: .destructive) {
                ServerSync.shared.dismiss(r.item.collection, r.item.itemID)
                r.perform()
                removal = nil
            }
        } message: { r in
            Text("“\(r.item.name)” was added for you by your StreamForge server admin. Removing it here removes it on all your devices.")
        }
    }
}

extension View {
    /// App-wide "Restore from sync" / managed-setting prompts (attach once, at the root).
    func managedSyncPrompts() -> some View { modifier(ManagedSyncPrompts()) }

    /// Confirmation before removing an admin-managed item.
    func managedRemovalAlert(_ removal: Binding<ManagedRemoval?>) -> some View { modifier(ManagedRemovalAlert(removal: removal)) }
}
