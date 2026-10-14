import SwiftUI

/// Top bar, centre buttons, bottom bar, timelines and button helpers.
extension PlayerScreen {
    var controls: some View {
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

    // MARK: Top bar

    var topBar: some View {
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
                if let t = model.torrentStatus { torrentChip(t) }
            }
            Spacer()
            #if os(iOS)
            HStack(spacing: 2) {
                RoutePickerButton()
                    .frame(width: 40, height: 44)
                    .accessibilityLabel("AirPlay audio")
                compactButton("airplayvideo") { airPlayTapped(); scheduleHide() }
                    .opacity(model.isAirPlayCompatible ? 1 : 0.45)
                    .accessibilityLabel("Play on AirPlay device")
                if PiPController.isSupported {
                    compactButton(model.pip.isActive ? "pip.exit" : "pip.enter") {
                        model.togglePictureInPicture()
                        scheduleHide()
                    }
                    .opacity(model.hasStarted ? 1 : 0.45)
                    .accessibilityLabel("Picture in Picture")
                }
                compactButton("chart.bar.xaxis") { model.showStats.toggle() }
                    .accessibilityLabel("Statistics")
            }
            #endif
        }
    }

    func torrentChip(_ t: TorrentStatus) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "person.2.fill")
            Text("\(t.activePeers)")
            Image(systemName: "arrow.down")
            Text(t.speedText)
            if let pct = model.torrentBufferPercent {
                Image(systemName: "internaldrive")
                Text("\(pct)%")
            }
        }
        .font(.caption2.monospacedDigit().weight(.semibold))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.black.opacity(0.45), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(t.activePeers) peers, \(t.speedText)")
    }

    // MARK: Centre

    var centerButtons: some View {
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

    var centerSpacing: CGFloat {
        #if os(tvOS)
        return 90
        #else
        return 54
        #endif
    }

    // MARK: Bottom bar

    var bottomBar: some View {
        VStack(spacing: 10) {
            if model.isLive {
                if model.timeshiftActive && model.liveWindow > 2 {
                    timeshiftBar
                }
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
                    toolbarButton("textformat.123", "Number") { openNumberPad() }
                    if model.previousChannelID != nil {
                        toolbarButton("arrow.uturn.backward", "Last Channel") { model.toggleLastChannel() }
                    }
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

    // MARK: VOD timeline

    @ViewBuilder
    var timeline: some View {
        let shown = scrubbing ?? model.position
        let total = max(model.duration, 1)
        VStack(spacing: 6) {
            #if os(iOS)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2)).frame(height: 5)
                    Capsule().fill(.white.opacity(0.35)).frame(width: geo.size.width * min(1, model.cachedUntil / total), height: 5)
                    ForEach(model.skipSegments) { seg in
                        Capsule().fill(Theme.gold.opacity(0.55))
                            .frame(width: max(2, geo.size.width * (seg.end - seg.start) / total), height: 5)
                            .offset(x: geo.size.width * seg.start / total)
                    }
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

    func chapterTitle(at t: Double) -> String? {
        model.chapters.last { $0.time <= t }?.title
    }

    // MARK: Live timeshift bar

    @ViewBuilder
    var timeshiftBar: some View {
        let start = model.liveRangeStart
        let edge = model.liveEdge
        let span = max(1, edge - start)
        let shown = liveScrubbing ?? model.position
        let fraction = max(0, min(1, (shown - start) / span))
        let behind = max(0, edge - shown)
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                toolbarButton("gobackward.30", "Back 30 seconds") { seek(-30) }
                #if os(iOS)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25)).frame(height: 5)
                        Capsule().fill(Theme.live).frame(width: geo.size.width * fraction, height: 5)
                        Circle().fill(.white).frame(width: liveScrubbing == nil ? 14 : 22, height: liveScrubbing == nil ? 14 : 22)
                            .offset(x: geo.size.width * fraction - (liveScrubbing == nil ? 7 : 11))
                    }
                    .frame(height: 24)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            hideTask?.cancel()
                            let f = max(0, min(1, Double(v.location.x / max(1, geo.size.width))))
                            liveScrubbing = start + f * span
                        }
                        .onEnded { _ in
                            if let s = liveScrubbing { model.seek(to: s) }
                            liveScrubbing = nil
                            scheduleHide()
                        })
                }
                .frame(height: 24)
                #else
                ZStack(alignment: .leading) {
                    ProgressLine(fraction: fraction, height: 8)
                }
                #endif
                if behind > 3 {
                    toolbarButton("goforward.30", "Forward 30 seconds") { seek(30) }
                }
            }
            HStack {
                Text("Buffer " + model.liveWindow.clockText)
                Spacer()
                if behind > 3 {
                    Text("−\(behind.clockText) behind live")
                } else if model.isPaused {
                    Text("Paused")
                }
                Spacer()
                if behind > 3 {
                    Button {
                        model.goLive()
                        scheduleHide()
                    } label: {
                        Label("Go Live", systemImage: "forward.end.fill")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.live)
                } else {
                    LiveBadge()
                }
            }
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.white.opacity(0.85))
        }
    }

    // MARK: Button helpers

    func controlButton(_ symbol: String, size: Font = .title3, action: @escaping () -> Void) -> some View {
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

    /// Smaller icon button for the crowded iPhone top bar.
    func compactButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    func toolbarButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
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
}
