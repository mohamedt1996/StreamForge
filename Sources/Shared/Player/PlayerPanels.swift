import SwiftUI

/// The slide-in side panels: audio, subtitles, playback settings, channels, chapters.
extension PlayerScreen {
    @ViewBuilder
    func panelView(_ panel: PlayerPanel) -> some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(panelTitle(panel)).font(.headline)
                    Spacer()
                    Button { self.panel = nil } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                        .buttonStyle(.plain)
                }
                .padding(16)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        switch panel {
                        case .audio: audioPanel
                        case .subtitles: subtitlePanel
                        case .settings: settingsPanel
                        case .channels: channelPanel
                        case .chapters: chapterPanel
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 20)
                }
            }
            .frame(width: panelWidth)
            .frame(maxHeight: .infinity)
            .background(.ultraThinMaterial)
        }
        .ignoresSafeArea()
    }

    var panelWidth: CGFloat {
        #if os(tvOS)
        return 640
        #else
        return min(380, UIScreen.main.bounds.width * 0.9)
        #endif
    }

    func panelTitle(_ p: PlayerPanel) -> String {
        switch p {
        case .audio: return "Audio"
        case .subtitles: return "Subtitles"
        case .settings: return "Playback"
        case .channels: return "Channels"
        case .chapters: return "Chapters"
        }
    }

    func optionRow(_ title: String, subtitle: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(selected ? .bold : .regular)).multilineTextAlignment(.leading)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.6)) }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }
            .padding(.vertical, 10).padding(.horizontal, 10)
            .background(selected ? Theme.surfaceHigh : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A toggle row that reads like `optionRow` (works with the tvOS focus engine).
    func toggleRow(_ title: String, subtitle: String? = nil, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.6)) }
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Theme.accent : .white.opacity(0.5))
            }
            .padding(.vertical, 10).padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Audio

    @ViewBuilder var audioPanel: some View {
        if model.audioTracks.isEmpty { Text("No audio tracks").foregroundStyle(.secondary).padding() }
        ForEach(model.audioTracks) { t in
            optionRow(t.displayName, selected: t.isSelected) { model.selectAudio(t) }
        }
        sectionLabel("Volume")
        valueRow("\(model.volume)%" + (model.volume > 100 ? " boost" : "")) {
            model.changeVolume(by: -10)
        } plus: {
            model.changeVolume(by: 10)
        }
        sectionLabel("Sound")
        toggleRow("Night mode", subtitle: "Softens loud scenes, lifts quiet ones", isOn: model.nightMode) {
            model.nightMode.toggle()
        }
        toggleRow("Dialogue boost", subtitle: "Makes voices clearer", isOn: model.dialogueBoost) {
            model.dialogueBoost.toggle()
        }
        sectionLabel("Audio delay")
        stepperRow(value: model.audioDelay, unit: "s", step: 0.1) { model.audioDelay = $0 }
        if model.videoTracks.count > 1 {
            sectionLabel("Video")
            ForEach(model.videoTracks) { t in optionRow(t.displayName, selected: t.isSelected) { model.selectVideo(t) } }
        }
    }

    // MARK: Subtitles

    @ViewBuilder var subtitlePanel: some View {
        optionRow("Off", selected: !model.subtitleTracks.contains { $0.isSelected }) { model.selectSubtitle(nil) }
        ForEach(model.subtitleTracks) { t in
            optionRow(t.displayName, selected: t.isSelected) { model.selectSubtitle(t) }
        }
        if !model.addonSubtitles.isEmpty {
            sectionLabel("From addons")
            ForEach(model.addonSubtitles.prefix(60)) { s in
                optionRow(s.languageName, subtitle: model.loadedAddonSubtitleIDs.contains(s.id) ? "Loaded" : s.url.host,
                          selected: false) { model.loadAddonSubtitle(s) }
            }
        }
        sectionLabel("Timing")
        stepperRow(value: model.subtitleDelay, unit: "s", step: 0.25) { model.subtitleDelay = $0 }
        sectionLabel("Size")
        stepperRow(value: model.subtitleScale, unit: "×", step: 0.1) { model.subtitleScale = max(0.4, min(3, $0)) }
        subtitleStyleSection
    }

    @ViewBuilder var subtitleStyleSection: some View {
        let prefs = PlayerPreferences.shared
        let v = prefs.values
        sectionLabel("Style")
        valueRow(v.subPosition >= 100 ? "Position: bottom" : "Position: raised \(100 - v.subPosition)%") {
            prefs.values.subPosition = min(100, v.subPosition + 5)
        } plus: {
            prefs.values.subPosition = max(40, v.subPosition - 5)
        }
        optionRow("Text colour", subtitle: v.subColor.label, selected: false) {
            let all = SubtitleColor.allCases.filter { $0 != .black }
            let i = all.firstIndex(of: v.subColor) ?? 0
            prefs.values.subColor = all[(i + 1) % all.count]
        }
        toggleRow("Background box", isOn: v.subBackground == .box) {
            prefs.values.subBackground = v.subBackground == .box ? .outline : .box
        }
        toggleRow("Bold", isOn: v.subBold) { prefs.values.subBold.toggle() }
        toggleRow("Override styled (ASS) subtitles", isOn: v.overrideASS) { prefs.values.overrideASS.toggle() }
        Text("More in Settings → Player → Advanced.")
            .font(.caption).foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 10).padding(.top, 6)
    }

    // MARK: Playback settings

    @ViewBuilder var settingsPanel: some View {
        sectionLabel("Speed")
        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { s in
            optionRow(s == 1 ? "Normal" : String(format: "%.2g×", s), selected: abs(model.speed - s) < 0.01) { model.setSpeed(s) }
        }
        .disabled(model.isLive)
        sectionLabel("Video")
        ForEach(VideoFit.allCases, id: \.self) { f in
            optionRow(f.label, selected: model.fit == f) { model.setFit(f) }
        }
        if !model.isLive {
            sectionLabel("Intros")
            toggleRow("Skip intros automatically", isOn: PlayerPreferences.shared.values.autoSkipIntro) {
                PlayerPreferences.shared.values.autoSkipIntro.toggle()
            }
        }
        if model.markerSeriesID != nil {
            let manual = model.manualMarkers
            let introSubtitle: String? = markerIntroSubtitle(pending: model.pendingIntroStart, manual: manual)
            sectionLabel("Skip markers for this series")
            optionRow(model.pendingIntroStart == nil ? "Mark intro start here" : "Re-mark intro start here",
                      subtitle: introSubtitle, selected: false) { model.markIntroStart() }
            optionRow("Mark intro end here",
                      subtitle: model.pendingIntroStart == nil ? "Uses 0:00 as the start if none is marked" : "At \(model.position.clockText)",
                      selected: false) { model.markIntroEnd() }
            optionRow("Mark credits start here",
                      subtitle: manual?.creditsFromEnd.map { "Saved: \($0.clockText) before the end" },
                      selected: false) { model.markCreditsStart() }
            if manual != nil {
                optionRow("Clear this series' markers", selected: false) { model.clearManualMarkers() }
            }
        }
        if model.isLive && model.timeshiftActive {
            sectionLabel("Live")
            optionRow("Jump to live", subtitle: model.behindLive > 3 ? "−\(model.behindLive.clockText) behind" : "You're live",
                      selected: false) { model.goLive() }
        }
        sectionLabel("Info")
        optionRow("Show statistics", selected: model.showStats) { model.showStats.toggle() }
        optionRow("Source: \(request.source.provider)", subtitle: request.source.title, selected: false) {}
    }

    func markerIntroSubtitle(pending: Double?, manual: IntroMemory.Manual?) -> String? {
        if let pending { return "Start set at \(pending.clockText)" }
        guard let start = manual?.introStart, let end = manual?.introEnd else { return nil }
        return "Saved: \(start.clockText)–\(end.clockText)"
    }

    // MARK: Channels

    @ViewBuilder var channelPanel: some View {
        let list = model.request.channelList
        if let prev = model.previousChannel {
            optionRow("Last channel: \(prev.name)", selected: false) {
                model.toggleLastChannel()
                panel = nil
            }
        }
        ForEach(list) { ch in
            Button {
                model.switchChannel(ch)
                panel = nil
            } label: {
                HStack(spacing: 10) {
                    if let n = ch.number { Text("\(n)").font(.caption.monospacedDigit()).frame(width: 34) }
                    ChannelLogo(url: ch.icon, name: ch.name, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ch.name).font(.subheadline.weight(ch.id == model.request.channelID ? .bold : .regular)).lineLimit(1)
                        if let now = DispatcharrStore.shared.nowPlaying(ch.id) {
                            Text(now.title).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                    }
                    Spacer()
                    if ch.id == model.request.channelID { Image(systemName: "speaker.wave.2.fill").foregroundStyle(Theme.accent) }
                }
                .padding(8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Chapters

    @ViewBuilder var chapterPanel: some View {
        ForEach(Array(model.chapters.enumerated()), id: \.offset) { _, c in
            optionRow(c.title, subtitle: c.time.clockText, selected: chapterTitle(at: model.position) == c.title && (model.chapters.last { $0.time <= model.position }?.time == c.time)) {
                model.jumpToChapter(c)
            }
        }
    }

    // MARK: Helpers

    func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.5))
            .padding(.top, 14).padding(.horizontal, 10)
    }

    func stepperRow(value: Double, unit: String, step: Double, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Button { set(value - step) } label: { Image(systemName: "minus.circle.fill").font(.title2) }.buttonStyle(.plain)
            Spacer()
            Text(String(format: "%+.2f%@", value, unit)).font(.body.monospacedDigit())
            Spacer()
            Button { set(value + step) } label: { Image(systemName: "plus.circle.fill").font(.title2) }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    /// − value + row with a free-form label.
    func valueRow(_ text: String, minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        HStack {
            Button(action: minus) { Image(systemName: "minus.circle.fill").font(.title2) }.buttonStyle(.plain)
            Spacer()
            Text(text).font(.body.monospacedDigit())
            Spacer()
            Button(action: plus) { Image(systemName: "plus.circle.fill").font(.title2) }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }
}
