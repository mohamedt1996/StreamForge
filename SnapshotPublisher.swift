import Foundation
#if os(iOS) && canImport(WidgetKit)
import WidgetKit
#endif
#if os(tvOS) && canImport(TVServices)
import TVServices
#endif

/// Writes the small snapshot the widgets (iOS) and the Top Shelf (tvOS) read from the App Group
/// container, then asks the system to refresh them. Without an App Group (some sideloading
/// tools strip it) nothing is written.
@MainActor
enum SnapshotPublisher {
    private static var pending: Task<Void, Never>?

    /// Debounced publish.
    static func schedule() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            publish()
        }
    }

    static func publish() {
        guard AppGroup.containerURL != nil else { return }
        let snapshot = makeSnapshot()
        guard snapshot.save() else { return }
        #if os(iOS) && canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
        #if os(tvOS) && canImport(TVServices)
        TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
    }

    static func makeSnapshot() -> SharedSnapshot {
        let library = LibraryStore.shared
        let store = DispatcharrStore.shared
        let continueItems: [SharedContinueItem] = library.continueWatching.prefix(10).compactMap { entry in
            guard let key = entry.key.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
                  let play = URL(string: "streamforge://resume?key=\(key)"),
                  let detail = URL(string: "streamforge://detail?key=\(key)") else { return nil }
            let subtitle = entry.episode.map { "\($0.code) · \(entry.remainingText)" } ?? entry.remainingText
            return SharedContinueItem(id: entry.key, title: entry.item.title, subtitle: subtitle,
                                      imageURL: remote(entry.episode?.still ?? entry.item.backdrop ?? entry.item.poster),
                                      posterURL: remote(entry.item.poster), progress: entry.fraction,
                                      playURL: play, detailURL: detail)
        }
        let ids = library.favoriteChannelIDs.isEmpty ? Array(library.recentChannelIDs.prefix(8)) : Array(library.favoriteChannelIDs.prefix(8))
        let channels: [SharedChannelItem] = ids.compactMap { id in
            guard let ch = store.channel(id), let url = URL(string: "streamforge://channel?id=\(id)") else { return nil }
            let now = store.nowPlaying(id)
            let next = store.nextUp(id)
            return SharedChannelItem(id: id, name: ch.name, number: ch.number, logoURL: remote(ch.icon),
                                     nowTitle: now?.title, nowStart: now?.start, nowEnd: now?.end,
                                     nextTitle: next?.title, nextStart: next?.start, url: url)
        }
        return SharedSnapshot(updatedAt: Date(), profileName: ProfileStore.shared.activeProfile.name,
                              continueWatching: continueItems, channels: channels)
    }

    /// Extensions can only load http(s) artwork.
    private static func remote(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }
}
