import Foundation

// Compiled into the apps AND the widget / Top Shelf extensions, so it must only use Foundation.

/// The App Group shared with the extensions. Sideloading tools may drop the entitlement when
/// re-signing, in which case `containerURL` is nil and nothing is shared (the app still works).
enum AppGroup {
    static let identifier = "group.com.mohamedt.streamforge"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

/// One "continue watching" entry for the widget and the Apple TV Top Shelf.
struct SharedContinueItem: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var subtitle: String?
    /// 16:9 artwork (episode still or backdrop).
    var imageURL: URL?
    /// 2:3 poster.
    var posterURL: URL?
    var progress: Double
    /// streamforge://resume?key=…
    var playURL: URL
    /// streamforge://detail?key=…
    var detailURL: URL
}

/// A favorite channel with its current and next programme.
struct SharedChannelItem: Codable, Hashable, Identifiable {
    var id: Int
    var name: String
    var number: Int?
    var logoURL: URL?
    var nowTitle: String?
    var nowStart: Date?
    var nowEnd: Date?
    var nextTitle: String?
    var nextStart: Date?
    /// streamforge://channel?id=…
    var url: URL
}

/// Small JSON document the app writes for its extensions.
struct SharedSnapshot: Codable {
    var updatedAt: Date
    var profileName: String?
    var continueWatching: [SharedContinueItem]
    var channels: [SharedChannelItem]

    static let fileName = "shared-snapshot.json"

    static var fileURL: URL? { AppGroup.containerURL?.appendingPathComponent(fileName) }

    static func load() -> SharedSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(SharedSnapshot.self, from: data)
    }

    /// Returns false when there is no App Group container (nothing is written then).
    @discardableResult
    func save() -> Bool {
        guard let url = SharedSnapshot.fileURL else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(self) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static let empty = SharedSnapshot(updatedAt: Date(timeIntervalSince1970: 0), profileName: nil, continueWatching: [], channels: [])
}
