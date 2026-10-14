import Foundation
import Observation
import SwiftUI

/// Subtitle background rendering.
enum SubtitleBackground: String, Codable, CaseIterable, Identifiable {
    /// Classic outline + drop shadow.
    case outline
    /// A translucent box behind each line (libass BorderStyle 4, mpv `background-box`).
    case box
    var id: String { rawValue }
    var label: String { self == .outline ? "Outline" : "Background box" }
}

/// A small palette usable on both iOS and tvOS (tvOS has no ColorPicker).
enum SubtitleColor: String, Codable, CaseIterable, Identifiable {
    case white = "FFFFFF"
    case yellow = "FFE14D"
    case cyan = "4DE8FF"
    case green = "6BFF6B"
    case magenta = "FF6BE8"
    case red = "FF5A5A"
    case gray = "B4B4B4"
    case black = "000000"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .white: return "White"
        case .yellow: return "Yellow"
        case .cyan: return "Cyan"
        case .green: return "Green"
        case .magenta: return "Magenta"
        case .red: return "Red"
        case .gray: return "Gray"
        case .black: return "Black"
        }
    }

    var color: Color {
        let v = Int(rawValue, radix: 16) ?? 0xFFFFFF
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// mpv colour string `#AARRGGBB` (alpha 255 = opaque).
    func mpv(opacity: Double = 1) -> String {
        let a = Int((max(0, min(1, opacity)) * 255).rounded())
        return String(format: "#%02lX", a) + rawValue
    }
}

/// Fonts that ship with iOS and tvOS. libass resolves them through CoreText.
enum SubtitleFonts {
    static let all: [String] = [
        "Helvetica Neue", "Avenir Next", "Arial", "Verdana", "Trebuchet MS", "Gill Sans", "Futura", "Georgia", "Menlo",
    ]
}

/// Player-only preferences (kept out of AppSettings on purpose). Persisted to `player-prefs.json`.
@MainActor
@Observable
final class PlayerPreferences {
    static let shared = PlayerPreferences()

    struct Values: Codable, Equatable {
        // Skip intro / credits
        var showSkipButtons = true
        var autoSkipIntro = false
        var learnIntros = true
        var useAniSkip = true
        var nextEpisodeAtCredits = true

        // Subtitle style
        var subFont = "Helvetica Neue"
        var subBold = false
        var subColor: SubtitleColor = .white
        var subBorderColor: SubtitleColor = .black
        var subBorderSize: Double = 2.5
        var subShadow = true
        var subBackground: SubtitleBackground = .outline
        var subBackColor: SubtitleColor = .black
        var subBackOpacity: Double = 0.6
        /// mpv `sub-pos`: 100 = bottom edge, lower values move subtitles up.
        var subPosition: Int = 100
        var overrideASS = false

        // Audio
        var volume: Int = 100
        var nightMode = false
        var dialogueBoost = false

        // Display (tvOS)
        var matchDisplayCriteria = true

        // Live TV timeshift
        var timeshiftEnabled = true
        var timeshiftMinutes: Int = {
            #if os(tvOS)
            return 15
            #else
            return 30
            #endif
        }()
        var timeshiftMaxMB: Int = {
            #if os(tvOS)
            return 1024
            #else
            return 2048
            #endif
        }()

        // Picture in Picture (iOS fallback path)
        var pipFrameRate: Int = 20

        init() {}

        // Tolerant decoding: new keys added later never wipe the user's existing preferences.
        private enum CodingKeys: String, CodingKey {
            case showSkipButtons, autoSkipIntro, learnIntros, useAniSkip, nextEpisodeAtCredits
            case subFont, subBold, subColor, subBorderColor, subBorderSize, subShadow, subBackground, subBackColor, subBackOpacity
            case subPosition, overrideASS
            case volume, nightMode, dialogueBoost
            case matchDisplayCriteria
            case timeshiftEnabled, timeshiftMinutes, timeshiftMaxMB
            case pipFrameRate
        }

        init(from decoder: Decoder) throws {
            self.init()
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func v<T: Decodable>(_ key: CodingKeys, _ current: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? current }
            showSkipButtons = v(.showSkipButtons, showSkipButtons)
            autoSkipIntro = v(.autoSkipIntro, autoSkipIntro)
            learnIntros = v(.learnIntros, learnIntros)
            useAniSkip = v(.useAniSkip, useAniSkip)
            nextEpisodeAtCredits = v(.nextEpisodeAtCredits, nextEpisodeAtCredits)
            subFont = v(.subFont, subFont)
            subBold = v(.subBold, subBold)
            subColor = v(.subColor, subColor)
            subBorderColor = v(.subBorderColor, subBorderColor)
            subBorderSize = v(.subBorderSize, subBorderSize)
            subShadow = v(.subShadow, subShadow)
            subBackground = v(.subBackground, subBackground)
            subBackColor = v(.subBackColor, subBackColor)
            subBackOpacity = v(.subBackOpacity, subBackOpacity)
            subPosition = v(.subPosition, subPosition)
            overrideASS = v(.overrideASS, overrideASS)
            volume = v(.volume, volume)
            nightMode = v(.nightMode, nightMode)
            dialogueBoost = v(.dialogueBoost, dialogueBoost)
            matchDisplayCriteria = v(.matchDisplayCriteria, matchDisplayCriteria)
            timeshiftEnabled = v(.timeshiftEnabled, timeshiftEnabled)
            timeshiftMinutes = v(.timeshiftMinutes, timeshiftMinutes)
            timeshiftMaxMB = v(.timeshiftMaxMB, timeshiftMaxMB)
            pipFrameRate = v(.pipFrameRate, pipFrameRate)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(showSkipButtons, forKey: .showSkipButtons)
            try c.encode(autoSkipIntro, forKey: .autoSkipIntro)
            try c.encode(learnIntros, forKey: .learnIntros)
            try c.encode(useAniSkip, forKey: .useAniSkip)
            try c.encode(nextEpisodeAtCredits, forKey: .nextEpisodeAtCredits)
            try c.encode(subFont, forKey: .subFont)
            try c.encode(subBold, forKey: .subBold)
            try c.encode(subColor, forKey: .subColor)
            try c.encode(subBorderColor, forKey: .subBorderColor)
            try c.encode(subBorderSize, forKey: .subBorderSize)
            try c.encode(subShadow, forKey: .subShadow)
            try c.encode(subBackground, forKey: .subBackground)
            try c.encode(subBackColor, forKey: .subBackColor)
            try c.encode(subBackOpacity, forKey: .subBackOpacity)
            try c.encode(subPosition, forKey: .subPosition)
            try c.encode(overrideASS, forKey: .overrideASS)
            try c.encode(volume, forKey: .volume)
            try c.encode(nightMode, forKey: .nightMode)
            try c.encode(dialogueBoost, forKey: .dialogueBoost)
            try c.encode(matchDisplayCriteria, forKey: .matchDisplayCriteria)
            try c.encode(timeshiftEnabled, forKey: .timeshiftEnabled)
            try c.encode(timeshiftMinutes, forKey: .timeshiftMinutes)
            try c.encode(timeshiftMaxMB, forKey: .timeshiftMaxMB)
            try c.encode(pipFrameRate, forKey: .pipFrameRate)
        }

        // MARK: mpv mapping (pure, callable from any isolation domain)

        /// Subtitle style properties to push to mpv. `sub-scale` stays with AppSettings / the player model.
        var subtitleProperties: [(String, String)] {
            var props: [(String, String)] = [
                ("sub-font", subFont),
                ("sub-bold", subBold ? "yes" : "no"),
                ("sub-color", subColor.mpv()),
                ("sub-border-color", subBorderColor.mpv()),
                ("sub-border-size", String(format: "%.1f", subBorderSize)),
                ("sub-shadow-offset", subShadow && subBackground == .outline ? "1" : "0"),
                ("sub-pos", String(max(0, min(150, subPosition)))),
                ("sub-ass-override", overrideASS ? "force" : "scale"),
            ]
            switch subBackground {
            case .outline:
                props.append(("sub-border-style", "outline-and-shadow"))
                // Unused by the outline style in current mpv; older builds draw the shadow in this colour.
                props.append(("sub-back-color", "#C0000000"))
                props.append(("sub-shadow-color", "#C0000000"))
            case .box:
                props.append(("sub-border-style", "background-box"))
                props.append(("sub-back-color", subBackColor.mpv(opacity: subBackOpacity)))
            }
            return props
        }

        /// Timeshift buffer size in MiB, estimated at ~8 Mbit/s (1 MiB/s) and capped by the disk budget.
        var timeshiftMegabytes: Int { max(64, min(timeshiftMaxMB, timeshiftMinutes * 60)) }
    }

    /// The `af` chain for night mode / dialogue boost. Empty string clears all filters.
    nonisolated static func audioFilter(nightMode: Bool, dialogueBoost: Bool) -> String {
        var filters: [String] = []
        if dialogueBoost {
            // Lift the speech band, tame the rumble underneath it.
            filters.append("lavfi=[equalizer=f=2200:t=q:w=1.1:g=6,equalizer=f=120:t=q:w=0.8:g=-5]")
        }
        if nightMode {
            // Dynamic range compression: quiet parts up, explosions down.
            filters.append("lavfi=[acompressor=threshold=0.0625:ratio=6:attack=15:release=300:makeup=3]")
        }
        return filters.joined(separator: ",")
    }

    var values: Values {
        didSet { if values != oldValue { FileStore.save(values, "player-prefs.json", mirrorToDefaults: true) } }
    }

    private init() {
        values = FileStore.load(Values.self, "player-prefs.json") ?? Values()
    }
}
