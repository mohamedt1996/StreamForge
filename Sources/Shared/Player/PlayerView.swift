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

/// Creates the player model exactly once. SwiftUI may call `init` many times while the
/// cover is up, and each PlayerModel owns a full mpv instance, so it must not live in `init`.
struct PlayerView: View {
    let request: PlaybackRequest
    @State private var model: PlayerModel?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let model { PlayerScreen(request: request, model: model) }
        }
        .onAppear {
            if model == nil { model = PlayerModel(request: request) }
        }
    }
}

/// The player UI. Split across files: controls (PlayerControls.swift), side panels
/// (PlayerPanels.swift) and overlays (PlayerOverlays.swift).
struct PlayerScreen: View {
    let request: PlaybackRequest
    let model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @State var controlsVisible = true
    @State var hideTask: Task<Void, Never>?
    @State var panel: PlayerPanel?
    @State var scrubbing: Double?
    @State var liveScrubbing: Double?
    @State var seekFeedback: String?
    @State var showNumberPad = false
    #if os(iOS)
    @State private var airPlayHandoff: AirPlayHandoffRequest?
    @State private var airPlayExplanation: String?
    @FocusState private var keyboardFocused: Bool
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            #if os(iOS)
            if PiPController.isSupported {
                // PiP source layers live behind the mpv surface (AVKit needs them in the window).
                PiPHostSurface(controller: model.pip)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
            #endif
            MPVSurface(player: model.player)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            if !model.hasStarted && !model.isLive && model.errorText == nil {
                LoadingArtworkView(request: model.request, status: model.statusText ?? model.bufferPercent.flatMap { $0 > 0 && $0 < 100 ? "Buffering \($0)%" : nil })
                    .transition(.opacity)
            } else if model.isBuffering || !model.hasStarted { bufferingOverlay }
            if let error = model.errorText { errorOverlay(error) }

            gestureLayer

            if controlsVisible && model.errorText == nil { controls.transition(.opacity) }
            if let seekFeedback {
                feedbackBubble(seekFeedback)
            } else if let toast = model.toast {
                feedbackBubble(toast)
            }
            if let segment = model.activeSkip, model.errorText == nil, panel == nil, !showNumberPad {
                skipButton(segment)
            }
            if model.showNextEpisodeCard, let next = model.nextEpisode { nextEpisodeCard(next) }
            if model.showStats { statsOverlay }
            if !model.channelDigits.isEmpty && !showNumberPad { channelEntryBadge }
            if showNumberPad { numberPadOverlay.transition(.opacity) }
            if let panel { panelView(panel).transition(.move(edge: .trailing).combined(with: .opacity)) }
            #if os(iOS)
            // An overlay, not a fullScreenCover: a cover would fire this screen's onDisappear and stop mpv.
            if let handoff = airPlayHandoff {
                AirPlayHandoffView(request: handoff) { position, playing in
                    airPlayHandoff = nil
                    model.resumeAfterHandoff(at: position, play: playing)
                }
                .transition(.opacity)
                .zIndex(10)
            }
            #endif
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .animation(.easeInOut(duration: 0.25), value: panel)
        .animation(.easeInOut(duration: 0.2), value: showNumberPad)
        .preferredColorScheme(.dark)
        .onChange(of: PlayerPreferences.shared.values) { model.applyPreferences() }
        .onChange(of: model.request.channelID) { showNumberPad = false }
        #if os(iOS)
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(.hidden)
        // Hardware keyboards (iPad): number keys tune channels.
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocused)
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in handleDigitKey(press.characters) }
        .alert("AirPlay", isPresented: Binding(get: { airPlayExplanation != nil }, set: { if !$0 { airPlayExplanation = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(airPlayExplanation ?? "")
        }
        #endif
        .onAppear {
            model.start()
            scheduleHide()
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = true
            keyboardFocused = true
            if UIDevice.current.userInterfaceIdiom == .phone {
                AppDelegate.setOrientation(.landscape, rotateTo: .landscape)
            }
            #endif
        }
        .onDisappear {
            model.stop()
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false
            if UIDevice.current.userInterfaceIdiom == .phone {
                AppDelegate.setOrientation(.all, rotateTo: .portrait)
            }
            #endif
        }
        #if os(tvOS)
        .focusable(rootFocusable)
        .onTapGesture { if !controlsVisible { showControls() } }
        .onLongPressGesture(minimumDuration: 0.6) { if model.isLive { openNumberPad() } }
        .onPlayPauseCommand { model.togglePause(); showControls() }
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in handleDigitKey(press.characters) }
        .onExitCommand {
            if showNumberPad { showNumberPad = false; model.cancelDigits() }
            else if !model.channelDigits.isEmpty { model.cancelDigits() }
            else if panel != nil { panel = nil }
            else if controlsVisible && model.hasStarted { controlsVisible = false }
            else { close() }
        }
        .onMoveCommand { direction in
            guard panel == nil, !showNumberPad else { return }
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

    #if os(tvOS)
    /// The root takes focus only when nothing else should: hidden controls, no panel/pad, no skip button
    /// (so the Skip button gets focus and a click skips).
    private var rootFocusable: Bool {
        !controlsVisible && panel == nil && !showNumberPad && model.activeSkip == nil
    }
    #endif

    func close() {
        dismiss()
    }

    private func handleDigitKey(_ characters: String) -> KeyPress.Result {
        guard model.isLive, characters.count == 1, let digit = Int(characters) else { return .ignored }
        model.enterDigit(digit)
        return .handled
    }

    func openNumberPad() {
        panel = nil
        controlsVisible = false
        showNumberPad = true
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
                        guard model.canSeek else { return }
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

    func toggleControls() {
        if showNumberPad { showNumberPad = false; return }
        if panel != nil { panel = nil; return }
        controlsVisible.toggle()
        if controlsVisible { scheduleHide() }
    }

    func showControls() {
        controlsVisible = true
        scheduleHide()
    }

    func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled, !model.isPaused, scrubbing == nil, liveScrubbing == nil, panel == nil else { return }
            controlsVisible = false
        }
    }

    func seek(_ delta: Double) {
        guard model.canSeek else { return }
        model.seek(by: delta)
        flash(delta < 0 ? "−\(Int(-delta))s" : "+\(Int(delta))s")
    }

    func flash(_ text: String) {
        seekFeedback = text
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if seekFeedback == text { seekFeedback = nil }
        }
    }

    #if os(iOS)
    func airPlayTapped() {
        guard let url = model.resolvedURL, model.isAirPlayCompatible else {
            airPlayExplanation = AVPlaybackCompatibility.airPlayExplanation(for: model.resolvedURL)
            return
        }
        let req = AirPlayHandoffRequest(url: url, headers: model.resolvedHeaders, start: model.isLive ? 0 : model.position, title: model.title)
        model.pauseForHandoff()
        airPlayHandoff = req
    }
    #endif

    var edgePadding: CGFloat {
        #if os(tvOS)
        return 80
        #else
        return 18
        #endif
    }
}
