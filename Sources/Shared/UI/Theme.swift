import SwiftUI
import NukeUI
import Nuke

enum Theme {
    static let background = Color(red: 0.03, green: 0.027, blue: 0.07)
    static let surface = Color(white: 1, opacity: 0.06)
    static let surfaceHigh = Color(white: 1, opacity: 0.11)
    static let accent = Color(red: 0.55, green: 0.36, blue: 0.96)
    static let accent2 = Color(red: 0.93, green: 0.28, blue: 0.60)
    static let live = Color(red: 0.96, green: 0.26, blue: 0.30)
    static let gold = Color(red: 0.98, green: 0.78, blue: 0.25)
    static let secondaryText = Color.white.opacity(0.62)

    static let accentGradient = LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)

    #if os(tvOS)
    static let posterWidth: CGFloat = 220
    static let landscapeWidth: CGFloat = 420
    static let gutter: CGFloat = 80
    static let rowSpacing: CGFloat = 48
    #else
    static var posterWidth: CGFloat { UIDevice.current.userInterfaceIdiom == .pad ? 150 : 112 }
    static var landscapeWidth: CGFloat { UIDevice.current.userInterfaceIdiom == .pad ? 320 : 250 }
    static let gutter: CGFloat = 16
    static let rowSpacing: CGFloat = 26
    #endif

    static var posterHeight: CGFloat { posterWidth * 1.5 }
}

/// Image view backed by Nuke's disk + memory cache, with a tasteful placeholder.
struct RemoteImage: View {
    var url: URL?
    var contentMode: ContentMode = .fill
    var placeholderSymbol: String = "film"
    var placeholderText: String?

    var body: some View {
        LazyImage(url: url) { state in
            if let image = state.image {
                image.resizable().aspectRatio(contentMode: contentMode)
            } else {
                ZStack {
                    LinearGradient(colors: [Theme.surfaceHigh, Theme.surface], startPoint: .top, endPoint: .bottom)
                    VStack(spacing: 6) {
                        Image(systemName: placeholderSymbol).font(.title2).foregroundStyle(.white.opacity(0.25))
                        if let placeholderText {
                            Text(placeholderText)
                                .font(.caption.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(3)
                                .padding(.horizontal, 8)
                        }
                    }
                }
                .redacted(reason: state.isLoading ? .placeholder : [])
            }
        }
        .pipeline(ImagePipeline.shared)
    }
}

enum ImagePipelineSetup {
    static func configure() {
        var config = ImagePipeline.Configuration.withDataCache(name: "streamforge.images", sizeLimit: 600 * 1024 * 1024)
        config.isProgressiveDecodingEnabled = false
        ImagePipeline.shared = ImagePipeline(configuration: config)
    }
}

// MARK: - Small components

struct Pill: View {
    var text: String
    var color: Color = Theme.surfaceHigh
    var foreground: Color = .white
    var icon: String?

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.caption2.weight(.bold))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .foregroundStyle(foreground)
    }
}

struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(.white).frame(width: 6, height: 6)
            Text("LIVE")
        }
        .font(.caption2.weight(.heavy))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Theme.live, in: Capsule())
        .foregroundStyle(.white)
    }
}

struct RatingView: View {
    var rating: Double
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill").foregroundStyle(Theme.gold)
            Text(String(format: "%.1f", rating))
        }
        .font(.caption.weight(.semibold))
    }
}

struct ProgressLine: View {
    var fraction: Double
    var height: CGFloat = 3
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(Theme.accentGradient).frame(width: geo.size.width * max(0, min(1, fraction)))
            }
        }
        .frame(height: height)
    }
}

struct SectionHeader: View {
    var title: String
    var subtitle: String?
    var action: (() -> Void)?
    var actionLabel = "See All"

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.bold))
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Theme.secondaryText) }
            }
            Spacer()
            if let action {
                Button(actionLabel, action: action)
                    .font(.subheadline.weight(.semibold))
                    #if os(tvOS)
                    .buttonStyle(.plain)
                    #endif
            }
        }
        .padding(.horizontal, Theme.gutter)
    }
}

struct EmptyStateView: View {
    var icon: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Theme.accentGradient)
            Text(title).font(.title3.weight(.bold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle).font(.headline).padding(.horizontal, 20).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .padding(.top, 6)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LoadingView: View {
    var text: String = "Loading…"
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(.white)
            Text(text).font(.subheadline).foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Card button style: lifts on tvOS focus, dims slightly on iOS press.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension View {
    /// Platform-appropriate style for poster/landscape cards.
    @ViewBuilder func cardButtonStyle() -> some View {
        #if os(tvOS)
        self.buttonStyle(.card)
        #else
        self.buttonStyle(CardButtonStyle())
        #endif
    }

    /// Lets the app background show through lists (tvOS lists have no background to hide).
    @ViewBuilder func hiddenListBackground() -> some View {
        #if os(tvOS)
        self
        #else
        self.scrollContentBackground(.hidden)
        #endif
    }

    func screenBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }
}
