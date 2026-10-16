import SwiftUI
import AVFoundation
import UIKit
#if os(iOS)
import WebKit
#endif

// Netflix-style hero trailers.
//
// The hero shows its backdrop first; after `TrailerPolicy.startDelay` (if autoplay is allowed
// and the hero is on screen) a muted trailer fades in over it, edge to edge with no player
// chrome. It pauses whenever the host says it isn't active (scrolled away, app in background,
// a player or sheet on top, page left) and resumes when it is again. When it ends it fades
// back to the artwork and offers a replay button (iOS). Unmuting lasts for the session.
//
// Trailers are YouTube only (every failure is silent and moves on to the next):
//   1. The user's optional Invidious instance, which plays the YouTube trailer natively.
//   2. iOS: the YouTube embed, trying each trailer id in turn.
// tvOS has no WebKit, so it uses Invidious only.

// MARK: - Policy

@MainActor
enum TrailerPolicy {
    /// Setting on, not on cellular / Low Data Mode, not a kids profile.
    static var allowsAutoplay: Bool {
        AppSettings.shared.values.trailerAutoplay && NetworkStatus.shared.allowsAutoplayMedia && !ProfileStore.shared.isKidsMode
    }
    /// Backdrop-only time before the trailer starts.
    nonisolated static let startDelay: TimeInterval = 2.5
    /// Crossfade between artwork and video.
    nonisolated static let fade: Double = 0.5
    /// Title / meta changes that accompany the crossfade: quick, so the header never feels laggy.
    nonisolated static var titleAnimation: Animation { .spring(response: 0.32, dampingFraction: 0.9) }
    /// Give up on a source that hasn't produced frames after this much (on-screen) time.
    nonisolated static let loadTimeout: TimeInterval = 15
    /// Unmuting sticks for the rest of the session (never persisted: a relaunch starts silent).
    static var sessionPrefersSound = false
}

/// Muted trailers must not stop the user's music or podcast; sound only when they unmute.
@MainActor
enum TrailerAudio {
    static func prepare(muted: Bool) {
        // The main player owns the session while it is up (trailers are paused then anyway).
        guard PlayerCoordinator.shared.current == nil, PlayerCoordinator.shared.multiview == nil else { return }
        let session = AVAudioSession.sharedInstance()
        if muted {
            try? session.setCategory(.ambient, mode: .default, options: [])
        } else {
            try? session.setCategory(.playback, mode: .moviePlayback)
            try? session.setActive(true)
        }
    }
}

// MARK: - Invidious

/// Looks up a direct MP4 stream for a YouTube trailer on a user-chosen Invidious instance
/// (`GET /api/v1/videos/{id}`), proxied through the instance (`local=true`) so it plays anywhere.
enum InvidiousTrailer {
    private struct Video: Decodable {
        struct Format: Decodable {
            var url: String?
            var container: String?
            var resolution: String?
            var type: String?
        }
        var formatStreams: [Format]?
    }

    static func streamURL(instance: String, youtubeKey: String) async -> URL? {
        guard let base = URL.normalizedBase(instance) else { return nil }
        let key = youtubeKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? youtubeKey
        let url = base.appendingRawPath("api/v1/videos/\(key)").appendingQuery(["local": "true"])
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let result = try? await URLSession.shared.data(for: req),
              let http = result.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let video = try? JSONDecoder().decode(Video.self, from: result.0) else { return nil }
        func height(_ f: Video.Format) -> Int { Int((f.resolution ?? "").filter(\.isNumber)) ?? 0 }
        let mp4 = (video.formatStreams ?? []).filter {
            $0.url != nil && (($0.container ?? "").lowercased() == "mp4" || ($0.type ?? "").lowercased().contains("mp4"))
        }
        // Muxed (audio + video) streams only, so unmuting works; best resolution up to 1080p.
        guard let best = mp4.filter({ height($0) <= 1080 }).max(by: { height($0) < height($1) }) ?? mp4.first,
              let raw = best.url else { return nil }
        return URL(string: raw, relativeTo: base)?.absoluteURL
    }
}

// MARK: - Controller

@MainActor
@Observable
final class TrailerController {
    enum Phase: Equatable {
        /// Showing the artwork (waiting for the delay, or nothing to play yet).
        case idle
        /// A source is warming up behind the artwork.
        case loading
        /// The video covers the artwork (possibly paused while the hero is inactive).
        case playing
        /// Finished and faded back to the artwork; can be replayed.
        case ended
        /// Every source failed: stay on the artwork quietly.
        case unavailable
    }

    private(set) var phase: Phase = .idle
    private(set) var isMuted = true
    private(set) var player: AVPlayer?
    /// The iOS web player's view (kept platform-neutral so observation always tracks it).
    private(set) var webView: UIView?

    /// True while the video should be visible over the artwork.
    var isRevealed: Bool { phase == .playing }

    private enum Candidate {
        case invidious(key: String, instance: String)
        #if os(iOS)
        case web(keys: [String])
        #endif
    }

    #if os(iOS)
    @ObservationIgnored private var web: TrailerWebPlayer?
    #endif
    @ObservationIgnored private var sources: [TrailerSource] = []
    @ObservationIgnored private var sourceGeneration = 0
    @ObservationIgnored private var active = false
    @ObservationIgnored private var candidates: [Candidate] = []
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    /// On-screen time spent loading the current source.
    @ObservationIgnored private var loadingTime: TimeInterval = 0
    /// iOS web source: when YouTube reported "playing" (revealed a moment later, after its overlay fades).
    @ObservationIgnored private var webPlayingSince: Date?
    /// Bumped on every reset so late callbacks from an old source are ignored.
    @ObservationIgnored private var generation = 0

    init() {}

    // MARK: Host API

    /// Trailer ids for the current title, best first. New ids reset everything; the trailer
    /// starts `delay` seconds later if the hero is active by then.
    func setKeys(_ newKeys: [String], delay: TimeInterval = TrailerPolicy.startDelay) {
        setSources(newKeys.compactMap(TrailerSource.parse), delay: delay)
    }

    func setSources(_ newSources: [TrailerSource], delay: TimeInterval = TrailerPolicy.startDelay) {
        let cleaned = TrailerSource.ordered(newSources)
        guard cleaned != sources else { return }
        reset()
        sources = cleaned
        scheduleStart(after: delay)
    }

    func playManually() {
        active = true
        guard !sources.isEmpty else { phase = .unavailable; return }
        if phase == .ended { replay(); return }
        startTask?.cancel(); startTask = nil
        if phase == .idle || phase == .unavailable { begin() } else { resumePlayback() }
    }

    /// Whether the hero is on screen and uncovered (and autoplay is allowed). Pauses/resumes.
    func setActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        if value {
            switch phase {
            case .idle: scheduleStart(after: TrailerPolicy.startDelay)
            case .loading, .playing: resumePlayback()
            case .ended, .unavailable: break
            }
        } else {
            startTask?.cancel()
            startTask = nil
            pausePlayback()
        }
    }

    func toggleMute() {
        isMuted.toggle()
        TrailerPolicy.sessionPrefersSound = !isMuted
        TrailerAudio.prepare(muted: isMuted)
        player?.isMuted = isMuted
        #if os(iOS)
        web?.setMuted(isMuted)
        #endif
    }

    func replay() {
        guard phase == .ended else { return }
        isMuted = !TrailerPolicy.sessionPrefersSound
        loadingTime = 0
        webPlayingSince = nil
        if let player {
            player.isMuted = isMuted
            player.seek(to: .zero)
            phase = .loading
            if active { TrailerAudio.prepare(muted: isMuted); player.play() }
            startMonitor()
            return
        }
        #if os(iOS)
        if let web {
            web.setMuted(isMuted)
            phase = .loading
            web.replay()
            if !active { web.pause() } else { TrailerAudio.prepare(muted: isMuted) }
            startMonitor()
            return
        }
        #endif
        phase = .idle
        scheduleStart(after: 0)
    }

    /// Drops any player and returns to the artwork.
    func reset() {
        generation += 1
        startTask?.cancel(); startTask = nil
        resolveTask?.cancel(); resolveTask = nil
        monitorTask?.cancel(); monitorTask = nil
        candidates = []
        dropSources()
        loadingTime = 0
        webPlayingSince = nil
        sources = []
        phase = .idle
    }

    // MARK: Start

    private func scheduleStart(after delay: TimeInterval) {
        guard active, phase == .idle, !sources.isEmpty, startTask == nil else { return }
        let gen = generation
        startTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self, !Task.isCancelled, self.generation == gen else { return }
            self.startTask = nil
            guard self.active, self.phase == .idle, TrailerPolicy.allowsAutoplay else { return }
            self.begin()
        }
    }

    private func begin() {
        phase = .loading
        isMuted = !TrailerPolicy.sessionPrefersSound
        var list: [Candidate] = []
        let keys = sources.map(\.youTubeKey)
        let instance = AppSettings.shared.values.invidiousInstance
        if !instance.isEmpty {
            list += keys.prefix(3).map { Candidate.invidious(key: $0, instance: instance) }
        }
        #if os(iOS)
        if !keys.isEmpty { list.append(.web(keys: Array(keys.prefix(4)))) }
        #endif
        candidates = list
        startMonitor()
        advance()
    }

    /// Tries the next source, or gives up quietly.
    private func advance() {
        dropSources()
        loadingTime = 0
        webPlayingSince = nil
        guard phase == .loading else { return }
        guard !candidates.isEmpty else {
            phase = .unavailable
            monitorTask?.cancel(); monitorTask = nil
            return
        }
        let next = candidates.removeFirst()
        switch next {
        case .invidious(let key, let instance):
            let gen = sourceGeneration
            resolveTask = Task { [weak self] in
                let url = await InvidiousTrailer.streamURL(instance: instance, youtubeKey: key)
                guard let self, !Task.isCancelled, self.sourceGeneration == gen, self.phase == .loading else { return }
                self.resolveTask = nil
                if let url { self.startNative(url) } else { self.advance() }
            }
        #if os(iOS)
        case .web(let keys):
            startWeb(keys)
        #endif
        }
    }

    private func startNative(_ url: URL) {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 5
        let p = AVPlayer(playerItem: item)
        p.isMuted = isMuted
        p.preventsDisplaySleepDuringVideoPlayback = false
        p.allowsExternalPlayback = false
        player = p
        if active {
            TrailerAudio.prepare(muted: isMuted)
            p.play()
        }
    }

    #if os(iOS)
    private func startWeb(_ keys: [String]) {
        let gen = sourceGeneration
        let w = TrailerWebPlayer(keys: keys, muted: isMuted, active: active) { [weak self] event in
            guard let self, self.sourceGeneration == gen else { return }
            self.handle(event)
        }
        web = w
        webView = w.view
        if !active { w.pause() } else { TrailerAudio.prepare(muted: isMuted) }
    }

    private func handle(_ event: TrailerWebPlayer.Event) {
        switch event {
        case .playing:
            if phase == .loading, webPlayingSince == nil { webPlayingSince = Date() }
            if !active { web?.pause() }
        case .ended:
            if phase == .playing || phase == .loading { finish() }
        case .failed:
            if phase == .loading || phase == .playing { phase = .loading; advance() }
        }
    }
    #endif

    // MARK: Playback state

    private func pausePlayback() {
        player?.pause()
        #if os(iOS)
        web?.pause()
        #endif
    }

    private func resumePlayback() {
        guard phase == .loading || phase == .playing else { return }
        if player != nil || hasWeb { TrailerAudio.prepare(muted: isMuted) }
        player?.play()
        #if os(iOS)
        web?.play()
        #endif
    }

    private var hasWeb: Bool { webView != nil }

    private func finish() {
        phase = .ended
        pausePlayback()
        monitorTask?.cancel(); monitorTask = nil
    }

    private func dropSources() {
        sourceGeneration += 1
        resolveTask?.cancel(); resolveTask = nil
        player?.pause()
        player = nil
        #if os(iOS)
        web?.stop()
        web = nil
        #endif
        webView = nil
    }

    // MARK: Monitor

    /// Polls the current source four times a second: reveal once frames flow, fade out at the
    /// end, move on when a source fails or never starts. Holds the controller weakly, so it
    /// stops by itself when the page goes away.
    private func startMonitor() {
        monitorTask?.cancel()
        let gen = generation
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, self.generation == gen else { return }
                if !self.tick(interval: 0.25) { return }
            }
        }
    }

    /// Returns false when monitoring can stop.
    private func tick(interval: TimeInterval) -> Bool {
        switch phase {
        case .idle, .ended, .unavailable:
            return false
        case .loading:
            if active { loadingTime += interval }
            if let p = player, let item = p.currentItem {
                if item.status == .failed { advance(); return phase == .loading }
                let t = p.currentTime().seconds
                // `t < 5` ignores the stale end position right after a replay's seek.
                if t.isFinite, t > 0.25, t < 5 {
                    phase = .playing
                    return true
                }
            }
            if webView != nil, let since = webPlayingSince, Date().timeIntervalSince(since) > 1.0 {
                // Brief startup crossfade; provider branding may still appear.
                phase = .playing
                return true
            }
            if loadingTime > TrailerPolicy.loadTimeout { advance(); return phase == .loading }
            return true
        case .playing:
            if let p = player, let item = p.currentItem {
                if item.status == .failed { phase = .loading; advance(); return phase == .loading }
                let t = p.currentTime().seconds
                let d = item.duration.seconds
                // Fade out just before the end, like Netflix (never show a frozen last frame).
                if d.isFinite, d > 1, t.isFinite, t >= d - 0.4 { finish(); return false }
            }
            return true
        }
    }
}

// MARK: - Native surface (AVPlayer)

final class TrailerPlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        #if os(iOS)
        // Keep the whole trailer inside the live iPhone / iPad container.
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        #else
        playerLayer.videoGravity = .resizeAspectFill
        #endif
    }

    required init?(coder: NSCoder) { fatalError() }
}

struct TrailerPlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> TrailerPlayerView {
        let view = TrailerPlayerView(frame: .zero)
        view.playerLayer.player = player
        return view
    }
    func updateUIView(_ uiView: TrailerPlayerView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }
    static func dismantleUIView(_ uiView: TrailerPlayerView, coordinator: ()) {
        uiView.playerLayer.player = nil
    }
}

// MARK: - Web surface (iOS)

#if os(iOS)
/// YouTube's iframe player without chrome: no controls, no taps, sized to fit, and faded
/// out before YouTube's end screen. Tries each id in turn when one is unavailable.
@MainActor
final class TrailerWebPlayer {
    enum Event { case playing, ended, failed }

    let view: WKWebView
    private let proxy: TrailerScriptProxy

    init(keys: [String], muted: Bool, active: Bool = true, onEvent: @escaping (Event) -> Void) {
        let proxy = TrailerScriptProxy()
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        config.allowsAirPlayForMediaPlayback = false
        config.userContentController.add(proxy, name: "trailer")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isUserInteractionEnabled = false
        web.accessibilityElementsHidden = true
        self.view = web
        self.proxy = proxy
        proxy.onMessage = { message in
            switch message {
            case "playing": onEvent(.playing)
            case "ended": onEvent(.ended)
            case "failed": onEvent(.failed)
            default: break
            }
        }
        web.loadHTMLString(Self.html(keys: keys, muted: muted, active: active), baseURL: URL(string: "https://www.youtube-nocookie.com"))
    }

    func play() { run("sfPlay()") }
    func pause() { run("sfPause()") }
    func replay() { run("sfReplay()") }
    func setMuted(_ muted: Bool) { run("sfMute(\(muted ? "true" : "false"))") }

    func stop() {
        proxy.onMessage = nil
        view.evaluateJavaScript("try{sfPause()}catch(e){}", completionHandler: nil)
        view.configuration.userContentController.removeScriptMessageHandler(forName: "trailer")
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
        view.removeFromSuperview()
    }

    private func run(_ js: String) {
        view.evaluateJavaScript("try{\(js)}catch(e){}", completionHandler: nil)
    }

    static func html(keys: [String], muted: Bool, active: Bool = true) -> String {
        let safe = keys.map { $0.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } }.filter { !$0.isEmpty }
        let list = "[" + safe.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <style>
        html,body{margin:0;padding:0;background:#000;overflow:hidden;width:100%;height:100%;}
        #wrap{position:absolute;top:50%;left:50%;width:min(100vw,177.77777778vh);height:min(100vh,56.25vw);
              transform:translate(-50%,-50%);pointer-events:none;}
        #wrap iframe,#p{width:100%;height:100%;border:0;pointer-events:none;}
        </style></head><body><div id="wrap"><div id="p"></div></div>
        <script>
        var keys=\(list),idx=0,player=null,muted=\(muted ? "true" : "false"),want=\(active ? "true" : "false"),done=false,started=false;
        function post(m){try{window.webkit.messageHandlers.trailer.postMessage(m);}catch(e){}}
        if(!keys.length){post('failed');}
        function onYouTubeIframeAPIReady(){
          if(!keys.length)return;
          player=new YT.Player('p',{host:'https://www.youtube-nocookie.com',videoId:keys[0],
            playerVars:{autoplay:1,mute:1,controls:0,playsinline:1,rel:0,iv_load_policy:3,
                        disablekb:1,fs:0,cc_load_policy:0,enablejsapi:1,origin:'https://www.youtube-nocookie.com'},
            events:{
              onReady:function(e){if(muted){e.target.mute();}else{e.target.unMute();} if(want){e.target.playVideo();}},
              onStateChange:function(e){
                if(e.data===1){ if(!want){player.pauseVideo();return;} if(!started){started=true;post('playing');} }
                else if(e.data===0){finish();}
              },
              onError:function(){next();}
            }});
        }
        function next(){idx++;started=false;if(idx<keys.length){player.loadVideoById(keys[idx]);}else{post('failed');}}
        function finish(){if(done)return;done=true;try{player.pauseVideo();}catch(e){}post('ended');}
        setInterval(function(){try{
          if(!player||!player.getDuration||done||!started)return;
          var d=player.getDuration(),t=player.getCurrentTime();
          if(d>1&&t>0&&d-t<0.9){finish();}
        }catch(e){}},250);
        function sfPlay(){want=true;if(player&&!done&&player.playVideo)player.playVideo();}
        function sfPause(){want=false;if(player&&player.pauseVideo)player.pauseVideo();}
        function sfMute(m){muted=m;if(player&&player.mute){if(m){player.mute();}else{player.unMute();}}}
        function sfReplay(){if(!player||!player.seekTo)return;done=false;started=false;want=true;player.seekTo(0,true);player.playVideo();}
        </script>
        <script src="https://www.youtube.com/iframe_api" onerror="post('failed')"></script>
        </body></html>
        """
    }
}

/// Weak bridge for script messages (WKUserContentController retains its handlers strongly).
final class TrailerScriptProxy: NSObject, WKScriptMessageHandler {
    var onMessage: ((String) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? String ?? ""
        MainActor.assumeIsolated {
            self.onMessage?(body)
        }
    }
}

#endif

// MARK: - SwiftUI pieces

/// Hosts the controller's web view; re-parents it if SwiftUI rebuilds the container.
struct TrailerWebHost: UIViewRepresentable {
    let webView: UIView

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.backgroundColor = .clear
        container.isUserInteractionEnabled = false
        container.clipsToBounds = true
        attach(to: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if webView.superview !== uiView { attach(to: uiView) }
    }

    private func attach(to container: UIView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
    }
}

/// The video layer: goes over the artwork, fades in when frames flow and out at the end.
/// `insets` keeps the picture (and YouTube's own top overlay) clear of the status bar /
/// Dynamic Island when the hero runs edge to edge under it; the artwork still fills that area.
struct TrailerSurface: View {
    let controller: TrailerController
    var insets = EdgeInsets()

    var body: some View {
        ZStack {
            #if os(iOS)
            // The iOS video is fitted (letterboxed), so the inset strip matches its black bars.
            Color.black
            #else
            Color.clear
            #endif
            if let player = controller.player {
                TrailerPlayerSurface(player: player)
                    .padding(insets)
            }
            if let webView = controller.webView {
                TrailerWebHost(webView: webView)
                    .padding(insets)
            }
        }
        .opacity(controller.isRevealed ? 1 : 0)
        .animation(.easeInOut(duration: TrailerPolicy.fade), value: controller.isRevealed)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Small round mute/unmute button while the trailer plays, replay once it has ended (iOS;
/// tvOS keeps trailers muted and adds nothing focusable, so focus behaves as before).
struct TrailerControlButton: View {
    let controller: TrailerController

    var body: some View {
        #if os(iOS)
        ZStack {
            switch controller.phase {
            case .playing:
                button(controller.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       label: controller.isMuted ? "Unmute trailer" : "Mute trailer") { controller.toggleMute() }
            case .ended:
                button("arrow.counterclockwise", label: "Replay trailer") { controller.replay() }
            case .idle, .loading, .unavailable:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: controller.phase)
        #else
        EmptyView()
        #endif
    }

    #if os(iOS)
    private func button(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.35), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .transition(.opacity)
    }
    #endif
}

/// Reports whether a hero is still mostly on screen (it pauses its trailer when scrolled away).
struct HeroVisibilityReader: View {
    var height: CGFloat
    @Binding var isVisible: Bool

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            Color.clear
                .onChange(of: frame.maxY > height * 0.45, initial: true) { _, visible in
                    if isVisible != visible { isVisible = visible }
                }
        }
    }
}


/// Explicit Trailer action stays in StreamForge and uses the same YouTube player.
struct TrailerPreviewSheet: View {
    let title: String
    let sources: [TrailerSource]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller = TrailerController()

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                VStack(spacing: 20) {
                    Spacer(minLength: 0)
                    ZStack {
                        Color.black
                        TrailerSurface(controller: controller)
                        if controller.phase == .loading || controller.phase == .idle {
                            ProgressView("Loading trailer…")
                        } else if controller.phase == .unavailable {
                            Text("No playable trailer is available right now.")
                                .multilineTextAlignment(.center).padding()
                        }
                    }
                    .frame(width: geo.size.width, height: min(geo.size.width * 9 / 16, max(1, geo.size.height - 80)))
                    HStack(spacing: 24) {
                        if controller.phase == .playing {
                            Button(controller.isMuted ? "Unmute" : "Mute") { controller.toggleMute() }
                        }
                        if controller.phase == .ended {
                            Button("Replay") { controller.replay() }
                        }
                    }.buttonStyle(.bordered)
                    Spacer(minLength: 0)
                }
            }
            .background(Color.black)
            .navigationTitle(title)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                controller.setSources(sources)
                if scenePhase == .active { controller.playManually() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    if controller.phase == .idle { controller.playManually() } else { controller.setActive(true) }
                } else { controller.setActive(false) }
            }
            .onDisappear { controller.reset() }
        }
    }
}
