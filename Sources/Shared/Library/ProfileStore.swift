import Foundation
import Observation

/// A household profile. Each has its own library (favorites, channels, progress, watched…).
struct UserProfile: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var emoji: String
    var colorIndex: Int
    var isKids: Bool
    /// Live TV category ids allowed in kids mode on top of the name heuristic.
    var allowedCategoryIDs: [String]

    /// Optional 4-digit PIN that protects switching to this profile.
    var pin: String {
        get { Keychain.get("profile.pin.\(id)") ?? "" }
        nonmutating set { Keychain.set(newValue, for: "profile.pin.\(id)") }
    }
    var hasPIN: Bool { !pin.isEmpty }

    enum CodingKeys: String, CodingKey { case id, name, emoji, colorIndex, isKids, allowedCategoryIDs }

    static let emojis = ["🍿", "🎬", "📺", "🦊", "🐼", "🚀", "⚽️", "🎮", "🌟", "🦄", "🐶", "🎧"]
    static let colorCount = 8
}

extension UserProfile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Profile"
        emoji = (try? c.decodeIfPresent(String.self, forKey: .emoji)) ?? "🍿"
        colorIndex = (try? c.decodeIfPresent(Int.self, forKey: .colorIndex)) ?? 0
        isKids = (try? c.decodeIfPresent(Bool.self, forKey: .isKids)) ?? false
        allowedCategoryIDs = (try? c.decodeIfPresent([String].self, forKey: .allowedCategoryIDs)) ?? []
    }
}

/// Profiles, the active profile, PINs and the parent PIN that guards Settings in kids mode.
@MainActor
@Observable
final class ProfileStore {
    static let shared = ProfileStore()

    private(set) var profiles: [UserProfile]
    private(set) var activeProfileID: UUID
    /// Show the "Who's watching?" picker (on launch when there are several profiles).
    var needsSelection: Bool
    /// Kids mode: Settings were unlocked with the parent PIN for this session.
    private(set) var settingsUnlocked = false

    private init() {
        var list = FileStore.load([UserProfile].self, "profiles.json") ?? []
        if list.isEmpty {
            list = [UserProfile(id: UUID(), name: "Me", emoji: "🍿", colorIndex: 0, isKids: false, allowedCategoryIDs: [])]
            FileStore.save(list, "profiles.json", mirrorToDefaults: true)
        }
        profiles = list
        let stored = UserDefaults.standard.string(forKey: "profiles.active").flatMap(UUID.init(uuidString:))
        let active = list.first { $0.id == stored }?.id ?? list[0].id
        activeProfileID = active
        needsSelection = list.count > 1
    }

    var activeProfile: UserProfile { profiles.first { $0.id == activeProfileID } ?? profiles[0] }
    var isKidsMode: Bool { activeProfile.isKids }

    /// Guards Settings while a kids profile is active, and editing kids profiles.
    var parentPIN: String {
        get { Keychain.get("profiles.parentPIN") ?? "" }
        set { Keychain.set(newValue, for: "profiles.parentPIN") }
    }

    var settingsLocked: Bool { isKidsMode && !settingsUnlocked && !parentPIN.isEmpty }

    private func persist() {
        FileStore.save(profiles, "profiles.json", mirrorToDefaults: true)
        UserDefaults.standard.set(activeProfileID.uuidString, forKey: "profiles.active")
        CloudSync.shared.schedulePush()
    }

    // MARK: Switching

    func select(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        needsSelection = false
        settingsUnlocked = false
        guard id != activeProfileID else { return }
        LibraryStore.shared.switchProfile(to: id)
        activeProfileID = id
        persist()
        DispatcharrStore.shared.reapplyFilters()
        VODIndex.shared.rebuildIfNeeded()
        SnapshotPublisher.schedule()
    }

    func verify(pin: String, for profile: UserProfile) -> Bool {
        !profile.hasPIN || profile.pin == pin
    }

    func unlockSettings(pin: String) -> Bool {
        guard pin == parentPIN else { return false }
        settingsUnlocked = true
        return true
    }

    func lockSettings() { settingsUnlocked = false }

    // MARK: Editing

    @discardableResult
    func add(name: String, emoji: String, colorIndex: Int, isKids: Bool) -> UserProfile {
        let p = UserProfile(id: UUID(), name: name.trimmed.isEmpty ? "Profile \(profiles.count + 1)" : name.trimmed,
                            emoji: emoji, colorIndex: colorIndex, isKids: isKids, allowedCategoryIDs: [])
        profiles.append(p)
        persist()
        return p
    }

    func update(_ profile: UserProfile) {
        guard let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        let kidsChanged = profiles[i].isKids != profile.isKids || profiles[i].allowedCategoryIDs != profile.allowedCategoryIDs
        profiles[i] = profile
        persist()
        if profile.id == activeProfileID, kidsChanged {
            DispatcharrStore.shared.reapplyFilters()
            VODIndex.shared.rebuildIfNeeded()
        }
    }

    func delete(_ profile: UserProfile) {
        guard profiles.count > 1, let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles.remove(at: i)
        profile.pin = ""
        LibraryStore.shared.deleteLibrary(profileID: profile.id)
        if activeProfileID == profile.id {
            let next = profiles[0].id
            LibraryStore.shared.switchProfile(to: next)
            activeProfileID = next
            DispatcharrStore.shared.reapplyFilters()
        }
        persist()
    }

    /// Replaces profiles from a backup / another device.
    func importProfiles(_ incoming: [(profile: UserProfile, pin: String)], parentPIN: String?, activeID: UUID?) {
        guard !incoming.isEmpty else { return }
        for entry in incoming {
            entry.profile.pin = entry.pin
            if let i = profiles.firstIndex(where: { $0.id == entry.profile.id }) {
                profiles[i] = entry.profile
            } else {
                profiles.append(entry.profile)
            }
        }
        if let parentPIN, !parentPIN.isEmpty { self.parentPIN = parentPIN }
        persist()
        let target = activeID.flatMap { id in profiles.first { $0.id == id }?.id } ?? activeProfileID
        if target != activeProfileID {
            LibraryStore.shared.switchProfile(to: target)
            activeProfileID = target
            persist()
        } else {
            LibraryStore.shared.reloadActiveProfile()
        }
        DispatcharrStore.shared.reapplyFilters()
        needsSelection = profiles.count > 1
    }
}

/// Kids-mode content rules.
enum KidsFilter {
    private static let kidsWords = ["kid", "child", "cartoon", "family", "animation", "animated", "junior", "jr",
                                    "disney", "nick", "boomerang", "baby", "toon", "enfant", "infantil", "kinder", "niños", "bambini"]
    private static let kidsGenres = ["animation", "family", "kids", "children", "cartoon", "animación", "familia", "infantil"]
    /// Certifications that are fine for kids (US / UK / DE / FR style).
    private static let kidsCertifications: Set<String> = ["G", "PG", "TV-Y", "TV-Y7", "TV-Y7-FV", "TV-G", "TV-PG", "U", "UC", "0", "6", "FSK 0", "FSK 6", "TP", "ALL", "AL"]

    static func isKidsCategory(_ name: String) -> Bool {
        let lc = name.lowercased()
        return kidsWords.contains { lc.contains($0) }
    }

    static func isKidsGenre(_ genre: String) -> Bool {
        let lc = genre.lowercased()
        return kidsGenres.contains { lc.contains($0) }
    }

    static func allows(genre: String?, categoryName: String?) -> Bool {
        if let genre, isKidsGenre(genre) { return true }
        if let categoryName, isKidsCategory(categoryName) { return true }
        return false
    }

    /// For TMDB / addon items: genres decide; a known certification can only further restrict.
    static func allows(_ item: MediaItem, certification: String? = nil) -> Bool {
        if let certification, !certification.isEmpty {
            return kidsCertifications.contains(certification.uppercased())
        }
        return item.genres.contains { isKidsGenre($0) }
    }

    /// Applies the active profile's kids mode to a list of items (no-op for adults).
    @MainActor
    static func filter(_ items: [MediaItem]) -> [MediaItem] {
        guard ProfileStore.shared.isKidsMode else { return items }
        return items.filter { item in
            switch item.origin {
            // Server items were already filtered by DispatcharrStore.
            case .dispatcharrMovie, .dispatcharrSeries, .dispatcharrChannel: return true
            default: return allows(item)
            }
        }
    }
}
