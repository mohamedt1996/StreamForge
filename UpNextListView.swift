import SwiftUI

/// Every "next episode" from Trakt, newest-aired first.
struct UpNextListView: View {
    @Environment(TraktService.self) private var trakt
    @Environment(AppRouter.self) private var router

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.landscapeWidth, maximum: Theme.landscapeWidth * 1.3), spacing: spacing, alignment: .top)]
    }
    private var spacing: CGFloat {
        #if os(tvOS)
        return 48
        #else
        return 14
        #endif
    }

    var body: some View {
        Group {
            if !trakt.isSignedIn {
                EmptyStateView(icon: "checkmark.seal", title: "Connect Trakt",
                               message: "Sign in with Trakt in Settings to see the next episode of every show you watch.",
                               actionTitle: "Open Settings") { router.push(.settings) }
            } else if trakt.upNext.isEmpty {
                EmptyStateView(icon: "tv", title: "You're all caught up",
                               message: "New episodes of shows you watch will appear here.")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: spacing * 1.4) {
                        ForEach(sorted) { entry in
                            Button { router.push(.detail(entry.item)) } label: {
                                LandscapeCard(title: entry.item.title,
                                              subtitle: subtitle(entry),
                                              image: entry.episode.still ?? entry.item.backdrop,
                                              fallbackImage: entry.item.poster,
                                              badge: entry.isNew ? "NEW" : nil)
                            }
                            .cardButtonStyle()
                        }
                    }
                    .padding(.horizontal, Theme.gutter)
                    .padding(.vertical, 12)
                }
            }
        }
        .screenBackground()
        .navigationTitle("Up Next")
        .refreshable { await trakt.refreshUpNext(force: true) }
    }

    private var sorted: [UpNextEntry] {
        trakt.upNext.sorted { a, b in
            if a.isNew != b.isNew { return a.isNew }
            return (a.firstAired ?? a.lastWatchedAt) > (b.firstAired ?? b.lastWatchedAt)
        }
    }

    private func subtitle(_ entry: UpNextEntry) -> String {
        var s = "\(entry.episode.code) · \(entry.episode.title)"
        if let aired = entry.firstAired, aired > Date() {
            s += " · \(aired.formatted(date: .abbreviated, time: .omitted))"
        }
        return s
    }
}
