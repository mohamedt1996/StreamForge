import SwiftUI

/// Buffering/error states, skip button, next-episode card, stats, and live-TV number entry.
extension PlayerScreen {
    var bufferingOverlay: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large).tint(.white)
            if let status = model.statusText {
                Text(status).font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.8))
            } else if let pct = model.bufferPercent, pct > 0, pct < 100 {
                Text("Buffering \(pct)%").font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(24)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
        .allowsHitTesting(false)
    }

    func errorOverlay(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 42)).foregroundStyle(Theme.gold)
            Text("Can't play this").font(.title3.weight(.bold))
            Text(error).font(.subheadline).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center).frame(maxWidth: 520)
            HStack(spacing: 14) {
                Button("Close") { close() }.buttonStyle(.bordered)
                Button("Try Again") { model.retry() }.buttonStyle(.borderedProminent).tint(Theme.accent)
                if model.isLive {
                    Button("Next Channel") { model.zap(1) }.buttonStyle(.bordered)
                }
            }
        }
        .padding(30)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding()
    }

    func feedbackBubble(_ text: String) -> some View {
        Text(text)
            .font(.title3.weight(.bold))
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .allowsHitTesting(false)
    }

    // MARK: Skip intro / recap / credits

    func skipButton(_ segment: SkipSegment) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    model.skip(segment)
                    if controlsVisible { scheduleHide() }
                } label: {
                    Label(segment.buttonTitle, systemImage: "forward.end.fill")
                        .font(.headline)
                        #if os(iOS)
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 1))
                        #endif
                }
                #if os(tvOS)
                .buttonStyle(.bordered)
                #else
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                #endif
            }
        }
        .padding(.horizontal, edgePadding)
        .padding(.bottom, controlsVisible ? skipBottomPaddingWithControls : 40)
    }

    private var skipBottomPaddingWithControls: CGFloat {
        #if os(tvOS)
        return 190
        #else
        return 130
        #endif
    }

    // MARK: Next episode

    func nextEpisodeCard(_ next: EpisodeRef) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 12) {
                    RemoteImage(url: next.still ?? request.item.backdrop)
                        .frame(width: 120, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.remaining < 35 ? "Up next in \(Int(model.remaining))s" : "Up next")
                            .font(.caption).foregroundStyle(.white.opacity(0.7))
                        Text("\(next.code) · \(next.title)").font(.subheadline.weight(.semibold)).lineLimit(2)
                        Button("Play Now") { model.playNextEpisode() }
                            .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
                    }
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .padding(.horizontal, edgePadding)
        .padding(.bottom, controlsVisible ? 130 : 30)
    }

    // MARK: Stats

    var statsOverlay: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.stats, id: \.0) { row in
                        HStack(spacing: 8) {
                            Text(row.0).foregroundStyle(.white.opacity(0.6)).frame(width: 110, alignment: .leading)
                            Text(row.1)
                        }
                    }
                    if model.stats.isEmpty { Text("Collecting…") }
                }
                .font(.caption.monospaced())
                .padding(12)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                Spacer()
            }
            Spacer()
        }
        .padding(.top, 80)
        .padding(.horizontal, edgePadding)
        .allowsHitTesting(false)
    }

    // MARK: Channel number entry

    var digitsText: String {
        let shown = model.channelDigits.map { String($0) }.joined(separator: " ")
        return model.channelDigits.count < 4 ? shown + " _" : shown
    }

    /// "Channel 1 2 _" badge while digits are being typed (hardware keys / remote).
    var channelEntryBadge: some View {
        VStack {
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Channel \(digitsText)")
                        .font(.title2.monospacedDigit().weight(.bold))
                    if let ch = model.digitPreview {
                        Text(ch.name).font(.subheadline).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            Spacer()
        }
        .padding(.top, 30)
        .padding(.horizontal, edgePadding)
        .allowsHitTesting(false)
    }

    /// On-screen number pad for tuning by channel number.
    var numberPadOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture { showNumberPad = false; model.cancelDigits() }
            VStack(spacing: padSpacing) {
                VStack(spacing: 4) {
                    Text(model.channelDigits.isEmpty ? "Enter a channel number" : "Channel \(digitsText)")
                        .font(.title3.monospacedDigit().weight(.bold))
                    Text(model.digitPreview?.name ?? (model.channelDigits.isEmpty ? " " : "No match yet"))
                        .font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                .frame(minWidth: padKeySize * 3 + padSpacing * 2)
                ForEach([[1, 2, 3], [4, 5, 6], [7, 8, 9]], id: \.self) { row in
                    HStack(spacing: padSpacing) {
                        ForEach(row, id: \.self) { d in padKey("\(d)") { model.enterDigit(d) } }
                    }
                }
                HStack(spacing: padSpacing) {
                    padKey("delete.left", isSymbol: true) { model.deleteDigit() }
                    padKey("0") { model.enterDigit(0) }
                    padKey("checkmark", isSymbol: true) {
                        model.commitDigits()
                        showNumberPad = false
                    }
                }
                if model.previousChannel != nil {
                    Button {
                        showNumberPad = false
                        model.toggleLastChannel()
                    } label: {
                        Label("Last channel" + (model.previousChannel.map { " · \($0.name)" } ?? ""), systemImage: "arrow.uturn.backward")
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                    }
                    #if os(tvOS)
                    .buttonStyle(.bordered)
                    #else
                    .buttonStyle(.bordered)
                    .tint(.white)
                    #endif
                }
            }
            .padding(padSpacing * 1.5)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    private var padKeySize: CGFloat {
        #if os(tvOS)
        return 110
        #else
        return 64
        #endif
    }

    private var padSpacing: CGFloat {
        #if os(tvOS)
        return 22
        #else
        return 12
        #endif
    }

    private func padKey(_ text: String, isSymbol: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if isSymbol { Image(systemName: text) } else { Text(text) }
            }
            .font(.title2.monospacedDigit().weight(.semibold))
            .frame(width: padKeySize, height: padKeySize * 0.72)
            #if os(iOS)
            .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            #endif
        }
        #if os(tvOS)
        .buttonStyle(.bordered)
        #else
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        #endif
    }
}

/// Stremio-style start screen: the title's artwork drifts and zooms slowly behind its logo or
/// name while the stream (often a torrent) connects and buffers.
struct LoadingArtworkView: View {
    let request: PlaybackRequest
    var status: String?
    @State private var drift = false
    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                RemoteImage(url: request.episode?.still ?? request.item.backdrop ?? request.item.poster)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(drift ? 1.18 : 1.02)
                    .offset(x: drift ? -geo.size.width * 0.04 : geo.size.width * 0.03,
                            y: drift ? -geo.size.height * 0.02 : geo.size.height * 0.02)
                    .clipped()
                    .opacity(0.55)
                LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.45), .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 18) {
                    Spacer()
                    if let logo = request.item.logo {
                        RemoteImage(url: logo, contentMode: .fit)
                            .frame(maxWidth: min(geo.size.width * 0.6, 520), maxHeight: 140)
                            .opacity(pulse ? 1 : 0.75)
                    } else {
                        Text(request.item.title)
                            .font(.system(size: 34, weight: .heavy))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .opacity(pulse ? 1 : 0.8)
                    }
                    if let ep = request.episode {
                        Text("\(ep.code) · \(ep.title)").font(.headline).foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer()
                    HStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text(status ?? "Starting…").font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                            .contentTransition(.opacity)
                    }
                    .padding(.bottom, 48)
                }
                .padding(.horizontal, 32)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 18).repeatForever(autoreverses: true)) { drift = true }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
