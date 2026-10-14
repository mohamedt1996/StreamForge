#if os(tvOS)
import AVKit
import AVFoundation
import CoreMedia
import UIKit

/// Frame-rate and dynamic-range matching on Apple TV (Settings → Video and Audio → Match Content).
/// Builds an AVDisplayCriteria from what mpv reports and hands it to the window's AVDisplayManager.
@MainActor
enum DisplayCriteriaMatcher {
    enum DynamicRange { case sdr, hdr10, hlg, dolbyVision }

    struct VideoInfo {
        var width: Int
        var height: Int
        var fps: Double
        var range: DynamicRange
    }

    static func videoInfo(from player: MPVPlayer) -> VideoInfo? {
        guard let w = player.int("video-params/w"), let h = player.int("video-params/h"), w > 0, h > 0 else { return nil }
        let fps = [player.double("container-fps"), player.double("estimated-vf-fps")]
            .compactMap { $0 }.first { $0 > 1 && $0 < 121 } ?? 0
        let gamma = (player.string("video-params/gamma") ?? "").lowercased()
        let dvProfile = player.int("current-tracks/video/dolby-vision-profile") ?? 0
        let range: DynamicRange
        if dvProfile > 0 && gamma == "pq" { range = .dolbyVision }
        else if gamma == "pq" { range = .hdr10 }
        else if gamma == "hlg" { range = .hlg }
        else { range = .sdr }
        return VideoInfo(width: w, height: h, fps: fps, range: range)
    }

    static func formatDescription(for info: VideoInfo) -> CMVideoFormatDescription? {
        let codec: CMVideoCodecType
        var ext: [String: Any] = [:]
        switch info.range {
        case .sdr:
            codec = kCMVideoCodecType_H264
            ext[kCMFormatDescriptionExtension_ColorPrimaries as String] = kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String
            ext[kCMFormatDescriptionExtension_TransferFunction as String] = kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String
            ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String
        case .hdr10, .hlg, .dolbyVision:
            // 'dvh1' signals Dolby Vision; plain HEVC + PQ/HLG signals HDR10/HLG.
            codec = info.range == .dolbyVision ? 0x6476_6831 : kCMVideoCodecType_HEVC
            ext[kCMFormatDescriptionExtension_ColorPrimaries as String] = kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String
            ext[kCMFormatDescriptionExtension_TransferFunction as String] = (info.range == .hlg
                ? kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
                : kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ) as String
            ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String
        }
        var desc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: codec,
                                                    width: Int32(info.width), height: Int32(info.height),
                                                    extensions: ext as CFDictionary, formatDescriptionOut: &desc)
        return status == noErr ? desc : nil
    }

    /// Returns the display manager it changed (to reset later), or nil if nothing was applied.
    static func apply(_ info: VideoInfo, window: UIWindow?) -> AVDisplayManager? {
        guard let manager = window?.avDisplayManager, manager.isDisplayCriteriaMatchingEnabled,
              let desc = formatDescription(for: info) else { return nil }
        let refresh = Float(info.fps > 1 ? info.fps : 60)
        manager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: refresh, formatDescription: desc)
        return manager
    }

    static func reset(_ manager: AVDisplayManager?) {
        manager?.preferredDisplayCriteria = nil
    }
}

extension PlayerModel {
    /// Called when a file loads: waits for mpv's video parameters, then asks the TV to switch modes.
    func scheduleDisplayCriteriaMatch() {
        displayCriteriaTask?.cancel()
        guard PlayerPreferences.shared.values.matchDisplayCriteria else { return }
        displayCriteriaTask = Task { [weak self] in
            for attempt in 0..<25 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, !Task.isCancelled else { return }
                if let info = DisplayCriteriaMatcher.videoInfo(from: self.player) {
                    // container-fps can arrive a moment after the first frame.
                    if info.fps <= 1 && attempt < 24 { continue }
                    if let manager = DisplayCriteriaMatcher.apply(info, window: self.player.view.window) {
                        self.displayCriteriaStorage = manager
                    }
                    return
                }
            }
        }
    }

    func resetDisplayCriteria() {
        displayCriteriaTask?.cancel()
        displayCriteriaTask = nil
        DisplayCriteriaMatcher.reset(displayCriteriaStorage as? AVDisplayManager)
        displayCriteriaStorage = nil
    }
}
#endif
