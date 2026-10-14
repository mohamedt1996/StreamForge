import SwiftUI
import AVFoundation

/// Full-screen grid of 2–4 live channels. Presented by `playerPresentation()` when
/// `PlayerCoordinator.shared.multiview` is set (see `PlayerCoordinator.openMultiview(_:)`).
struct MultiviewView: View {
    let channels: [XCChannel]
    @State private var model: MultiviewModel?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let model { MultiviewScreen(model: model) }
        }
        .onAppear {
            // Created once: every tile owns an mpv instance.
            if model == nil { model = MultiviewModel(channels: channels) }
        }
    }
}

private enum MultiviewPickerTarget: Identifiable {
    case add
    case replace(UUID)
    var id: String {
        switch self {
        case .add: return "add"
        case .replace(let tile): return "replace-\(tile.uuidString)"
        }
    }
}

struct MultiviewScreen: View {
    let model: MultiviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var picker: MultiviewPickerTarget?
    @FocusState private var focusedTile: UUID?

    var body: some View {
        GeometryReader { geo in
            let grid = Self.gridShape(count: model.tiles.count, size: geo.size)
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                if model.tiles.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: gap) {
                        ForEach(0..<grid.rows, id: \.self) { r in
                            HStack(spacing: gap) {
                                ForEach(0..<grid.cols, id: \.self) { c in
                                    cell(index: r * grid.cols + c)
                                }
                            }
                        }
                    }
                    .padding(outerPadding)
                }
                #if os(iOS)
                topBar
                #endif
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .sheet(item: $picker) { target in
            MultiviewChannelPicker(title: pickerTitle(target), exclude: model.channelIDs) { channel in
                switch target {
                case .add: model.add(channel)
                case .replace(let id): model.replace(id, with: channel)
                }
            }
        }
        .onChange(of: focusedTile) {
            if let id = focusedTile { model.setAudio(id) }
        }
        .onAppear {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .moviePlayback)
            try? session.setActive(true)
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = true
            #endif
            if model.tiles.isEmpty {
                // Wait for the cover's presentation to finish before stacking the picker sheet on it.
                Task {
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    if model.tiles.isEmpty && picker == nil { picker = .add }
                }
            }
        }
        .onDisappear {
            // Only when multiview is really closing: a sheet covering the grid (tvOS) also fires onDisappear.
            if PlayerCoordinator.shared.multiview == nil { model.shutdown() }
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
        }
        #if os(tvOS)
        .onExitCommand { dismiss() }
        #endif
    }

    // MARK: Layout

    static func gridShape(count: Int, size: CGSize) -> (cols: Int, rows: Int) {
        switch count {
        case 0, 1: return (1, 1)
        case 2: return size.width >= size.height ? (2, 1) : (1, 2)
        default: return (2, 2)
        }
    }

    private var gap: CGFloat {
        #if os(tvOS)
        return 24
        #else
        return 4
        #endif
    }

    private var outerPadding: CGFloat {
        #if os(tvOS)
        return 48
        #else
        return 4
        #endif
    }

    @ViewBuilder
    private func cell(index: Int) -> some View {
        if index < model.tiles.count {
            tileView(model.tiles[index])
        } else if index == model.tiles.count && model.canAdd {
            addCell
        } else {
            Color.clear
        }
    }

    private func pickerTitle(_ target: MultiviewPickerTarget) -> String {
        switch target {
        case .add: return "Add Channel"
        case .replace: return "Replace Channel"
        }
    }

    // MARK: Tiles

    @ViewBuilder
    private func tileView(_ tile: MultiviewTile) -> some View {
        #if os(tvOS)
        Button {
            model.setAudio(tile.id)
        } label: {
            tileContent(tile)
        }
        .buttonStyle(MultiviewTileButtonStyle())
        .focused($focusedTile, equals: tile.id)
        .contextMenu { tileActions(tile) }
        #else
        tileContent(tile)
            .contentShape(Rectangle())
            .onTapGesture { model.setAudio(tile.id) }
            .onLongPressGesture(minimumDuration: 0.5) { expand(tile) }
            .overlay(alignment: .topTrailing) {
                Menu {
                    tileActions(tile)
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                        .padding(8)
                        .contentShape(Rectangle())
                }
            }
        #endif
    }

    @ViewBuilder
    private func tileActions(_ tile: MultiviewTile) -> some View {
        Button { expand(tile) } label: { Label("Watch Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") }
        Button { model.setAudio(tile.id) } label: { Label("Listen to This Channel", systemImage: "speaker.wave.2") }
        Button { picker = .replace(tile.id) } label: { Label("Replace Channel", systemImage: "arrow.triangle.2.circlepath") }
        Button(role: .destructive) { model.remove(tile.id) } label: { Label("Remove", systemImage: "xmark") }
    }

    private func tileContent(_ tile: MultiviewTile) -> some View {
        let audible = tile.id == model.audioTileID
        return ZStack(alignment: .bottomLeading) {
            Color.black
            MPVSurface(player: tile.player)
                .accessibilityHidden(true)
            if let error = tile.errorText {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.gold)
                    Text(error).font(.caption).multilineTextAlignment(.center).lineLimit(3)
                    Button("Retry") { tile.load() }.buttonStyle(.bordered).controlSize(.small)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tile.isBuffering {
                ProgressView().tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 8) {
                ChannelLogo(url: tile.channel.icon, name: tile.channel.name, size: labelLogoSize)
                Text(tile.channel.name).font(.caption.weight(.semibold)).lineLimit(1)
                Image(systemName: audible ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.caption)
                    .foregroundStyle(audible ? Theme.accent : .white.opacity(0.6))
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(audible ? Theme.accent : Color.white.opacity(0.12), lineWidth: audible ? 4 : 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tile.channel.name + (audible ? ", playing sound" : ", muted"))
    }

    private var labelLogoSize: CGFloat {
        #if os(tvOS)
        return 40
        #else
        return 24
        #endif
    }

    private var addCell: some View {
        Button { picker = .add } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus.rectangle.on.rectangle").font(.largeTitle)
                Text("Add Channel").font(.headline)
            }
            .foregroundStyle(.white.opacity(0.8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .foregroundStyle(.white.opacity(0.25))
            )
            .contentShape(Rectangle())
        }
        #if os(tvOS)
        .buttonStyle(MultiviewTileButtonStyle())
        #else
        .buttonStyle(.plain)
        #endif
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.split.2x2").font(.system(size: 48)).foregroundStyle(Theme.accentGradient)
            Text("Multiview").font(.title2.weight(.bold))
            Text("Watch up to \(model.maxTiles) live channels at once. The highlighted tile plays the sound.")
                .font(.subheadline).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
            Button { picker = .add } label: { Label("Add Channel", systemImage: "plus") }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
            Button("Close") { dismiss() }.buttonStyle(.bordered)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    #if os(iOS)
    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).frame(width: 40, height: 40)
                    .background(.black.opacity(0.55), in: Circle())
            }
            Spacer()
            if model.canAdd && !model.tiles.isEmpty {
                Button { picker = .add } label: {
                    Image(systemName: "plus").font(.headline).frame(width: 40, height: 40)
                        .background(.black.opacity(0.55), in: Circle())
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.top, 50)
    }
    #endif

    // MARK: Actions

    private func expand(_ tile: MultiviewTile) {
        let channel = tile.channel
        // The coordinator closes multiview (onDisappear shuts every mpv instance down) and opens the player.
        PlayerCoordinator.shared.expandFromMultiview(channel, list: [])
    }
}

/// No lift/scale effect: the grid draws its own audio highlight, and focus shows as a white outline.
struct MultiviewTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MultiviewTileButtonBody(configuration: configuration)
    }
}

private struct MultiviewTileButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(isFocused ? 0.9 : 0), lineWidth: 3)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// Searchable channel list (favorites first) used to add or replace a tile.
struct MultiviewChannelPicker: View {
    let title: String
    let exclude: Set<Int>
    let onPick: (XCChannel) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                let favs = favorites
                if !favs.isEmpty {
                    Section("Favorites") {
                        ForEach(favs) { row($0) }
                    }
                }
                Section(query.isEmpty ? "All Channels" : "Results") {
                    ForEach(others) { row($0) }
                }
            }
            .searchable(text: $query, prompt: "Search channels")
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private var all: [XCChannel] { DispatcharrStore.shared.channels }

    private func matches(_ ch: XCChannel) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        if let n = ch.number, String(n) == q { return true }
        return ch.name.localizedCaseInsensitiveContains(q)
    }

    private var favorites: [XCChannel] {
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return LibraryStore.shared.favoriteChannelIDs.compactMap { byID[$0] }.filter { matches($0) }
    }

    private var others: [XCChannel] {
        let fav = Set(LibraryStore.shared.favoriteChannelIDs)
        return all.filter { !fav.contains($0.id) && matches($0) }
    }

    private func row(_ ch: XCChannel) -> some View {
        let taken = exclude.contains(ch.id)
        return Button {
            onPick(ch)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                if let n = ch.number {
                    Text("\(n)").font(.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText).frame(width: 40)
                }
                ChannelLogo(url: ch.icon, name: ch.name, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ch.name).lineLimit(1)
                    if let now = DispatcharrStore.shared.nowPlaying(ch.id) {
                        Text(now.title).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                }
                Spacer()
                if taken { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }
        }
        .disabled(taken)
    }
}
