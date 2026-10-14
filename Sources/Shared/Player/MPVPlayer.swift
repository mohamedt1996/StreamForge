import Foundation
import UIKit
import Libmpv

/// CAMetalLayer with the MoltenVK workarounds from the MPVKit reference player.
final class MPVMetalLayer: CAMetalLayer {
    // MoltenVK briefly sets drawableSize to 1x1 to finish presentation; ignoring it avoids flicker.
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 { super.drawableSize = newValue }
        }
    }

    #if os(iOS)
    // EDR must be toggled on the main thread or the screen never enters HDR mode.
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.sync { super.wantsExtendedDynamicRangeContent = newValue }
            }
        }
    }
    #endif
}

final class MPVVideoView: UIView {
    override class var layerClass: AnyClass { MPVMetalLayer.self }
    var metalLayer: MPVMetalLayer { layer as! MPVMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
}

struct MPVTrack: Identifiable, Hashable {
    enum Kind: String { case video, audio, sub }
    var id: Int
    var kind: Kind
    var title: String?
    var lang: String?
    var codec: String?
    var isSelected: Bool
    var isExternal: Bool
    var channels: Int?
    var isDefault: Bool

    var displayName: String {
        var parts: [String] = []
        if let lang, let name = Locale.current.localizedString(forLanguageCode: lang) { parts.append(name) }
        else if let lang { parts.append(lang.uppercased()) }
        if let title, !title.isEmpty, title.lowercased() != lang?.lowercased() { parts.append(title) }
        if parts.isEmpty { parts.append("Track \(id)") }
        var extra: [String] = []
        if let codec { extra.append(codec.uppercased()) }
        if let channels, channels > 0 { extra.append(channels == 6 ? "5.1" : channels == 8 ? "7.1" : "\(channels)ch") }
        if isExternal { extra.append("External") }
        return parts.joined(separator: " · ") + (extra.isEmpty ? "" : "  (\(extra.joined(separator: ", ")))")
    }
}

@MainActor
protocol MPVPlayerDelegate: AnyObject {
    func mpvPropertyChanged(_ name: String, value: Any?)
    func mpvFileLoaded()
    func mpvEndFile(error: String?)
    func mpvTracksChanged()
}

/// Owns one libmpv instance rendering into an `MPVVideoView` via MoltenVK.
final class MPVPlayer {
    struct Options {
        var hwdec: String = "videotoolbox"
        var hdr: Bool = true
        var cacheMB: Int = 150
        var userAgent: String?
        var audioLanguage: String = "en"
        var subtitleLanguage: String = "en"
        var autoSubtitles: Bool = false
        var subtitleScale: Double = 1.0
    }

    let view = MPVVideoView(frame: .zero)
    weak var delegate: MPVPlayerDelegate?
    private(set) var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "streamforge.mpv.events", qos: .userInitiated)

    // Properties observed and pushed to the delegate.
    static let observed: [(String, mpv_format)] = [
        ("time-pos", MPV_FORMAT_DOUBLE),
        ("duration", MPV_FORMAT_DOUBLE),
        ("pause", MPV_FORMAT_FLAG),
        ("paused-for-cache", MPV_FORMAT_FLAG),
        ("core-idle", MPV_FORMAT_FLAG),
        ("eof-reached", MPV_FORMAT_FLAG),
        ("demuxer-cache-time", MPV_FORMAT_DOUBLE),
        ("cache-buffering-state", MPV_FORMAT_INT64),
        ("track-list/count", MPV_FORMAT_INT64),
        ("video-params/sig-peak", MPV_FORMAT_DOUBLE),
        ("speed", MPV_FORMAT_DOUBLE),
        ("chapter-list/count", MPV_FORMAT_INT64),
    ]

    init(options: Options) {
        guard let mpv = mpv_create() else { return }
        handle = mpv

        #if DEBUG
        mpv_request_log_messages(mpv, "warn")
        #else
        mpv_request_log_messages(mpv, "no")
        #endif

        var layer = view.metalLayer
        mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &layer)

        let opts: [(String, String)] = [
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", options.hwdec),
            ("target-colorspace-hint", options.hdr ? "yes" : "no"),
            ("tone-mapping", "auto"),
            ("video-rotate", "no"),
            ("keep-open", "yes"),
            ("idle", "yes"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("ytdl", "no"),
            ("hr-seek", "yes"),
            ("cache", "yes"),
            ("demuxer-max-bytes", "\(options.cacheMB)MiB"),
            ("demuxer-max-back-bytes", "\(max(32, options.cacheMB / 3))MiB"),
            ("demuxer-readahead-secs", "30"),
            ("network-timeout", "30"),
            ("stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=6"),
            ("alang", "\(options.audioLanguage),eng,en"),
            ("slang", "\(options.subtitleLanguage),eng,en"),
            ("subs-match-os-language", "yes"),
            ("subs-fallback", "yes"),
            ("sid", options.autoSubtitles ? "auto" : "no"),
            ("sub-auto", "fuzzy"),
            ("sub-scale", String(format: "%.2f", options.subtitleScale)),
            ("sub-font", "Helvetica Neue"),
            ("sub-border-size", "2.5"),
            ("sub-shadow-offset", "1"),
            ("sub-ass-override", "scale"),
            ("audio-file-auto", "no"),
            ("screenshot-directory", NSTemporaryDirectory()),
            ("user-agent", options.userAgent?.nilIfEmpty ?? "StreamForge/1.0 (mpv)"),
        ]
        for (k, v) in opts { mpv_set_option_string(mpv, k, v) }

        guard mpv_initialize(mpv) >= 0 else {
            mpv_terminate_destroy(mpv)
            handle = nil
            return
        }

        for (name, format) in Self.observed { mpv_observe_property(mpv, 0, name, format) }

        mpv_set_wakeup_callback(mpv, { ctx in
            guard let ctx else { return }
            let player = Unmanaged<MPVPlayer>.fromOpaque(ctx).takeUnretainedValue()
            player.readEvents()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit { shutdown() }

    func shutdown() {
        guard let mpv = handle else { return }
        handle = nil
        mpv_set_wakeup_callback(mpv, nil, nil)
        // Destroy on the event queue so it can never race an in-flight mpv_wait_event,
        // and never block: deinit may itself run on that queue.
        queue.async { mpv_terminate_destroy(mpv) }
    }

    // MARK: Commands

    func load(_ url: URL, start: Double? = nil, headers: [String: String] = [:], title: String? = nil, live: Bool = false) {
        guard let mpv = handle else { return }
        let headerValue = headers.map { "\($0.key): \($0.value)" }.joined(separator: ",")
        mpv_set_property_string(mpv, "http-header-fields", headerValue)
        mpv_set_property_string(mpv, "start", start.map { String(format: "%.2f", $0) } ?? "none")
        mpv_set_property_string(mpv, "force-media-title", title ?? "")
        // Live streams: small cache, no back-buffer, don't cache forever.
        mpv_set_property_string(mpv, "cache-secs", live ? "\(AppSettings.shared.values.liveBufferSeconds + 4)" : "3600")
        mpv_set_property_string(mpv, "demuxer-readahead-secs", live ? "\(AppSettings.shared.values.liveBufferSeconds)" : "30")
        mpv_set_property_string(mpv, "cache-pause-initial", live ? "yes" : "no")
        mpv_set_property_string(mpv, "cache-pause-wait", live ? "\(AppSettings.shared.values.liveBufferSeconds)" : "1")
        command("loadfile", url.absoluteString, "replace")
    }

    func command(_ args: String...) {
        guard let mpv = handle else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { for p in cargs where p != nil { free(UnsafeMutablePointer(mutating: p)) } }
        mpv_command_async(mpv, 0, &cargs)
    }

    func set(_ name: String, _ value: String) {
        guard let mpv = handle else { return }
        mpv_set_property_string(mpv, name, value)
    }

    func setFlag(_ name: String, _ value: Bool) {
        guard let mpv = handle else { return }
        var v: Int32 = value ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &v)
    }

    func setDouble(_ name: String, _ value: Double) {
        guard let mpv = handle else { return }
        var v = value
        mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &v)
    }

    func string(_ name: String) -> String? {
        guard let mpv = handle, let c = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(c) }
        return String(cString: c)
    }

    func double(_ name: String) -> Double? {
        guard let mpv = handle else { return nil }
        var v = Double()
        return mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &v) >= 0 ? v : nil
    }

    func int(_ name: String) -> Int? {
        guard let mpv = handle else { return nil }
        var v = Int64()
        return mpv_get_property(mpv, name, MPV_FORMAT_INT64, &v) >= 0 ? Int(v) : nil
    }

    func flag(_ name: String) -> Bool {
        guard let mpv = handle else { return false }
        var v = Int32()
        mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &v)
        return v != 0
    }

    func tracks() -> [MPVTrack] {
        let count = int("track-list/count") ?? 0
        return (0..<count).compactMap { i in
            let p = "track-list/\(i)/"
            guard let type = string(p + "type"), let kind = MPVTrack.Kind(rawValue: type), let id = int(p + "id") else { return nil }
            return MPVTrack(id: id, kind: kind, title: string(p + "title"), lang: string(p + "lang"), codec: string(p + "codec"),
                            isSelected: flag(p + "selected"), isExternal: flag(p + "external"),
                            channels: int(p + "demux-channel-count"), isDefault: flag(p + "default"))
        }
    }

    struct Chapter: Hashable { var title: String; var time: Double }

    func chapters() -> [Chapter] {
        let count = int("chapter-list/count") ?? 0
        return (0..<count).compactMap { i in
            guard let t = double("chapter-list/\(i)/time") else { return nil }
            return Chapter(title: string("chapter-list/\(i)/title") ?? "Chapter \(i + 1)", time: t)
        }
    }

    // MARK: Events

    private func readEvents() {
        queue.async { [weak self] in
            guard let self else { return }
            while let mpv = self.handle {
                guard let event = mpv_wait_event(mpv, 0) else { break }
                let id = event.pointee.event_id
                if id == MPV_EVENT_NONE { break }
                self.handle(event: event.pointee)
                if id == MPV_EVENT_SHUTDOWN { break }
            }
        }
    }

    private func handle(event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let ptr = event.data?.assumingMemoryBound(to: mpv_event_property.self) else { return }
            let prop = ptr.pointee
            let name = String(cString: prop.name)
            var value: Any?
            if let data = prop.data {
                switch prop.format {
                case MPV_FORMAT_DOUBLE: value = data.assumingMemoryBound(to: Double.self).pointee
                case MPV_FORMAT_FLAG: value = data.assumingMemoryBound(to: Int32.self).pointee != 0
                case MPV_FORMAT_INT64: value = Int(data.assumingMemoryBound(to: Int64.self).pointee)
                default: value = nil
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if name == "track-list/count" { self.delegate?.mpvTracksChanged() }
                self.delegate?.mpvPropertyChanged(name, value: value)
            }
        case MPV_EVENT_FILE_LOADED:
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.mpvFileLoaded()
                self?.delegate?.mpvTracksChanged()
            }
        case MPV_EVENT_END_FILE:
            guard let ptr = event.data?.assumingMemoryBound(to: mpv_event_end_file.self) else { return }
            let end = ptr.pointee
            var message: String?
            if end.reason == MPV_END_FILE_REASON_ERROR {
                message = String(cString: mpv_error_string(end.error))
            }
            let reason = end.reason
            DispatchQueue.main.async { [weak self] in
                if reason == MPV_END_FILE_REASON_ERROR || reason == MPV_END_FILE_REASON_EOF {
                    self?.delegate?.mpvEndFile(error: message)
                }
            }
        case MPV_EVENT_LOG_MESSAGE:
            #if DEBUG
            if let msg = event.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee {
                print("[mpv] \(String(cString: msg.prefix)): \(String(cString: msg.text))", terminator: "")
            }
            #endif
        default:
            break
        }
    }
}
