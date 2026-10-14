#if os(iOS)
import SwiftUI
import WebKit

/// Muted, looping YouTube trailer behind the detail header (iOS only; tvOS has no WebKit).
struct TrailerBackdrop: UIViewRepresentable {
    var youtubeKey: String
    var onReady: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onReady: onReady) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.isUserInteractionEnabled = false
        web.navigationDelegate = context.coordinator
        web.loadHTMLString(html, baseURL: URL(string: "https://www.youtube-nocookie.com"))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.loadHTMLString("", baseURL: nil)
    }

    private var html: String {
        let key = youtubeKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? youtubeKey
        let src = "https://www.youtube-nocookie.com/embed/\(key)?autoplay=1&mute=1&controls=0&playsinline=1&loop=1&playlist=\(key)&modestbranding=1&rel=0&iv_load_policy=3&disablekb=1&fs=0"
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;padding:0;background:transparent;overflow:hidden;height:100%;}
        .w{position:absolute;top:50%;left:50%;width:177.78vh;height:100vh;min-width:100%;min-height:56.25vw;transform:translate(-50%,-50%);}
        iframe{width:100%;height:100%;border:0;pointer-events:none;}</style></head>
        <body><div class="w"><iframe src="\(src)" allow="autoplay; encrypted-media" allowfullscreen="false"></iframe></div></body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onReady: () -> Void
        init(onReady: @escaping () -> Void) { self.onReady = onReady }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Give the player a moment to start so the fade-in doesn't reveal YouTube's spinner.
            let ready = onReady
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { ready() }
        }
    }
}

/// Decides when the trailer may play: setting on, not cellular / Low Data Mode, ~2 s after
/// the page appears, and only while the header is on screen.
struct TrailerLayer: View {
    var youtubeKey: String?
    var visible: Bool
    @State private var armed = false
    @State private var loaded = false

    private var allowed: Bool {
        AppSettings.shared.values.trailerAutoplay && NetworkStatus.shared.allowsAutoplayMedia && !ProfileStore.shared.isKidsMode
    }

    var body: some View {
        ZStack {
            Color.clear
            if let key = youtubeKey, allowed, armed, visible {
                TrailerBackdrop(youtubeKey: key) { loaded = true }
                    .opacity(loaded ? 1 : 0)
                    .animation(.easeInOut(duration: 0.8), value: loaded)
                    .allowsHitTesting(false)
                    .onDisappear { loaded = false }
            }
        }
        .allowsHitTesting(false)
        .task(id: youtubeKey) {
            armed = false
            loaded = false
            guard youtubeKey != nil else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { armed = true }
        }
        .onDisappear { armed = false; loaded = false }
    }
}
#endif

#if os(tvOS)
import SwiftUI
import AVFoundation
import UIKit

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
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let result = try? await URLSession.shared.data(for: req),
              let http = result.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let video = try? JSONDecoder().decode(Video.self, from: result.0) else { return nil }
        func height(_ f: Video.Format) -> Int { Int((f.resolution ?? "").filter(\.isNumber)) ?? 0 }
        let mp4 = (video.formatStreams ?? []).filter {
            $0.url != nil && (($0.container ?? "").lowercased() == "mp4" || ($0.type ?? "").lowercased().contains("mp4"))
        }
        guard let best = mp4.max(by: { height($0) < height($1) }), let raw = best.url else { return nil }
        return URL(string: raw, relativeTo: base)?.absoluteURL
    }
}

final class TrailerPlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        playerLayer.videoGravity = .resizeAspectFill
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
}

/// tvOS trailer behind the detail header: only when trailers are on and an Invidious instance is set.
struct TrailerLayer: View {
    var youtubeKey: String?
    var visible: Bool
    @State private var player: AVPlayer?
    @State private var ready = false

    private var instance: String { AppSettings.shared.values.invidiousInstance }

    private var allowed: Bool {
        AppSettings.shared.values.trailerAutoplay && !instance.isEmpty && NetworkStatus.shared.allowsAutoplayMedia
            && !ProfileStore.shared.isKidsMode
    }

    var body: some View {
        ZStack {
            Color.clear
            if let player, visible {
                TrailerPlayerSurface(player: player)
                    .opacity(ready ? 1 : 0)
                    .animation(.easeInOut(duration: 0.8), value: ready)
            }
        }
        .allowsHitTesting(false)
        .task(id: youtubeKey) {
            stop()
            guard let key = youtubeKey, allowed else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let url = await InvidiousTrailer.streamURL(instance: instance, youtubeKey: key),
                  !Task.isCancelled else { return }
            let p = AVPlayer(url: url)
            p.isMuted = true
            p.preventsDisplaySleepDuringVideoPlayback = false
            player = p
            if visible { p.play() }
            // Fade in once frames are flowing, so the spinner-free header never flashes black.
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
                if p.currentTime().seconds > 0.3 { ready = true; return }
            }
        }
        .onChange(of: visible) {
            if visible { player?.play() } else { player?.pause() }
        }
        .onDisappear { stop() }
    }

    private func stop() {
        player?.pause()
        player = nil
        ready = false
    }
}
#endif
