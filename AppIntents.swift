import AppIntents
import Foundation

/// A live channel Siri / Shortcuts can tune ("Play BBC One in StreamForge").
struct ChannelEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Channel"
    static var defaultQuery = ChannelQuery()

    var id: Int
    var name: String
    var number: Int?

    var displayRepresentation: DisplayRepresentation {
        if let number {
            return DisplayRepresentation(title: "\(name)", subtitle: "Channel \(number)")
        }
        return DisplayRepresentation(title: "\(name)")
    }

    init(id: Int, name: String, number: Int?) {
        self.id = id
        self.name = name
        self.number = number
    }
}

struct ChannelQuery: EntityStringQuery {
    func entities(for identifiers: [Int]) async throws -> [ChannelEntity] {
        await MainActor.run {
            identifiers.compactMap { id in
                DispatcharrStore.shared.channel(id).map { ChannelEntity(id: $0.id, name: $0.name, number: $0.number) }
            }
        }
    }

    func entities(matching string: String) async throws -> [ChannelEntity] {
        await MainActor.run {
            let q = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !q.isEmpty else { return [] }
            let channels = DispatcharrStore.shared.channels
            if let n = Int(q) {
                return channels.filter { $0.number == n }.map { ChannelEntity(id: $0.id, name: $0.name, number: $0.number) }
            }
            let exact = channels.filter { $0.name.lowercased() == q }
            let prefix = channels.filter { $0.name.lowercased().hasPrefix(q) && $0.name.lowercased() != q }
            let contains = channels.filter { !$0.name.lowercased().hasPrefix(q) && $0.name.lowercased().contains(q) }
            return Array((exact + prefix + contains).prefix(25)).map { ChannelEntity(id: $0.id, name: $0.name, number: $0.number) }
        }
    }

    func suggestedEntities() async throws -> [ChannelEntity] {
        await MainActor.run {
            let store = DispatcharrStore.shared
            let library = LibraryStore.shared
            var ids = library.favoriteChannelIDs
            for id in library.recentChannelIDs where !ids.contains(id) { ids.append(id) }
            // Siri only matches spoken channel names ("Play BBC One") against these suggestions, so
            // favorites and recents come first, then the rest of the lineup.
            var list = ids.compactMap { store.channel($0) }
            let chosen = Set(list.map(\.id))
            list += store.channels.filter { !chosen.contains($0.id) }
            return list.prefix(150).map { ChannelEntity(id: $0.id, name: $0.name, number: $0.number) }
        }
    }
}

struct PlayChannelIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Channel"
    static var description = IntentDescription("Opens StreamForge and tunes a live TV channel.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Channel")
    var channel: ChannelEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$channel)")
    }

    init() {}

    init(channel: ChannelEntity) {
        self.channel = channel
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.tuneChannel(id: channel.id)
        return .result()
    }
}

struct ResumeWatchingIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Watching"
    static var description = IntentDescription("Opens StreamForge and resumes what you watched last.")
    static var openAppWhenRun: Bool = true

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.resumeLatest()
        return .result()
    }
}

struct SearchIntent: AppIntent {
    static var title: LocalizedStringResource = "Search StreamForge"
    static var description = IntentDescription("Opens StreamForge's search with your query.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Search for")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search for \(\.$query)")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.openSearch(query)
        return .result()
    }
}

struct StreamForgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayChannelIntent(),
            phrases: [
                "Play \(\.$channel) in \(.applicationName)",
                "Watch \(\.$channel) on \(.applicationName)",
                "Tune \(.applicationName) to \(\.$channel)",
            ],
            shortTitle: "Play Channel",
            systemImageName: "dot.radiowaves.left.and.right")
        AppShortcut(
            intent: ResumeWatchingIntent(),
            phrases: [
                "Resume watching in \(.applicationName)",
                "Continue watching in \(.applicationName)",
            ],
            shortTitle: "Resume Watching",
            systemImageName: "play.fill")
        AppShortcut(
            intent: SearchIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Search in \(.applicationName)",
            ],
            shortTitle: "Search",
            systemImageName: "magnifyingglass")
    }
}
