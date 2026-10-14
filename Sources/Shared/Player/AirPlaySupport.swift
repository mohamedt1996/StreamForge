#if os(iOS)
import AVKit
import AVFoundation
import SwiftUI
import UIKit

/// The system AirPlay route button (audio routes; video routes only matter for the hand-off player).
struct RoutePickerButton: UIViewRepresentable {
    var prioritizesVideo = false

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        view.tintColor = .white
        view.activeTintColor = UIColor(Theme.accent)
        view.prioritizesVideoDevices = prioritizesVideo
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.prioritizesVideoDevices = prioritizesVideo
    }
}

/// What the AVPlayer hand-off needs to continue where mpv was.
struct AirPlayHandoffRequest: Identifiable {
    let id = UUID()
    var url: URL
    var headers: [String: String]
    var start: Double
    var title: String
}

/// Plays a compatible source with AVPlayer so it can go to an AirPlay receiver as real video.
/// Shown as an overlay inside the player; `onFinish` must remove it.
struct AirPlayHandoffView: View {
    let request: AirPlayHandoffRequest
    /// Called once with the position AVPlayer reached and whether it was playing.
    let onFinish: (Double?, Bool) -> Void
    @State private var session = AirPlayHandoffSession()

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            AVPlayerControllerView(player: session.player)
                .ignoresSafeArea()
            HStack(spacing: 12) {
                Button {
                    report()
                } label: {
                    Label("Back to StreamForge player", systemImage: "chevron.backward")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                Spacer()
                RoutePickerButton(prioritizesVideo: true)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .preferredColorScheme(.dark)
        .onAppear { session.start(request) }
        .onDisappear {
            // Covers the player closing underneath us as well as the button.
            if !session.finished { report() }
        }
    }

    private func report() {
        guard !session.finished else { return }
        session.finished = true
        let t = session.player.currentTime().seconds
        let playing = session.player.rate > 0
        session.player.pause()
        onFinish(t.isFinite ? t : nil, playing)
    }
}

/// Owns the AVPlayer for one hand-off.
@MainActor
@Observable
final class AirPlayHandoffSession {
    let player = AVPlayer()
    var finished = false
    private var started = false

    func start(_ request: AirPlayHandoffRequest) {
        guard !started else { return }
        started = true
        let options: [String: Any]? = request.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": request.headers]
        let item = AVPlayerItem(asset: AVURLAsset(url: request.url, options: options))
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        player.replaceCurrentItem(with: item)
        if request.start > 1 {
            player.seek(to: CMTime(seconds: request.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
    }
}

struct AVPlayerControllerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.updatesNowPlayingInfoCenter = true
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.videoGravity = .resizeAspect
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
    }
}
#endif
