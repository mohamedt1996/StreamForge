import WidgetKit
import SwiftUI
import UIKit

// MARK: - Shared look

private enum WidgetTheme {
    static let background = Color(red: 0.03, green: 0.027, blue: 0.07)
    static let accent = Color(red: 0.55, green: 0.36, blue: 0.96)
    static let accent2 = Color(red: 0.93, green: 0.28, blue: 0.60)
    static let live = Color(red: 0.96, green: 0.26, blue: 0.30)
    static let gradient = LinearGradient(colors: [accent, accent2], startPoint: .leading, endPoint: .trailing)
}

/// Widgets can't load images asynchronously in their views, so artwork is downloaded and
/// downscaled while building the timeline.
private enum ArtworkLoader {
    static func load(_ urls: [URL?], maxPixel: CGFloat) async -> [URL: UIImage] {
        await withTaskGroup(of: (URL, UIImage?).self) { group in
            for case let url? in urls {
                group.addTask {
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 8
                    guard let (data, _) = try? await URLSession.shared.data(for: request),
                          let image = UIImage(data: data) else { return (url, nil) }
                    return (url, downscale(image, maxPixel: maxPixel))
                }
            }
            var out: [URL: UIImage] = [:]
            for await (url, image) in group { if let image { out[url] = image } }
            return out
        }
    }

    private static func downscale(_ image: UIImage, maxPixel: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxPixel else { return image }
        let scale = maxPixel / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

private struct Artwork: View {
    var image: UIImage?
    var symbol: String

    var body: some View {
        if let image {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(colors: [WidgetTheme.accent.opacity(0.45), WidgetTheme.accent2.opacity(0.25)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: symbol).font(.title2).foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}

private struct ProgressBar: View {
    var value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(WidgetTheme.gradient).frame(width: geo.size.width * max(0, min(1, value)))
            }
        }
        .frame(height: 3)
    }
}

private struct EmptyWidget: View {
    var icon: String
    var text: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(WidgetTheme.gradient)
            Text(text).font(.caption).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Continue Watching

struct ContinueEntry: TimelineEntry {
    var date: Date
    var items: [SharedContinueItem]
    var images: [URL: UIImage]
}

struct ContinueProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContinueEntry {
        ContinueEntry(date: Date(), items: [], images: [:])
    }

    func getSnapshot(in context: Context, completion: @escaping (ContinueEntry) -> Void) {
        Task { completion(await makeEntry(family: context.family)) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueEntry>) -> Void) {
        Task {
            let entry = await makeEntry(family: context.family)
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(3600))))
        }
    }

    private func makeEntry(family: WidgetFamily) async -> ContinueEntry {
        let snapshot = SharedSnapshot.load() ?? .empty
        let count: Int
        switch family {
        case .systemSmall: count = 1
        case .systemMedium: count = 3
        default: count = 6
        }
        let items = Array(snapshot.continueWatching.prefix(count))
        let images = await ArtworkLoader.load(items.map { $0.imageURL ?? $0.posterURL }, maxPixel: 600)
        return ContinueEntry(date: Date(), items: items, images: images)
    }
}

struct ContinueWidgetView: View {
    var entry: ContinueEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if entry.items.isEmpty {
                EmptyWidget(icon: "play.rectangle.on.rectangle", text: "Start watching something in StreamForge")
            } else if family == .systemSmall, let item = entry.items.first {
                small(item)
            } else {
                list
            }
        }
        .containerBackground(for: .widget) { WidgetTheme.background }
    }

    private func image(_ item: SharedContinueItem) -> UIImage? {
        (item.imageURL ?? item.posterURL).flatMap { entry.images[$0] }
    }

    private func small(_ item: SharedContinueItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            Artwork(image: image(item), symbol: "play.fill")
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.caption.weight(.bold)).lineLimit(2)
                if let s = item.subtitle { Text(s).font(.caption2).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
                ProgressBar(value: item.progress)
            }
            .padding(10)
        }
        .widgetURL(item.playURL)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Continue Watching").font(.caption.weight(.heavy)).foregroundStyle(WidgetTheme.gradient)
                Spacer()
                Image(systemName: "play.circle.fill").foregroundStyle(WidgetTheme.accent)
            }
            ForEach(entry.items) { item in
                Link(destination: item.playURL) {
                    HStack(spacing: 10) {
                        Artwork(image: image(item), symbol: "play.fill")
                            .frame(width: 74, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.caption.weight(.semibold)).lineLimit(1)
                            if let s = item.subtitle {
                                Text(s).font(.caption2).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                            }
                            ProgressBar(value: item.progress)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
    }
}

struct ContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ContinueWatching", provider: ContinueProvider()) { entry in
            ContinueWidgetView(entry: entry)
        }
        .configurationDisplayName("Continue Watching")
        .description("Pick up where you left off.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Live Now

struct LiveEntry: TimelineEntry {
    var date: Date
    var channels: [SharedChannelItem]
    var logos: [URL: UIImage]
}

struct LiveProvider: TimelineProvider {
    func placeholder(in context: Context) -> LiveEntry {
        LiveEntry(date: Date(), channels: [], logos: [:])
    }

    func getSnapshot(in context: Context, completion: @escaping (LiveEntry) -> Void) {
        Task { completion(await makeEntry(at: Date(), family: context.family, logos: nil)) }
    }

    /// One entry per programme change so "now" stays accurate without the app running.
    func getTimeline(in context: Context, completion: @escaping (Timeline<LiveEntry>) -> Void) {
        Task {
            let first = await makeEntry(at: Date(), family: context.family, logos: nil)
            var entries = [first]
            let changes = first.channels.flatMap { [$0.nowEnd, $0.nextStart] }.compactMap { $0 }
                .filter { $0 > Date() && $0 < Date().addingTimeInterval(4 * 3600) }
            for date in Array(Set(changes)).sorted().prefix(12) {
                entries.append(await makeEntry(at: date, family: context.family, logos: first.logos))
            }
            completion(Timeline(entries: entries, policy: .after(Date().addingTimeInterval(1800))))
        }
    }

    private func makeEntry(at date: Date, family: WidgetFamily, logos: [URL: UIImage]?) async -> LiveEntry {
        let snapshot = SharedSnapshot.load() ?? .empty
        let count = family == .systemSmall ? 1 : (family == .systemMedium ? 3 : 7)
        let channels = Array(snapshot.channels.prefix(count))
        let images: [URL: UIImage]
        if let logos { images = logos } else { images = await ArtworkLoader.load(channels.map(\.logoURL), maxPixel: 160) }
        return LiveEntry(date: date, channels: channels, logos: images)
    }
}

struct LiveWidgetView: View {
    var entry: LiveEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if entry.channels.isEmpty {
                EmptyWidget(icon: "dot.radiowaves.left.and.right", text: "Favorite channels appear here")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(WidgetTheme.live).frame(width: 7, height: 7)
                        Text("On Now").font(.caption.weight(.heavy))
                        Spacer()
                    }
                    ForEach(entry.channels) { channel in
                        Link(destination: channel.url) { row(channel) }
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .widgetURL(entry.channels.first?.url)
            }
        }
        .containerBackground(for: .widget) { WidgetTheme.background }
    }

    private func row(_ c: SharedChannelItem) -> some View {
        let showingNext = c.nowEnd.map { entry.date >= $0 } ?? false
        let title = showingNext ? (c.nextTitle ?? "Live") : (c.nowTitle ?? "Live")
        let progress: Double = {
            guard !showingNext, let s = c.nowStart, let e = c.nowEnd, e > s else { return 0 }
            return min(1, max(0, entry.date.timeIntervalSince(s) / e.timeIntervalSince(s)))
        }()
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.1))
                if let url = c.logoURL, let logo = entry.logos[url] {
                    Image(uiImage: logo).resizable().aspectRatio(contentMode: .fit).padding(4)
                } else {
                    Text(String(c.name.prefix(2)).uppercased()).font(.caption2.weight(.bold))
                }
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.name).font(.caption.weight(.semibold)).lineLimit(1)
                Text(title).font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                if family != .systemSmall { ProgressBar(value: progress) }
            }
        }
    }
}

struct LiveNowWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LiveNow", provider: LiveProvider()) { entry in
            LiveWidgetView(entry: entry)
        }
        .configurationDisplayName("On Now")
        .description("What's on your favorite channels.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct StreamForgeWidgetBundle: WidgetBundle {
    var body: some Widget {
        ContinueWatchingWidget()
        LiveNowWidget()
    }
}
