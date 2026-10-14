#if os(iOS)
import AVKit
import AVFoundation
import CoreMedia
import CoreVideo
import Observation
import SwiftUI
import UIKit

/// Holds the layers Picture in Picture can use. It sits behind the mpv surface in the player,
/// because AVKit needs its source layer to be in the window.
final class PiPLayerHostView: UIView {
    let playerLayer = AVPlayerLayer()
    let sampleLayer = AVSampleBufferDisplayLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        playerLayer.videoGravity = .resizeAspect
        sampleLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
        layer.addSublayer(sampleLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        sampleLayer.frame = bounds
        CATransaction.commit()
    }
}

struct PiPHostSurface: UIViewRepresentable {
    let controller: PiPController
    func makeUIView(context: Context) -> PiPLayerHostView { controller.hostView }
    func updateUIView(_ uiView: PiPLayerHostView, context: Context) {}
}

/// Picture in Picture for the mpv player.
///
/// mpv draws into a CAMetalLayer, which AVKit can't use. Two strategies:
/// - **Hand-off** (MP4/MOV/HLS): an AVPlayer takes over at the current position and PiP uses its
///   AVPlayerLayer. mpv pauses; when PiP ends, mpv resumes where AVPlayer stopped.
/// - **Software** (MKV/TS/live): a second mpv instance using mpv's software render API takes over
///   at the current position and renders PiP-sized frames into an AVSampleBufferDisplayLayer. It
///   never touches the GPU, so it keeps playing while the app is in the background.
@MainActor
@Observable
final class PiPController {
    enum Mode { case handoff, frames }

    private(set) var isActive = false
    private(set) var isStarting = false
    private(set) var mode: Mode?

    let hostView: PiPLayerHostView
    @ObservationIgnored private weak var model: PlayerModel?
    @ObservationIgnored private var pip: AVPictureInPictureController?
    @ObservationIgnored private var proxy: PiPDelegateProxy?
    @ObservationIgnored private var avPlayer: AVPlayer?
    @ObservationIgnored private var renderer: MPVSoftwareRenderer?
    @ObservationIgnored private var startTask: Task<Void, Never>?

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    init() {
        hostView = PiPLayerHostView(frame: .zero)
    }

    // MARK: Start / stop

    func toggle(model: PlayerModel) {
        if isActive || isStarting { stop(resume: true) } else { start(model: model) }
    }

    func start(model: PlayerModel) {
        guard pip == nil, Self.isSupported, model.hasStarted else { return }
        self.model = model
        isStarting = true
        let proxy = PiPDelegateProxy()
        proxy.owner = self
        self.proxy = proxy

        let controller: AVPictureInPictureController
        if let url = model.resolvedURL, !model.isLive, model.isAVPlayerCompatible {
            mode = .handoff
            let options: [String: Any]? = model.resolvedHeaders.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": model.resolvedHeaders]
            let asset = AVURLAsset(url: url, options: options)
            let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            player.allowsExternalPlayback = true
            hostView.playerLayer.player = player
            hostView.playerLayer.isHidden = false
            hostView.sampleLayer.isHidden = true
            let wasPlaying = !model.isPaused
            player.seek(to: CMTime(seconds: max(0, model.position), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() }
            model.pauseForHandoff()
            avPlayer = player
            controller = AVPictureInPictureController(contentSource: .init(playerLayer: hostView.playerLayer))
        } else {
            guard let url = model.resolvedURL,
                  let renderer = MPVSoftwareRenderer(layer: hostView.sampleLayer, userAgent: AppSettings.shared.values.customUserAgent) else {
                isStarting = false
                model.showToast("Picture in Picture isn't available for this stream")
                return
            }
            mode = .frames
            hostView.playerLayer.isHidden = true
            hostView.sampleLayer.isHidden = false
            hostView.sampleLayer.flush()
            hostView.sampleLayer.controlTimebase = nil
            let wasPlaying = !model.isPaused
            renderer.load(url, start: model.isLive ? nil : model.position, headers: model.resolvedHeaders, live: model.isLive)
            renderer.setPaused(!wasPlaying)
            model.pauseForHandoff()
            self.renderer = renderer
            proxy.paused = !wasPlaying
            proxy.live = model.isLive
            proxy.duration = model.duration
            proxy.position = model.position
            let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: hostView.sampleLayer, playbackDelegate: proxy)
            controller = AVPictureInPictureController(contentSource: source)
            controller.requiresLinearPlayback = model.isLive
        }
        controller.delegate = proxy
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        pip = controller

        // `isPictureInPicturePossible` turns true asynchronously once the layer is ready.
        startTask?.cancel()
        startTask = Task { [weak self] in
            for _ in 0..<40 {
                guard let self, !Task.isCancelled else { return }
                if let pip = self.pip, pip.isPictureInPicturePossible {
                    pip.startPictureInPicture()
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            self?.model?.showToast("Picture in Picture isn't available right now")
            self?.stop(resume: true)
        }
    }

    /// Ends PiP and hands playback back to mpv.
    func stop(resume: Bool) {
        startTask?.cancel()
        startTask = nil
        if let pip, pip.isPictureInPictureActive { pip.stopPictureInPicture() }
        finish(restored: resume)
    }

    private func finish(restored: Bool) {
        if mode == .handoff, let player = avPlayer {
            let t = player.currentTime().seconds
            let playing = player.rate > 0
            player.pause()
            hostView.playerLayer.player = nil
            model?.resumeAfterHandoff(at: t.isFinite ? t : nil, play: playing || (restored && isActive))
        }
        if mode == .frames, let renderer {
            let t = renderer.position
            let playing = !renderer.isPaused
            renderer.destroy()
            hostView.sampleLayer.flush()
            if let model {
                if model.isLive {
                    model.resumeAfterHandoff(at: nil, play: playing || restored)
                    model.goLive()
                } else {
                    model.resumeAfterHandoff(at: t, play: playing || (restored && isActive))
                }
            }
        }
        renderer = nil
        avPlayer = nil
        pip?.delegate = nil
        pip = nil
        proxy = nil
        mode = nil
        isActive = false
        isStarting = false
    }

    // MARK: Delegate callbacks (via proxy, on the main actor)

    fileprivate func didStart() {
        isStarting = false
        isActive = true
    }

    fileprivate func failed(_ message: String) {
        model?.showToast("Picture in Picture failed: \(message)")
        finish(restored: true)
    }

    fileprivate func didStop(restored: Bool) {
        guard pip != nil else { return }
        finish(restored: restored)
    }

    fileprivate func setPlaying(_ playing: Bool) {
        if let renderer {
            renderer.setPaused(!playing)
        } else {
            model?.player.setFlag("pause", !playing)
        }
        proxy?.paused = !playing
        pip?.invalidatePlaybackState()
    }

    fileprivate func skip(by seconds: Double) {
        if let renderer {
            renderer.seek(by: seconds)
            refreshProxyFromRenderer()
            return
        }
        guard let model, model.canSeek else { return }
        model.seek(by: seconds)
    }

    private func refreshProxyFromRenderer() {
        guard let renderer, let proxy else { return }
        if let p = renderer.position { proxy.position = p }
        if let d = renderer.duration, d > 0 { proxy.duration = d }
        proxy.paused = renderer.isPaused
        pip?.invalidatePlaybackState()
    }

}

/// Non-isolated delegate object for AVKit. Queries answer from a state snapshot; actions hop to the main actor.
final class PiPDelegateProxy: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    weak var owner: PiPController?
    var paused = false
    var live = false
    var duration: Double = 0
    var position: Double = 0
    private var restoreRequested = false

    // MARK: AVPictureInPictureControllerDelegate

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        let o = owner
        Task { @MainActor in o?.didStart() }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        let message = error.localizedDescription
        let o = owner
        Task { @MainActor in o?.failed(message) }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        restoreRequested = true
        completionHandler(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        let restored = restoreRequested
        restoreRequested = false
        let o = owner
        Task { @MainActor in o?.didStop(restored: restored) }
    }

    // MARK: AVPictureInPictureSampleBufferPlaybackDelegate

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        paused = !playing
        let o = owner
        Task { @MainActor in o?.setPlaying(playing) }
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        if live || duration <= 0 {
            return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }
        return CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        paused
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        let seconds = CMTimeGetSeconds(skipInterval)
        let o = owner
        Task { @MainActor in
            o?.skip(by: seconds)
            completionHandler()
        }
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        // mpv keeps producing the audio while PiP shows the frames.
        false
    }
}

// MARK: - PlayerModel glue

extension PlayerModel {
    /// Lazily created PiP controller (iOS only).
    var pip: PiPController {
        if let existing = pipStorage as? PiPController { return existing }
        let created = PiPController()
        pipStorage = created
        return created
    }

    func togglePictureInPicture() {
        pip.toggle(model: self)
    }

    func stopPictureInPicture() {
        (pipStorage as? PiPController)?.stop(resume: false)
    }
}
#endif
