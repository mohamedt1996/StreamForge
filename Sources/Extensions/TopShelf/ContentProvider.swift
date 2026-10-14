import TVServices
import Foundation

/// Apple TV Top Shelf: Continue Watching and favorite channels, from the snapshot the app
/// writes into the shared App Group container.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        guard let snapshot = SharedSnapshot.load() else {
            completionHandler(nil)
            return
        }
        var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []

        let continueItems: [TVTopShelfSectionedItem] = snapshot.continueWatching.prefix(10).map { entry in
            let item = TVTopShelfSectionedItem(identifier: entry.id)
            item.title = entry.subtitle.map { "\(entry.title) · \($0)" } ?? entry.title
            item.imageShape = .hdtv
            if let url = entry.imageURL ?? entry.posterURL {
                item.setImageURL(url, for: .screenScale1x)
                item.setImageURL(url, for: .screenScale2x)
            }
            item.playbackProgress = max(0, min(1, entry.progress))
            item.displayAction = TVTopShelfAction(url: entry.detailURL)
            item.playAction = TVTopShelfAction(url: entry.playURL)
            return item
        }
        if !continueItems.isEmpty {
            let section = TVTopShelfItemCollection(items: continueItems)
            section.title = "Continue Watching"
            sections.append(section)
        }

        let channelItems: [TVTopShelfSectionedItem] = snapshot.channels.prefix(12).map { channel in
            let item = TVTopShelfSectionedItem(identifier: "channel-\(channel.id)")
            var title = channel.name
            if let now = channel.nowTitle { title += " · \(now)" }
            item.title = title
            item.imageShape = .square
            if let url = channel.logoURL {
                item.setImageURL(url, for: .screenScale1x)
                item.setImageURL(url, for: .screenScale2x)
            }
            if let s = channel.nowStart, let e = channel.nowEnd, e > s {
                item.playbackProgress = max(0, min(1, Date().timeIntervalSince(s) / e.timeIntervalSince(s)))
            }
            item.displayAction = TVTopShelfAction(url: channel.url)
            item.playAction = TVTopShelfAction(url: channel.url)
            return item
        }
        if !channelItems.isEmpty {
            let section = TVTopShelfItemCollection(items: channelItems)
            section.title = "On Now"
            sections.append(section)
        }

        completionHandler(sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections))
    }
}
