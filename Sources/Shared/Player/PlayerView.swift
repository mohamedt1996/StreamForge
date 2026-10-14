import SwiftUI

/// Hosts the mpv render view.
struct MPVSurface: UIViewRepresentable {
    let player: MPVPlayer
    func makeUIView(context: Context) -> MPVVideoView { player.view }
    func updateUIView(_ uiView: MPVVideoView, context: Context) {}
}

enum PlayerPanel: Identifiable {
    case audio, subtitles, settings, channels, chapters
    var id: Self { self }
}

struct PlayerView: View {
    let request: PlaybackRequest
    @Environment(\.dismiss) private var dismiss
    @State private var model: PlayerModel
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var panel: PlayerPanel?
    @State private var scrubbing: Double?
    @State private var seekFeedback: String?
    @State private var numberEntry = ""

    init(request: PlaybackRequest) {
        self.request = request
        _model = State(initialValue: PlayerModel(request: request))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MPVSurface(player: model.player)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            if model.isBuffering || !model.hasStarted { bufferingOverlay }
            if let error = model.errorText { errorOverlay(error) }

            gestureLayer

            if controlsVisible && model.errorText == nil { controls.transition(.opacity) }
            if let seekFeedback { feedbackBubble(seekFeedback) }
            if model.showNextEpisodeCard, let next = model.nextEpisode { nextEpisodeCard(next) }
            if model.showStats { statsOverlay }
            if let panel { panelView(panel).transition(.move(edge: .trailing).combined(with: .opacity)) }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .animation(.easeInOut(duration: 0.25), value: panel)
        .preferredColorScheme(.dark)
        #if os(iOS)
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(.hidden)
        #endif
        .onAppear {
            model.start()
            scheduleHide()
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = true
            #endif
        }
        .onDisappear {
            model.stop()
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
        }
        #if os(tvOS)
        .focusable(!controlsVisible && panel == nil)
        .onTapGesture { if !controlsVisible { showControls() } }
        .onPlayPauseCommand { model.togglePause(); showControls() }
        .onExitCommand {
            if panel != nil { panel = nil } else if controlsVisible && model.hasStarted { controlsVisible = false } else { close() }
        }
        .onMoveCommand { direction in
            guard panel == nil else { return }
            if controlsVisible { scheduleHide(); return }
            switch direction {
            case .left: seek(-Double(AppSettings.shared.values.seekStep))
            case .right: seek(Double(AppSettings.shared.values.seekStep))
            case .up: if model.isLive { model.zap(-1); flash("Channel ▲") } else { showControls() }
            case .down: if model.isLive { panel = .channels } else { showControls() }
            @unknown default: break
            }
        }
        #endif
    }

    private func close() {
        dismiss()
    }

    // MARK: Gestures

    @ViewBuilder
    private var gestureLayer: some View {
        #if os(iOS)
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture(count: 2).onEnded { value in
                        guard !model.isLive || model.request.catchup != nil else { return }
                        let step = Double(AppSettings.shared.values.seekStep)
                        if value.location.x < geo.size.width / 3 { seek(-step) }
                        else if value.location.x > geo.size.width * 2 / 3 { seek(step) }
                        else { model.togglePause() }
                    }
                    .exclusively(before: TapGesture().onEnded { toggleControls() })
                )
                .simultaneousGesture(MagnifyGesture().onEnded { v in
                    model.setFit(v.magnification > 1 ? .fill : .fit)
                    flash(model.fit.label)
                })
                .simultaneousGesture(DragGesture(minimumDistance: 40).onEnded { v in
                    guard model.isLive, abs(v.translation.width) > abs(v.translation.height) else { return }
                    model.zap(v.translation.width < 0 ? 1 : -1)
                    flash(v.translation.width < 0 ? "Next channel" : "Previous channel")
                })
        }
        .ignoresSafeArea()
        #else
        Color.clear
        #endif
    }

    private func toggleControls() {
        if panel != nil { panel = nil; return }
        controlsVisible.toggle()
        if controlsVisible { scheduleHide() }
    }

    private func showControls() {
        controlsVisible = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled, !model.isPaused, scrubbing == nil, panel == nil else { return }
            controlsVisible = false
        }
    }

    private func seek(_ delta: Double) {
        model.seek(by: delta)
        flash(delta < 0 ? "−\(Int(-delta))s" : "+\(Int(delta))s")
    }

    private func flash(_ text: String) {
        seekFeedback = text
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if seekFeedback == text { seekFeedback = nil }
        }
    }

    // MARK: Overlays

    private var bufferingOverlay: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large).tint(.white)
            if let status = model.statusText {
                Text(status).font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.8))
            } else if let pct = model.bufferPercent, pct > 0, pct < 100 {
                Text("Buffering \(pct)%").font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(24)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
        .allowsHitTesting(false)
    }

    private func errorOverlay(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 42)).foregroundStyle(Theme.gold)
            Text("Can't play this").font(.title3.weight(.bold))
            Text(error).font(.subheadline).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center).frame(maxWidth: 520)
            HStack(spacing: 14) {
                Button("Close") { close() }.buttonStyle(.bordered)
                Button("Try Again") { model.retry() }.buttonStyle(.borderedProminent).tint(Theme.accent)
                if model.isLive {
                    Button("Next Channel") { model.zap(1) }.buttonStyle(.bordered)
                }
            }
        }
        .padding(30)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding()
    }

    private func feedbackBubble(_ text: String) -> some View {
        Text(text)
            .font(.title3.weight(.bold))
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .allowsHitTesting(false)
    }

    // MARK: Controls

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.75), .clear, .clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                topBar
                Spacer()
                centerButtons
                Spacer()
                bottomBar
            }
            .padding(.horizontal, edgePadding)
            .padding(.vertical, 12)
        }
    }

    private var edgePadding: CGFloat {
        #if os(tvOS)
        return 80
        #else
        return 18
        #endif
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 14) {
            #if os(iOS)
            controlButton("xmark") { close() }
            #endif
            if model.isLive, let ch = model.currentChannel {
                ChannelLogo(url: ch.icon, name: ch.name, size: 44)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(model.isLive ? (model.currentChannel?.name ?? model.title) : model.title)
                        .font(.headline).lineLimit(1)
                    if model.isLive { LiveBadge() }
                    if model.isHDR { Pill(text: "HDR", color: Theme.gold.opacity(0.85), foreground: .black) }
                }
                if let sub = model.subtitle {
                    Text(sub).font(.subheadline).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
                if model.isLive, let next = model.nextProgramme {
                    Text("Next · \(next.start.formatted(date: .omitted, time: .shortened)) \(next.title)")
                        .font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
            }
            Spacer()
            #if os(iOS)
            controlButton("chart.bar.xaxis") { model.showStats.toggle() }
            #endif
        }
    }

    private var centerButtons: some View {
        HStack(spacing: centerSpacing) {
            if model.isLive {
                controlButton("chevron.up", size: .title) { model.zap(-1); scheduleHide() }
            } else {
                controlButton("gobackward.\(AppSettings.shared.values.seekStep)", size: .title) { seek(-Double(AppSettings.shared.values.seekStep)); scheduleHide() }
            }
            controlButton(model.isPaused || model.ended ? "play.fill" : "pause.fill", size: .largeTitle) {
                model.togglePause(); scheduleHide()
            }
            .opacity(model.hasStarted ? 1 : 0.4)
            if model.isLive {
                controlButton("chevron.down", size: .title) { model.zap(1); scheduleHide() }
            } else {
                controlButton("goforward.\(AppSettings.shared.values.seekStep)", size: .title) { seek(Double(AppSettings.shared.values.seekStep)); scheduleHide() }
            }
        }
    }

    private var centerSpacing: CGFloat {
        #if os(tvOS)
        return 90
        #else
        return 54
        #endif
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if model.isLive {
                if let p = model.currentProgramme {
                    HStack(spacing: 10) {
                        Text(p.start.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit())
                        ProgressLine(fraction: p.progress, height: 4)
                        Text(p.end.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit())
                    }
                }
            } else {
                timeline
            }
            HStack(spacing: 18) {
                if model.isLive {
                    toolbarButton("list.bullet", "Channels") { panel = .channels }
                }
                toolbarButton("speaker.wave.2", "Audio") { panel = .audio }
                toolbarButton("captions.bubble", "Subtitles") { panel = .subtitles }
                if model.chapters.count > 1 {
                    toolbarButton("list.number", "Chapters") { panel = .chapters }
                }
                Spacer()
                toolbarButton(model.fit.icon, model.fit.label) { model.cycleFit(); flash(model.fit.label) }
                toolbarButton("slider.horizontal.3", "Settings") { panel = .settings }
                #if os(tvOS)
                toolbarButton("chart.bar.xaxis", "Stats") { model.showStats.toggle() }
                #endif
            }
        }
    }

    @ViewBuilder
    private var timeline: some View {
        let shown = scrubbing ?? model.position
        let total = max(model.duration, 1)
        VStack(spacing: 6) {
            #if os(iOS)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2)).frame(height: 5)
                    Capsule().fill(.white.opacity(0.35)).frame(width: geo.size.width * min(1, model.cachedUntil / total), height: 5)
                    Capsule().fill(Theme.accentGradient).frame(width: geo.size.width * min(1, shown / total), height: 5)
                    ForEach(model.chapters, id: \.time) { c in
                        Rectangle().fill(.black.opacity(0.6)).frame(width: 2, height: 5).offset(x: geo.size.width * c.time / total)
                    }
                    Circle().fill(.white).frame(width: scrubbing == nil ? 14 : 22, height: scrubbing == nil ? 14 : 22)
                        .offset(x: geo.size.width * min(1, shown / total) - (scrubbing == nil ? 7 : 11))
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        hideTask?.cancel()
                        scrubbing = max(0, min(total, Double(v.location.x / geo.size.width) * total))
                    }
                    .onEnded { _ in
                        if let s = scrubbing { model.seek(to: s) }
                        scrubbing = nil
                        scheduleHide()
                    })
            }
            .frame(height: 24)
            #else
            ProgressLine(fraction: shown / total, height: 8)
            #endif
            HStack {
                Text(shown.clockText)
                Spacer()
                if let s = scrubbing { Text(chapterTitle(at: s) ?? "").lineLimit(1) }
                Spacer()
                Text("-" + max(0, model.duration - shown).clockText)
            }
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.white.opacity(0.85))
        }
    }

    private func chapterTitle(at t: Double) -> String? {
        model.chapters.last { $0.time <= t }?.title
    }

    private func controlButton(_ symbol: String, size: Font = .title3, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(size.weight(.semibold))
                .frame(width: 54, height: 54)
                .contentShape(Rectangle())
        }
        #if os(tvOS)
        .buttonStyle(.plain)
        #else
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        #endif
    }

    private func toolbarButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            scheduleHide()
        } label: {
            #if os(tvOS)
            Label(label, systemImage: symbol).font(.callout.weight(.semibold))
            #else
            Image(systemName: symbol).font(.title3).frame(width: 36, height: 36)
            #endif
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(label)
    }

    // MARK: Next episode

    private func nextEpisodeCard(_ next: EpisodeRef) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 12) {
                    RemoteImage(url: next.still ?? request.item.backdrop)
                        .frame(width: 120, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Up next in \(Int(model.remaining))s").font(.caption).foregroundStyle(.white.opacity(0.7))
                        Text("\(next.code) · \(next.title)").font(.subheadline.weight(.semibold)).lineLimit(2)
                        Button("Play Now") { model.playNextEpisode() }
                            .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
                    }
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .padding(.horizontal, edgePadding)
        .padding(.bottom, controlsVisible ? 130 : 30)
    }

    // MARK: Stats

    private var statsOverlay: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.stats, id: \.0) { row in
                        HStack(spacing: 8) {
                            Text(row.0).foregroundStyle(.white.opacity(0.6)).frame(width: 110, alignment: .leading)
                            Text(row.1)
                        }
                    }
                    if model.stats.isEmpty { Text("Collecting…") }
                }
                .font(.caption.monospaced())
                .padding(12)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                Spacer()
            }
            Spacer()
        }
        .padding(.top, 80)
        .padding(.horizontal, edgePadding)
        .allowsHitTesting(false)
    }

    // MARK: Panels

    @ViewBuilder
    private func panelView(_ panel: PlayerPanel) -> some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(panelTitle(panel)).font(.headline)
                    Spacer()
                    Button { self.panel = nil } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                        .buttonStyle(.plain)
                }
                .padding(16)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        switch panel {
                        case .audio: audioPanel
                        case .subtitles: subtitlePanel
                        case .settings: settingsPanel
                        case .channels: channelPanel
                        case .chapters: chapterPanel
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 20)
                }
            }
            .frame(width: panelWidth)
            .frame(maxHeight: .infinity)
            .background(.ultraThinMaterial)
        }
        .ignoresSafeArea()
    }

    private var panelWidth: CGFloat {
        #if os(tvOS)
        return 640
        #else
        return min(380, UIScreen.main.bounds.width * 0.9)
        #endif
    }

    private func panelTitle(_ p: PlayerPanel) -> String {
        switch p {
        case .audio: return "Audio"
        case .subtitles: return "Subtitles"
        case .settings: return "Playback"
        case .channels: return "Channels"
        case .chapters: return "Chapters"
        }
    }

    private func optionRow(_ title: String, subtitle: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(selected ? .bold : .regular)).multilineTextAlignment(.leading)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.6)) }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }
            .padding(.vertical, 10).padding(.horizontal, 10)
            .background(selected ? Theme.surfaceHigh : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var audioPanel: some View {
        if model.audioTracks.isEmpty { Text("No audio tracks").foregroundStyle(.secondary).padding() }
        ForEach(model.audioTracks) { t in
            optionRow(t.displayName, selected: t.isSelected) { model.selectAudio(t) }
        }
        sectionLabel("Audio delay")
        stepperRow(value: model.audioDelay, unit: "s", step: 0.1) { model.audioDelay = $0 }
        if model.videoTracks.count > 1 {
            sectionLabel("Video")
            ForEach(model.videoTracks) { t in optionRow(t.displayName, selected: t.isSelected) { model.selectVideo(t) } }
        }
    }

    @ViewBuilder private var subtitlePanel: some View {
        optionRow("Off", selected: !model.subtitleTracks.contains { $0.isSelected }) { model.selectSubtitle(nil) }
        ForEach(model.subtitleTracks) { t in
            optionRow(t.displayName, selected: t.isSelected) { model.selectSubtitle(t) }
        }
        if !model.addonSubtitles.isEmpty {
            sectionLabel("From addons")
            ForEach(model.addonSubtitles.prefix(60)) { s in
                optionRow(s.languageName, subtitle: model.loadedAddonSubtitleIDs.contains(s.id) ? "Loaded" : s.url.host,
                          selected: false) { model.loadAddonSubtitle(s) }
            }
        }
        sectionLabel("Timing")
        stepperRow(value: model.subtitleDelay, unit: "s", step: 0.25) { model.subtitleDelay = $0 }
        sectionLabel("Size")
        stepperRow(value: model.subtitleScale, unit: "×", step: 0.1) { model.subtitleScale = max(0.4, min(3, $0)) }
    }

    @ViewBuilder private var settingsPanel: some View {
        sectionLabel("Speed")
        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { s in
            optionRow(s == 1 ? "Normal" : String(format: "%.2g×", s), selected: abs(model.speed - s) < 0.01) { model.setSpeed(s) }
        }
        .disabled(model.isLive)
        sectionLabel("Video")
        ForEach(VideoFit.allCases, id: \.self) { f in
            optionRow(f.label, selected: model.fit == f) { model.setFit(f) }
        }
        sectionLabel("Info")
        optionRow("Show statistics", selected: model.showStats) { model.showStats.toggle() }
        optionRow("Source: \(request.source.provider)", subtitle: request.source.title, selected: false) {}
    }

    @ViewBuilder private var channelPanel: some View {
        let list = model.request.channelList
        ForEach(list) { ch in
            Button {
                model.switchChannel(ch)
                panel = nil
            } label: {
                HStack(spacing: 10) {
                    if let n = ch.number { Text("\(n)").font(.caption.monospacedDigit()).frame(width: 34) }
                    ChannelLogo(url: ch.icon, name: ch.name, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ch.name).font(.subheadline.weight(ch.id == model.request.channelID ? .bold : .regular)).lineLimit(1)
                        if let now = DispatcharrStore.shared.nowPlaying(ch.id) {
                            Text(now.title).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                    }
                    Spacer()
                    if ch.id == model.request.channelID { Image(systemName: "speaker.wave.2.fill").foregroundStyle(Theme.accent) }
                }
                .padding(8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var chapterPanel: some View {
        ForEach(Array(model.chapters.enumerated()), id: \.offset) { _, c in
            optionRow(c.title, subtitle: c.time.clockText, selected: chapterTitle(at: model.position) == c.title && (model.chapters.last { $0.time <= model.position }?.time == c.time)) {
                model.jumpToChapter(c)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.5))
            .padding(.top, 14).padding(.horizontal, 10)
    }

    private func stepperRow(value: Double, unit: String, step: Double, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Button { set(value - step) } label: { Image(systemName: "minus.circle.fill").font(.title2) }.buttonStyle(.plain)
            Spacer()
            Text(String(format: "%+.2f%@", value, unit)).font(.body.monospacedDigit())
            Spacer()
            Button { set(value + step) } label: { Image(systemName: "plus.circle.fill").font(.title2) }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }
}
