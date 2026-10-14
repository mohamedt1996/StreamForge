import SwiftUI

/// Settings → Player → Advanced: skip markers, subtitle style, audio, live timeshift, display matching, PiP.
struct PlayerAdvancedSettingsView: View {
    @State private var prefs = PlayerPreferences.shared
    @State private var memory = IntroMemory.shared

    init() {}

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section {
                SubtitlePreview(values: prefs.values)
                    .listRowInsets(EdgeInsets())
                Picker("Font", selection: $prefs.values.subFont) {
                    ForEach(SubtitleFonts.all, id: \.self) { name in
                        Text(name).font(.custom(name, size: 17)).tag(name)
                    }
                }
                Toggle("Bold", isOn: $prefs.values.subBold)
                colorPicker("Text colour", selection: $prefs.values.subColor)
                Picker("Background", selection: $prefs.values.subBackground) {
                    ForEach(SubtitleBackground.allCases) { Text($0.label).tag($0) }
                }
                if prefs.values.subBackground == .box {
                    colorPicker("Box colour", selection: $prefs.values.subBackColor)
                    Picker("Box opacity", selection: $prefs.values.subBackOpacity) {
                        ForEach([0.25, 0.4, 0.6, 0.75, 0.9, 1.0], id: \.self) { v in
                            Text("\(Int(v * 100))%").tag(v)
                        }
                    }
                } else {
                    colorPicker("Outline colour", selection: $prefs.values.subBorderColor)
                    Picker("Outline size", selection: $prefs.values.subBorderSize) {
                        ForEach([0.0, 1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0], id: \.self) { v in
                            Text(v == 0 ? "None" : String(format: "%.1f", v)).tag(v)
                        }
                    }
                    Toggle("Drop shadow", isOn: $prefs.values.subShadow)
                }
                Picker("Position", selection: $prefs.values.subPosition) {
                    ForEach([100, 95, 90, 85, 80, 70, 60, 50], id: \.self) { v in
                        Text(v == 100 ? "Bottom" : "Raised \(100 - v)%").tag(v)
                    }
                }
                Toggle("Override embedded ASS styles", isOn: $prefs.values.overrideASS)
            } header: {
                Text("Subtitle style")
            } footer: {
                Text("Size is under Player → Subtitle size. Styled (ASS) subtitles keep their own look unless you override them. Changes apply immediately, also during playback.")
            }

            Section {
                Toggle("Show Skip Intro / Recap buttons", isOn: $prefs.values.showSkipButtons)
                Toggle("Skip intros automatically", isOn: $prefs.values.autoSkipIntro)
                Toggle("Learn intros when I skip them", isOn: $prefs.values.learnIntros)
                Toggle("Online markers (TheIntroDB)", isOn: $prefs.values.useIntroDB)
                Toggle("Anime timestamps (AniSkip)", isOn: $prefs.values.useAniSkip)
                Toggle("Show next episode when credits start", isOn: $prefs.values.nextEpisodeAtCredits)
                if memory.count > 0 {
                    Button(role: .destructive) { memory.forgetAll() } label: {
                        Text("Forget learned intros (\(memory.count))")
                    }
                }
                if memory.manualCount > 0 {
                    Button(role: .destructive) { memory.forgetAllManual() } label: {
                        Text("Clear manual markers (\(memory.manualCount) series)")
                    }
                }
            } header: {
                Text("Intros & credits")
            } footer: {
                Text("Markers come from TheIntroDB (by TMDB id), chapter names, AniSkip (for anime with Kitsu/MAL ids), markers you set yourself (player → Playback → Skip markers for this series) and from your own skips: jump 30 s–3 min forward early in an episode and the next episodes of that season will offer Skip Intro at the same spot.")
            }

            Section {
                Picker("Default volume", selection: $prefs.values.volume) {
                    ForEach(Array(stride(from: 50, through: 200, by: 10)), id: \.self) { v in
                        Text(v > 100 ? "\(v)% (boost)" : "\(v)%").tag(v)
                    }
                }
                Toggle("Night mode (compress loud scenes)", isOn: $prefs.values.nightMode)
                Toggle("Dialogue boost", isOn: $prefs.values.dialogueBoost)
            } header: {
                Text("Audio")
            } footer: {
                Text("Volume above 100% amplifies in software and can distort loud scenes. Night mode and dialogue boost can also be toggled per video in the player's Audio panel.")
            }

            Section {
                Toggle("Pause & rewind live TV", isOn: $prefs.values.timeshiftEnabled)
                if prefs.values.timeshiftEnabled {
                    Picker("Rewind window", selection: $prefs.values.timeshiftMinutes) {
                        ForEach([10, 15, 30, 60, 90, 120], id: \.self) { Text("\($0) minutes").tag($0) }
                    }
                    Picker("Maximum disk use", selection: $prefs.values.timeshiftMaxMB) {
                        ForEach([512, 1024, 2048, 4096, 8192], id: \.self) { mb in
                            Text(mb >= 1024 ? "\(mb / 1024) GB" : "\(mb) MB").tag(mb)
                        }
                    }
                }
            } header: {
                Text("Live TV")
            } footer: {
                Text("Live channels are buffered to a temporary file so you can pause and jump back (about 1 GB per 15 minutes of HD). The buffer is deleted when you leave the player.")
            }

            #if os(tvOS)
            Section {
                Toggle("Match frame rate & dynamic range", isOn: $prefs.values.matchDisplayCriteria)
            } header: {
                Text("Display")
            } footer: {
                Text("Switches your TV to the video's frame rate and HDR format. It also needs Settings → Video and Audio → Match Content turned on for your Apple TV.")
            }
            #endif

            #if os(iOS)
            Section {
                Picker("Frame rate for MKV / live PiP", selection: $prefs.values.pipFrameRate) {
                    ForEach([12, 15, 20, 24, 30], id: \.self) { Text("\($0) fps").tag($0) }
                }
            } header: {
                Text("Picture in Picture")
            } footer: {
                Text("MP4 and HLS sources move to the system player for Picture in Picture. Other formats (MKV, live TV) keep playing in mpv and are mirrored into the PiP window at this frame rate; higher values use more battery.")
            }
            #endif

            Section {
                Button("Reset to defaults") { prefs.values = PlayerPreferences.Values() }
            }
        }
        .hiddenListBackground()
        .screenBackground()
        .navigationTitle("Advanced Player")
    }

    private func colorPicker(_ title: String, selection: Binding<SubtitleColor>) -> some View {
        Picker(selection: selection) {
            ForEach(SubtitleColor.allCases) { c in
                Label {
                    Text(c.label)
                } icon: {
                    Image(systemName: "circle.fill").foregroundStyle(c.color)
                }
                .tag(c)
            }
        } label: {
            Text(title)
        }
    }
}

/// Approximates how mpv will draw subtitles with the current style.
struct SubtitlePreview: View {
    var values: PlayerPreferences.Values
    var sample = "The quick brown fox\njumps over the lazy dog."

    private var fontSize: CGFloat {
        #if os(tvOS)
        return 34
        #else
        return 19
        #endif
    }

    var body: some View {
        let scale = AppSettings.shared.values.subtitleScale
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(red: 0.25, green: 0.33, blue: 0.45), Color(red: 0.55, green: 0.47, blue: 0.36), Color(red: 0.12, green: 0.12, blue: 0.14)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            styledText(size: fontSize * scale)
                .padding(.bottom, bottomPadding)
                .padding(.horizontal, 12)
        }
        .frame(height: previewHeight)
        .frame(maxWidth: .infinity)
        .clipped()
        .accessibilityLabel("Subtitle preview")
    }

    private var previewHeight: CGFloat {
        #if os(tvOS)
        return 260
        #else
        return 150
        #endif
    }

    private var bottomPadding: CGFloat {
        let raised = CGFloat(100 - max(0, min(100, values.subPosition))) / 100
        return 10 + raised * (previewHeight - 60)
    }

    @ViewBuilder
    private func styledText(size: CGFloat) -> some View {
        let text = Text(sample)
            .font(.custom(values.subFont, size: size).weight(values.subBold ? .bold : .regular))
            .foregroundStyle(values.subColor.color)
            .multilineTextAlignment(.center)
        switch values.subBackground {
        case .box:
            text
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(values.subBackColor.color.opacity(values.subBackOpacity), in: RoundedRectangle(cornerRadius: 3))
        case .outline:
            let r = CGFloat(values.subBorderSize) * 0.45
            let border = values.subBorderColor.color
            text
                .shadow(color: values.subBorderSize > 0 ? border : .clear, radius: r)
                .shadow(color: values.subBorderSize > 0 ? border : .clear, radius: r)
                .shadow(color: values.subShadow ? .black.opacity(0.7) : .clear, radius: 0, x: 1.5, y: 1.5)
        }
    }
}
