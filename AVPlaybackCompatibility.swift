import Foundation

/// Decides whether a resolved stream URL can be handed to AVFoundation (AirPlay video, PiP hand-off).
/// AVPlayer only plays MP4/MOV/M4V files and HLS; MKV, MPEG-TS and raw IPTV streams stay with mpv.
enum AVPlaybackCompatibility {
    static let containerExtensions: Set<String> = ["mp4", "m4v", "mov", "m3u8"]

    /// AVPlayer on this device can play it (PiP hand-off).
    static func isAVPlayerCompatible(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else { return false }
        return containerExtensions.contains(url.pathExtension.lowercased())
    }

    /// An AirPlay receiver can fetch it directly. Loopback URLs (the embedded TorrServer) are only
    /// reachable from this device, so they don't qualify.
    static func isAirPlayCompatible(_ url: URL) -> Bool {
        guard isAVPlayerCompatible(url), url.scheme?.lowercased() != "file" else { return false }
        let host = (url.host ?? "").lowercased()
        return !(host == "localhost" || host == "::1" || host.hasPrefix("127."))
    }

    /// A short, honest reason shown when AirPlay video isn't possible.
    static func airPlayExplanation(for url: URL?) -> String {
        guard let url else {
            return "The stream hasn't started yet. Try again once it's playing."
        }
        let ext = url.pathExtension.lowercased()
        if isAVPlayerCompatible(url) && !isAirPlayCompatible(url) {
            return "This stream is served from inside the app (on-device torrent engine), so an AirPlay receiver can't reach it. You can still send the audio with the AirPlay audio button."
        }
        let kind = ext.isEmpty ? "live IPTV / MPEG-TS stream" : "\(ext.uppercased()) file"
        return "This is a \(kind). StreamForge decodes it with mpv, which can't send video over AirPlay — only MP4/MOV and HLS sources can. The AirPlay audio button still routes the sound to a speaker or Apple TV."
    }
}
