import SwiftUI

private struct GuideOffsetKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
}

/// Classic TV guide: channels down, time across, with a sticky channel column and a "now" line.
struct GuideView: View {
    @Environment(DispatcharrStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerCoordinator.self) private var player
    @State private var categoryID: String?
    @State private var favoritesOnly = false
    @State private var offset: CGPoint = .zero
    @State private var selected: (XCChannel, XCEPGListing)?
    @State private var windowStart = GuideView.roundedStart()

    static let hours: Double = 12

    #if os(tvOS)
    private let ppm: CGFloat = 9
    private let rowHeight: CGFloat = 96
    private let columnWidth: CGFloat = 300
    #else
    private var ppm: CGFloat { UIDevice.current.userInterfaceIdiom == .pad ? 6 : 4.2 }
    private let rowHeight: CGFloat = 64
    private var columnWidth: CGFloat { UIDevice.current.userInterfaceIdiom == .pad ? 190 : 118 }
    #endif

    static func roundedStart() -> Date {
        let now = Date().addingTimeInterval(-30 * 60)
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        var c = comps
        c.minute = (comps.minute ?? 0) < 30 ? 0 : 30
        return Calendar.current.date(from: c) ?? now
    }

    private var channels: [XCChannel] {
        if favoritesOnly { return library.favoriteChannelIDs.compactMap { store.channel($0) } }
        if let categoryID { return store.channelsByCategory[categoryID] ?? [] }
        return store.channels.filter { !library.isHidden(category: "live:\($0.categoryID)") }
    }

    private var timelineWidth: CGFloat { CGFloat(Self.hours * 60) * ppm }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                timeHeader
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(channels) { channel in
                        GuideRow(channel: channel, windowStart: windowStart, ppm: ppm, rowHeight: rowHeight,
                                 columnWidth: columnWidth, timelineWidth: timelineWidth, stickyOffset: -offset.x,
                                 list: channels) { programme in selected = (channel, programme) }
                    }
                }
            }
            .overlay(alignment: .topLeading) { nowLine }
            .background(GeometryReader { geo in
                Color.clear.preference(key: GuideOffsetKey.self, value: geo.frame(in: .named("guide")).origin)
            })
        }
        .coordinateSpace(name: "guide")
        .onPreferenceChange(GuideOffsetKey.self) { offset = $0 }
        .screenBackground()
        .navigationTitle("TV Guide")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { favoritesOnly = true; categoryID = nil } label: { Label("Favorites", systemImage: "star") }
                    Button { favoritesOnly = false; categoryID = nil } label: { Label("All Channels", systemImage: "square.grid.2x2") }
                    Divider()
                    ForEach(store.liveCategories) { cat in
                        Button(cat.name) { favoritesOnly = false; categoryID = cat.id }
                    }
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let pair = selected {
                ProgrammeDetailSheet(channel: pair.0, programme: pair.1)
                    #if os(iOS)
                    .presentationDetents([.medium, .large])
                    #endif
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                windowStart = Self.roundedStart()
            }
        }
    }

    private var timeHeader: some View {
        let slots = Int(Self.hours * 2)
        return HStack(spacing: 0) {
            Color.clear.frame(width: columnWidth)
            ForEach(0..<slots, id: \.self) { i in
                let date = windowStart.addingTimeInterval(Double(i) * 1800)
                Text(date, style: .time)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 30 * ppm, alignment: .leading)
                    .padding(.leading, 6)
            }
        }
        .frame(height: 30)
        .background(Theme.background.opacity(0.95))
        .offset(y: -min(0, offset.y))
        .zIndex(2)
    }

    private var nowLine: some View {
        let x = columnWidth + CGFloat(Date().timeIntervalSince(windowStart) / 60) * ppm
        return Rectangle()
            .fill(Theme.live)
            .frame(width: 2)
            .frame(maxHeight: .infinity)
            .offset(x: x)
            .allowsHitTesting(false)
    }
}

private struct GuideRow: View {
    var channel: XCChannel
    var windowStart: Date
    var ppm: CGFloat
    var rowHeight: CGFloat
    var columnWidth: CGFloat
    var timelineWidth: CGFloat
    var stickyOffset: CGFloat
    var list: [XCChannel]
    var onSelect: (XCEPGListing) -> Void
    @Environment(DispatcharrStore.self) private var store
    @Environment(PlayerCoordinator.self) private var player

    var body: some View {
        let windowEnd = windowStart.addingTimeInterval(GuideView.hours * 3600)
        let programmes = store.epg(for: channel.id).filter { $0.end > windowStart && $0.start < windowEnd }
        ZStack(alignment: .topLeading) {
            // Programme blocks
            ForEach(programmes) { p in
                let start = max(p.start, windowStart)
                let end = min(p.end, windowEnd)
                let x = columnWidth + CGFloat(start.timeIntervalSince(windowStart) / 60) * ppm
                let w = max(CGFloat(end.timeIntervalSince(start) / 60) * ppm - 3, 8)
                Button { if p.isLive { player.playChannel(channel, in: list) } else { onSelect(p) } } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title).font(.footnote.weight(.semibold)).lineLimit(1)
                        Text(p.timeRangeText).font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .frame(width: w, height: rowHeight, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(p.isLive ? AnyShapeStyle(Theme.accent.opacity(0.35)) : AnyShapeStyle(Theme.surface))
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { onSelect(p) } label: { Label("Details", systemImage: "info.circle") }
                }
                .offset(x: x)
            }
            if programmes.isEmpty {
                Text("No guide data")
                    .font(.caption).foregroundStyle(Theme.secondaryText)
                    .frame(width: 30 * 6 * ppm, height: rowHeight, alignment: .leading)
                    .padding(.leading, 10)
                    .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .offset(x: columnWidth)
            }
            // Sticky channel cell
            Button { player.playChannel(channel, in: list) } label: {
                HStack(spacing: 8) {
                    ChannelLogo(url: channel.icon, name: channel.name, size: rowHeight * 0.62)
                    Text(channel.name).font(.caption.weight(.semibold)).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(width: columnWidth - 4, height: rowHeight)
                .background(Theme.background.opacity(0.97))
                .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .offset(x: max(0, stickyOffset))
            .zIndex(1)
        }
        .frame(width: columnWidth + timelineWidth, height: rowHeight, alignment: .topLeading)
        .task(id: channel.id) { await store.loadEPG(channel.id) }
    }
}

struct ProgrammeDetailSheet: View {
    var channel: XCChannel
    var programme: XCEPGListing
    @Environment(DispatcharrStore.self) private var store
    @Environment(PlayerCoordinator.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ChannelLogo(url: channel.icon, name: channel.name, size: 52)
                VStack(alignment: .leading) {
                    Text(channel.name).font(.subheadline).foregroundStyle(Theme.secondaryText)
                    Text(programme.timeRangeText).font(.caption).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                if programme.isLive { LiveBadge() }
            }
            Text(programme.title).font(.title2.weight(.bold))
            if !programme.description.isEmpty {
                ScrollView { Text(programme.description).font(.body).foregroundStyle(.white.opacity(0.85)) }
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                if programme.isLive {
                    Button { dismiss(); player.playChannel(channel, in: []) } label: { Label("Watch Live", systemImage: "play.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                } else if programme.end < Date(), programme.hasArchive || channel.hasArchive {
                    Button { dismiss(); player.playCatchup(channel, programme: programme) } label: {
                        Label("Watch from Start", systemImage: "gobackward").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else if programme.start > Date(), let rest = store.restClient() {
                    Button {
                        Task {
                            do {
                                try await rest.scheduleRecording(channelID: channel.id, programme: programme)
                                message = "Scheduled to record."
                            } catch { message = error.localizedDescription }
                        }
                    } label: { Label("Record", systemImage: "record.circle").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.live)
                }
            }
            if let message { Text(message).font(.footnote).foregroundStyle(Theme.secondaryText) }
        }
        .padding(24)
        .screenBackground()
    }
}
