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
/// - **Frames** (MKV/TS/live): mpv keeps playing (and keeps the audio); its decoded frames are copied
///   with `screenshot-raw` into an AVSampleBufferDisplayLayer at a reduced frame rate.
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
    @ObservationIgnored private var frameTimer: DispatchSourceTimer?
    @ObservationIgnored private var timebase: CMTimebase?
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
            mode = .frames
            hostView.playerLayer.isHidden = true
            hostView.sampleLayer.isHidden = false
            hostView.sampleLayer.flush()
            var tb: CMTimebase?
            CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
            if let tb {
                CMTimebaseSetTime(tb, time: CMTime(seconds: max(0, model.position), preferredTimescale: 600))
                CMTimebaseSetRate(tb, rate: model.isPaused ? 0 : 1)
                hostView.sampleLayer.controlTimebase = tb
            }
            timebase = tb
            syncProxy()
            let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: hostView.sampleLayer, playbackDelegate: proxy)
            controller = AVPictureInPictureController(contentSource: source)
            controller.requiresLinearPlayback = model.isLive && !model.canSeek
            let fps = max(8, min(30, PlayerPreferences.shared.values.pipFrameRate))
            frameTimer = Self.makeFrameTimer(player: model.player, layer: hostView.sampleLayer, timebase: tb, fps: fps)
            model.pipSync = { [weak self] in self?.syncFromModel() }
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
        frameTimer?.cancel()
        frameTimer = nil
        if mode == .handoff, let player = avPlayer {
            let t = player.currentTime().seconds
            let playing = player.rate > 0
            player.pause()
            hostView.playerLayer.player = nil
            model?.resumeAfterHandoff(at: t.isFinite ? t : nil, play: playing || (restored && isActive))
        }
        if mode == .frames {
            model?.pipSync = nil
            hostView.sampleLayer.flush()
            hostView.sampleLayer.controlTimebase = nil
        }
        avPlayer = nil
        timebase = nil
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
        model?.player.setFlag("pause", !playing)
        if let timebase { CMTimebaseSetRate(timebase, rate: playing ? 1 : 0) }
        proxy?.paused = !playing
        pip?.invalidatePlaybackState()
    }

    fileprivate func skip(by seconds: Double) {
        guard let model, model.canSeek else { return }
        model.seek(by: seconds)
    }

    private func syncFromModel() {
        guard let model else { return }
        if let timebase {
            CMTimebaseSetTime(timebase, time: CMTime(seconds: max(0, model.position), preferredTimescale: 600))
            CMTimebaseSetRate(timebase, rate: model.isPaused ? 0 : 1)
        }
        syncProxy()
        pip?.invalidatePlaybackState()
    }

    private func syncProxy() {
        guard let model, let proxy else { return }
        proxy.paused = model.isPaused
        proxy.live = model.isLive
        proxy.duration = model.duration
        proxy.position = model.position
    }

    // MARK: Frame pump (runs off the main actor)

    nonisolated private static func makeFrameTimer(player: MPVPlayer, layer: AVSampleBufferDisplayLayer,
                                                   timebase: CMTimebase?, fps: Int) -> DispatchSourceTimer {
        let queue = DispatchQueue(label: "streamforge.pip.frames", qos: .userInteractive)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(1000 / fps), leeway: .milliseconds(5))
        timer.setEventHandler {
            guard let buffer = player.copyVideoFrame() else { return }
            let time = timebase.map { CMTimebaseGetTime($0) } ?? CMClockGetTime(CMClockGetHostTimeClock())
            guard let sample = makeSampleBuffer(buffer, time: time) else { return }
            DispatchQueue.main.async {
                if layer.status == .failed { layer.flush() }
                layer.enqueue(sample)
            }
        }
        timer.resume()
        return timer
    }

    nonisolated private static func makeSampleBuffer(_ buffer: CVPixelBuffer, time: CMTime) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                           formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                       formatDescription: format, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
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
