#if os(iOS)
import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import Libmpv

/// A second, lightweight mpv instance that renders with mpv's software render API
/// (`MPV_RENDER_API_TYPE_SW`) into CVPixelBuffers for an AVSampleBufferDisplayLayer.
///
/// Used for Picture in Picture of formats AVPlayer can't play (MKV, MPEG-TS, live channels):
/// unlike the main Metal-backed player it never touches the GPU, so it keeps running while the
/// app is in the background. Frames are rendered at PiP size, which keeps the CPU cost low.
final class MPVSoftwareRenderer: @unchecked Sendable {
    let layer: AVSampleBufferDisplayLayer
    private(set) var handle: OpaquePointer?
    private var renderContext: OpaquePointer?
    private let renderQueue = DispatchQueue(label: "streamforge.pip.render", qos: .userInteractive)
    private let eventQueue = DispatchQueue(label: "streamforge.pip.events", qos: .userInitiated)
    private var pool: CVPixelBufferPool?
    private let width: Int32
    private let height: Int32
    private var formatPtr: UnsafeMutablePointer<CChar>?
    private var destroyed = false
    /// Called on the main queue once the first frame has been enqueued.
    var onFirstFrame: (() -> Void)?
    private var deliveredFirstFrame = false

    init?(layer: AVSampleBufferDisplayLayer, width: Int32 = 960, height: Int32 = 540, userAgent: String?) {
        self.layer = layer
        self.width = width
        self.height = height
        guard let mpv = mpv_create() else { return nil }
        handle = mpv
        mpv_request_log_messages(mpv, "no")
        let opts: [(String, String)] = [
            ("vo", "libmpv"),
            ("hwdec", "videotoolbox-copy"),
            ("sw-fast", "yes"),
            ("keep-open", "yes"),
            ("idle", "yes"),
            ("ytdl", "no"),
            ("input-default-bindings", "no"),
            ("cache", "yes"),
            ("demuxer-max-bytes", "64MiB"),
            ("demuxer-max-back-bytes", "16MiB"),
            ("network-timeout", "30"),
            ("stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=6"),
            ("sid", "no"),
            ("user-agent", userAgent?.isEmpty == false ? userAgent! : "StreamForge/1.0 (mpv)"),
        ]
        for (k, v) in opts { mpv_set_option_string(mpv, k, v) }
        guard mpv_initialize(mpv) >= 0 else {
            mpv_terminate_destroy(mpv)
            handle = nil
            return nil
        }

        let apiType = strdup("sw")
        defer { free(apiType) }
        var params = [
            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiType)),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
        ]
        var ctx: OpaquePointer?
        guard mpv_render_context_create(&ctx, mpv, &params) >= 0, let ctx else {
            mpv_terminate_destroy(mpv)
            handle = nil
            return nil
        }
        renderContext = ctx
        formatPtr = strdup("bgr0")

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(width),
            kCVPixelBufferHeightKey as String: Int(height),
            kCVPixelBufferBytesPerRowAlignmentKey as String: 64,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)

        mpv_render_context_set_update_callback(ctx, { ctxPtr in
            guard let ctxPtr else { return }
            let renderer = Unmanaged<MPVSoftwareRenderer>.fromOpaque(ctxPtr).takeUnretainedValue()
            renderer.scheduleRender()
        }, Unmanaged.passUnretained(self).toOpaque())

        // Drain events so the core never stalls on a full queue.
        mpv_set_wakeup_callback(mpv, { ctxPtr in
            guard let ctxPtr else { return }
            let renderer = Unmanaged<MPVSoftwareRenderer>.fromOpaque(ctxPtr).takeUnretainedValue()
            renderer.drainEvents()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit { destroy() }

    // MARK: Control

    func load(_ url: URL, start: Double?, headers: [String: String], live: Bool) {
        guard let mpv = handle else { return }
        let headerValue = headers.map { "\($0.key): \($0.value)" }.joined(separator: ",")
        mpv_set_property_string(mpv, "http-header-fields", headerValue)
        mpv_set_property_string(mpv, "start", start.map { String(format: "%.2f", max(0, $0)) } ?? "none")
        mpv_set_property_string(mpv, "cache-pause-initial", live ? "yes" : "no")
        command(["loadfile", url.absoluteString, "replace"])
    }

    func setPaused(_ paused: Bool) {
        guard let mpv = handle else { return }
        var v: Int32 = paused ? 1 : 0
        mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &v)
    }

    func seek(by seconds: Double) {
        command(["seek", String(format: "%.3f", seconds), "relative"])
    }

    var position: Double? {
        guard let mpv = handle else { return nil }
        var v = Double()
        return mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &v) >= 0 ? v : nil
    }

    var duration: Double? {
        guard let mpv = handle else { return nil }
        var v = Double()
        return mpv_get_property(mpv, "duration", MPV_FORMAT_DOUBLE, &v) >= 0 ? v : nil
    }

    var isPaused: Bool {
        guard let mpv = handle else { return true }
        var v = Int32()
        mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &v)
        return v != 0
    }

    private func command(_ args: [String]) {
        guard let mpv = handle else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { for p in cargs where p != nil { free(UnsafeMutablePointer(mutating: p)) } }
        mpv_command_async(mpv, 0, &cargs)
    }

    // MARK: Rendering

    private func scheduleRender() {
        renderQueue.async { [weak self] in self?.renderFrame() }
    }

    private func renderFrame() {
        guard !destroyed, let ctx = renderContext, let pool, let formatPtr else { return }
        let flags = mpv_render_context_update(ctx)
        guard flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }

        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess, let buffer = out else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return
        }
        var size: [Int32] = [width, height]
        var stride = CVPixelBufferGetBytesPerRow(buffer)
        size.withUnsafeMutableBufferPointer { sizePtr in
            withUnsafeMutablePointer(to: &stride) { stridePtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(sizePtr.baseAddress)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(formatPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stridePtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: base),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                _ = mpv_render_context_render(ctx, &params)
            }
        }
        // "bgr0" leaves the 4th byte undefined; force it opaque so the layer shows the frame.
        let rows = Int(height), cols = Int(width)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<rows {
            var i = y * stride + 3
            let end = y * stride + cols * 4
            while i < end { bytes[i] = 255; i += 4 }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        guard let sample = Self.sampleBuffer(buffer) else { return }
        let layer = self.layer
        let first = !deliveredFirstFrame
        deliveredFirstFrame = true
        DispatchQueue.main.async { [weak self] in
            if layer.status == .failed { layer.flush() }
            layer.enqueue(sample)
            if first { self?.onFirstFrame?() }
        }
    }

    private static func sampleBuffer(_ buffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                           formatDescriptionOut: &format) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                       formatDescription: format, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    // MARK: Events / teardown

    private func drainEvents() {
        eventQueue.async { [weak self] in
            guard let self else { return }
            while let mpv = self.handle, !self.destroyed {
                guard let event = mpv_wait_event(mpv, 0) else { break }
                if event.pointee.event_id == MPV_EVENT_NONE || event.pointee.event_id == MPV_EVENT_SHUTDOWN { break }
            }
        }
    }

    func destroy() {
        guard !destroyed else { return }
        destroyed = true
        let ctx = renderContext
        let mpv = handle
        let fmt = formatPtr
        renderContext = nil
        handle = nil
        formatPtr = nil
        if let mpv { mpv_set_wakeup_callback(mpv, nil, nil) }
        if let ctx { mpv_render_context_set_update_callback(ctx, nil, nil) }
        // The render context must be freed before the core, on the render queue so no render is in flight.
        renderQueue.async {
            if let ctx { mpv_render_context_free(ctx) }
            if let mpv { mpv_terminate_destroy(mpv) }
            if let fmt { free(fmt) }
        }
    }
}
#endif
