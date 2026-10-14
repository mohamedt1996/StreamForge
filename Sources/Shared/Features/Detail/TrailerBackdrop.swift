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
