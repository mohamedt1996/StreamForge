import SwiftUI

private struct GuideOffsetKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) { value = nextValue() }
}

private struct GuideSelection: Identifiable {
    var channel: XCChannel
    var programme: XCEPGListing
    var id: String { "\(channel.id)|\(programme.id)" }
}

/// Classic TV guide: channels down, time across, with a sticky channel column and a "now" line.
/// Uses the bulk XMLTV guide: pick a day (yesterday for catch-up, then today + the downloaded days).
struct GuideView: View {
    @Environment(DispatcharrStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerCoordinator.self) private var player
    @Environment(AppSettings.self) private var settings
    @State private var categoryID: String?
    @State private var favoritesOnly = false
    @State private var sportsOnly = false
    @State private var offset: CGPoint = .zero
    @State private var selected: GuideSelection?
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var now = Date()

    private var guide: GuideStore { .shared }

    #if os(tvOS)
    private let ppm: CGFloat = 9
    private let rowHeight: CGFloat = 96
    private let columnWidth: CGFloat = 300
    #else
    private var ppm: CGFloat { UIDevice.current.userInterfaceIdiom == .pad ? 6 : 4.2 }
    private let rowHeight: CGFloat = 64
    private var columnWidth: CGFloat { UIDevice.current.userInterfaceIdiom == .pad ? 190 : 118 }
    #endif

    /// The guide shows a whole day (local time).
    private var windowStart: Date { day }
    private var windowEnd: Date { Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400) }
    private var hours: Double { windowEnd.timeIntervalSince(windowStart) / 3600 }
    private var timelineWidth: CGFloat { CGFloat(hours * 60) * ppm }

    private var days: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let back = store.channels.contains(where: \.hasArchive) ? 1 : 0
        var forward = settings.values.guideDays
        if let latest = guide.latest {
            let available = cal.dateComponents([.day], from: today, to: cal.startOfDay(for: latest)).day ?? 0
            forward = max(1, min(forward, available + 1))
        } else {
            forward = 1
        }
        return (-back..<forward).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
    }

    private var channels: [XCChannel] {
        var list: [XCChannel]
        if favoritesOnly {
            list = library.favoriteChannelIDs.compactMap { store.channel($0) }
        } else if let categoryID {
            list = store.channelsByCategory[categoryID] ?? []
        } else {
            list = store.channels.filter { !library.isHidden(category: "live:\($0.categoryID)") }
        }
        if sportsOnly {
            let ids = Set(guide.liveSportsNow(channels: list, limit: 500).map(\.channel.id))
            list = list.filter { ids.contains($0.id) || SportsDetector.isSportsCategory(store.categoryName($0.categoryID, kind: .channel)) }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            dayPicker
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        timeHeader
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(channels) { channel in
                                GuideRow(channel: channel, windowStart: windowStart, windowEnd: windowEnd, ppm: ppm, rowHeight: rowHeight,
                                         columnWidth: columnWidth, timelineWidth: timelineWidth, stickyOffset: -offset.x,
                                         list: channels) { programme in selected = GuideSelection(channel: channel, programme: programme) }
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
                .onAppear { scrollToNow(proxy) }
                .onChange(of: day) { scrollToNow(proxy) }
            }
        }
        .screenBackground()
        .navigationTitle("TV Guide")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { favoritesOnly = true; sportsOnly = false; categoryID = nil } label: { Label("Favorites", systemImage: "star") }
                    Button { sportsOnly = true; favoritesOnly = false; categoryID = nil } label: { Label("Sports", systemImage: "sportscourt") }
                    Button { favoritesOnly = false; sportsOnly = false; categoryID = nil } label: { Label("All Channels", systemImage: "square.grid.2x2") }
                    Divider()
                    ForEach(store.liveCategories) { cat in
                        Button(cat.name) { favoritesOnly = false; sportsOnly = false; categoryID = cat.id }
                    }
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(item: $selected) { sel in
            ProgrammeDetailSheet(channel: sel.channel, programme: sel.programme)
                #if os(iOS)
                .presentationDetents([.medium, .large])
                #endif
        }
        .task {
            await guide.refreshIfStale()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                now = Date()
                let today = Calendar.current.startOfDay(for: now)
                if !days.contains(day) { day = today }
            }
        }
    }

    private var dayPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(days, id: \.self) { d in
                    Button { day = d } label: {
                        Text(dayLabel(d))
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(d == day ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surface), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if guide.phase.isBusy {
                    ProgressView().padding(.leading, 6)
                    Text(guide.statusText).font(.caption).foregroundStyle(Theme.secondaryText)
                } else if !guide.hasData {
                    Button { Task { await guide.refresh(force: true) } } label: {
                        Label("Download full guide", systemImage: "arrow.down.circle").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 8)
        }
    }

    private func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private func scrollToNow(_ proxy: ScrollViewProxy) {
        let cal = Calendar.current
        let target: Int
        if cal.isDate(day, inSameDayAs: Date()) {
            target = max(0, Int(Date().timeIntervalSince(windowStart) / 1800) - 1)
        } else if day < Date() {
            target = 36  // 18:00 yesterday: primetime catch-up
        } else {
            target = 36
        }
        DispatchQueue.main.async {
            withAnimation(nil) { proxy.scrollTo("slot-\(target)", anchor: .topLeading) }
        }
    }

    private var timeHeader: some View {
        let slots = Int(hours * 2)
        return HStack(spacing: 0) {
            Color.clear.frame(width: columnWidth)
            ForEach(0..<slots, id: \.self) { i in
                let date = windowStart.addingTimeInterval(Double(i) * 1800)
                Text(date, style: .time)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 30 * ppm, alignment: .leading)
                    .padding(.leading, 6)
                    .id("slot-\(i)")
            }
        }
        .frame(height: 30)
        .background(Theme.background.opacity(0.95))
        .offset(y: -min(0, offset.y))
        .zIndex(2)
    }

    @ViewBuilder
    private var nowLine: some View {
        if now >= windowStart && now < windowEnd {
            let x = columnWidth + CGFloat(now.timeIntervalSince(windowStart) / 60) * ppm
            Rectangle()
                .fill(Theme.live)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                .offset(x: x)
                .allowsHitTesting(false)
        }
    }
}

private struct GuideRow: View {
    var channel: XCChannel
    var windowStart: Date
    var windowEnd: Date
    var ppm: CGFloat
    var rowHeight: CGFloat
    var columnWidth: CGFloat
    var timelineWidth: CGFloat
    var stickyOffset: CGFloat
    var list: [XCChannel]
    var onSelect: (XCEPGListing) -> Void
    @Environment(DispatcharrStore.self) private var store
    @Environment(PlayerCoordinator.self) private var player
    private var reminders: ReminderCenter { .shared }

    var body: some View {
        let programmes = store.epg(for: channel.id).filter { $0.end > windowStart && $0.start < windowEnd }
        ZStack(alignment: .topLeading) {
            // Programme blocks
            ForEach(programmes) { p in
                let start = max(p.start, windowStart)
                let end = min(p.end, windowEnd)
                let x = columnWidth + CGFloat(start.timeIntervalSince(windowStart) / 60) * ppm
                let w = max(CGFloat(end.timeIntervalSince(start) / 60) * ppm - 3, 8)
                let reminded = reminders.has(channelID: channel.id, programme: p)
                Button { tap(p) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if p.isSports { SportBadge() }
                            if reminded { Image(systemName: "bell.fill").font(.caption2).foregroundStyle(Theme.gold) }
                            Text(p.title).font(.footnote.weight(.semibold)).lineLimit(1)
                        }
                        Text(p.timeRangeText).font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .frame(width: w, height: rowHeight, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(p.isLive ? AnyShapeStyle(Theme.accent.opacity(0.35))
                                  : (p.end < Date() ? AnyShapeStyle(Theme.surface.opacity(0.5)) : AnyShapeStyle(Theme.surface)))
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { onSelect(p) } label: { Label("Details", systemImage: "info.circle") }
                    if p.start > Date() {
                        Button { reminders.toggle(channel: channel, programme: p) } label: {
                            Label(reminded ? "Cancel Reminder" : "Remind Me", systemImage: reminded ? "bell.slash" : "bell")
                        }
                    }
                    if p.end < Date(), p.hasArchive || channel.hasArchive {
                        Button { player.playCatchup(channel, programme: p) } label: { Label("Watch from Start", systemImage: "gobackward") }
                    }
                }
                .offset(x: x)
            }
            if programmes.isEmpty {
                Text("No guide data")
                    .font(.caption).foregroundStyle(Theme.secondaryText)
                    .frame(width: 30 * 6 * ppm, height: rowHeight, alignment: .leading)
                    .padding(.leading, 10)
                    .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .offset(x: columnWidth + max(0, stickyOffset))
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

    private func tap(_ p: XCEPGListing) {
        if p.isLive { player.playChannel(channel, in: list) } else { onSelect(p) }
    }
}

struct ProgrammeDetailSheet: View {
    var channel: XCChannel
    var programme: XCEPGListing
    @Environment(DispatcharrStore.self) private var store
    @Environment(PlayerCoordinator.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    private var reminders: ReminderCenter { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ChannelLogo(url: channel.icon, name: channel.name, size: 52)
                VStack(alignment: .leading) {
                    Text(channel.name).font(.subheadline).foregroundStyle(Theme.secondaryText)
                    Text("\(programme.start.formatted(.dateTime.weekday(.abbreviated))) \(programme.timeRangeText)")
                        .font(.caption).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                if programme.isLive { LiveBadge() }
            }
            HStack(spacing: 6) {
                if programme.isSports { SportBadge() }
                if programme.isNew { Pill(text: "NEW", color: Theme.accent.opacity(0.5)) }
                if programme.isPremiere { Pill(text: "PREMIERE", color: Theme.accent2.opacity(0.5)) }
                if programme.isLiveBroadcast { Pill(text: "LIVE BROADCAST", color: Theme.live.opacity(0.5)) }
                ForEach(programme.categories.prefix(3), id: \.self) { Pill(text: $0) }
            }
            Text(programme.title).font(.title2.weight(.bold))
            let sub = [programme.episodeNumber, programme.subtitle].compactMap { $0 }.joined(separator: " · ")
            if !sub.isEmpty {
                Text(sub).font(.headline).foregroundStyle(Theme.secondaryText)
            }
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
                } else if programme.start > Date() {
                    let on = reminders.has(channelID: channel.id, programme: programme)
                    Button { reminders.toggle(channel: channel, programme: programme) } label: {
                        Label(on ? "Reminder Set" : "Remind Me", systemImage: on ? "bell.fill" : "bell").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(on ? Theme.gold : Theme.accent)
                    if let rest = store.restClient() {
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
            }
            if let message { Text(message).font(.footnote).foregroundStyle(Theme.secondaryText) }
        }
        .padding(24)
        .screenBackground()
    }
}
