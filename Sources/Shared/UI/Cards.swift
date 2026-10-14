import SwiftUI

/// Poster card used in every grid and shelf. Upgrades missing artwork via TMDB lazily.
struct PosterCard: View {
    var item: MediaItem
    var width: CGFloat = Theme.posterWidth
    var showTitle = true
    @State private var enriched: URL?
    @Environment(LibraryStore.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RemoteImage(url: enriched ?? item.poster, placeholderSymbol: item.type == .series ? "tv" : "film",
                            placeholderText: item.title)
                    .frame(width: width, height: width * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .bottom) {
                        if let p = library.progress(for: item), p.fraction > 0.02 {
                            ProgressLine(fraction: p.fraction).padding(6)
                        }
                    }
                if item.type == .series, NewEpisodeTracker.shared.isNew(item) {
                    Text("NEW")
                        .font(.caption2.weight(.heavy))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Theme.live, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .foregroundStyle(.white)
                        .padding(6)
                } else if library.isWatched(item) {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Theme.accent)
                        .font(.title3)
                        .padding(6)
                } else if let r = item.rating, r > 0 {
                    RatingView(rating: r)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.65), in: Capsule())
                        .padding(6)
                }
            }
            if showTitle {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.footnote.weight(.semibold)).lineLimit(1)
                    if let y = item.yearText {
                        Text(y).font(.caption2).foregroundStyle(Theme.secondaryText)
                    }
                }
                .frame(width: width, alignment: .leading)
            }
        }
        .task(id: item.id) {
            if item.poster == nil { enriched = await MetadataService.shared.enrichedPoster(for: item) }
        }
    }
}

/// 16:9 card for continue-watching, episodes and channels.
struct LandscapeCard: View {
    var title: String
    var subtitle: String?
    var image: URL?
    var fallbackImage: URL?
    var progress: Double?
    var badge: String?
    var width: CGFloat = Theme.landscapeWidth
    var symbol: String = "play.rectangle"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: image ?? fallbackImage, placeholderSymbol: symbol)
                    .frame(width: width, height: width * 9 / 16)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    if let badge { Pill(text: badge, color: .black.opacity(0.6)) }
                    if let progress { ProgressLine(fraction: progress) }
                }
                .padding(8)
            }
            .frame(width: width, height: width * 9 / 16)
            Text(title).font(.footnote.weight(.semibold)).lineLimit(1).frame(width: width, alignment: .leading)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1).frame(width: width, alignment: .leading)
            }
        }
    }
}

/// Horizontal shelf of items with a header.
struct Shelf<Item: Identifiable, Content: View>: View {
    var title: String
    var subtitle: String?
    var items: [Item]
    var seeAll: (() -> Void)?
    @ViewBuilder var content: (Item) -> Content

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: title, subtitle: subtitle, action: seeAll)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: shelfSpacing) {
                        ForEach(items) { content($0) }
                    }
                    .padding(.horizontal, Theme.gutter)
                    #if os(tvOS)
                    .padding(.vertical, 30)
                    #endif
                }
                #if os(tvOS)
                .scrollClipDisabled()
                #endif
            }
        }
    }

    private var shelfSpacing: CGFloat {
        #if os(tvOS)
        return 40
        #else
        return 12
        #endif
    }
}

struct ChannelLogo: View {
    var url: URL?
    var name: String
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(Theme.surfaceHigh)
            if url != nil {
                RemoteImage(url: url, contentMode: .fit, placeholderSymbol: "tv")
                    .padding(size * 0.12)
            } else {
                Text(initials).font(.system(size: size * 0.32, weight: .bold)).foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(width: size, height: size)
    }

    private var initials: String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}

/// Responsive poster grid.
struct PosterGrid: View {
    var items: [MediaItem]
    var onSelect: (MediaItem) -> Void
    var onAppearLast: (() -> Void)?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.posterWidth, maximum: Theme.posterWidth * 1.25), spacing: spacing, alignment: .top)]
    }
    private var spacing: CGFloat {
        #if os(tvOS)
        return 48
        #else
        return 12
        #endif
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: spacing * 1.5) {
            ForEach(items) { item in
                Button { onSelect(item) } label: { PosterCard(item: item) }
                    .cardButtonStyle()
                    .contextMenu { MediaContextMenu(item: item) }
                    .onAppear { if item.id == items.last?.id { onAppearLast?() } }
            }
        }
        .padding(.horizontal, Theme.gutter)
    }
}

struct MediaContextMenu: View {
    var item: MediaItem
    @Environment(LibraryStore.self) private var library

    var body: some View {
        Button {
            library.toggleFavorite(item)
        } label: {
            Label(library.isFavorite(item) ? "Remove from My List" : "Add to My List",
                  systemImage: library.isFavorite(item) ? "minus.circle" : "plus.circle")
        }
        Button {
            library.setWatched(item, !library.isWatched(item))
        } label: {
            Label(library.isWatched(item) ? "Mark as Unwatched" : "Mark as Watched",
                  systemImage: library.isWatched(item) ? "eye.slash" : "eye")
        }
    }
}
