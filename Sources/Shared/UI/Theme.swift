import SwiftUI
import NukeUI
import Nuke

enum Theme {
    static let background = Color(red: 0.045, green: 0.05, blue: 0.065)
    static let surface = Color(white: 1, opacity: 0.06)
    static let surfaceHigh = Color(white: 1, opacity: 0.11)
    static let accent = Color(red: 0.55, green: 0.36, blue: 0.96)
    static let accent2 = accent
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

// MARK: - Device

/// What the app is running on. Detected once from the hardware model identifier
/// ("iPhone16,1"; the simulator reports the model it simulates), with the live safe area as
/// a fallback for phones newer than this table. Layout uses it to size the hero and title
/// and to keep trailers clear of the Dynamic Island / notch.
struct DeviceProfile: Equatable {
    enum Kind: Equatable {
        /// iPhone 14 Pro and later Dynamic Island models.
        case phoneDynamicIsland
        /// iPhone X – 14 and 16e.
        case phoneNotch
        /// Touch ID phones (SE, 8 and earlier).
        case phoneHomeButton
        case pad
        /// An iPhone/iPad build running on a Mac.
        case mac
        case tv
    }

    let kind: Kind
    /// Hardware identifier, e.g. "iPhone17,1" (empty when unavailable).
    let model: String
    /// Portrait screen size in points.
    let screen: CGSize

    @MainActor static let current = DeviceProfile.detect()

    var isPhone: Bool { [.phoneDynamicIsland, .phoneNotch, .phoneHomeButton].contains(kind) }
    var hasDynamicIsland: Bool { kind == .phoneDynamicIsland }
    /// Plus / Pro Max / Air-sized phones.
    var isLargePhone: Bool { isPhone && screen.width >= 428 }
    /// SE / mini-sized phones.
    var isSmallPhone: Bool { isPhone && (kind == .phoneHomeButton || screen.height <= 812) }

    /// Portrait height to keep video and overlays below: the Dynamic Island ends ~48 pt down
    /// (its safe area is 59–62 pt), a notch at ~30 pt (44–50 pt safe area).
    var minimumTopClearance: CGFloat {
        switch kind {
        case .phoneDynamicIsland: return 59
        case .phoneNotch: return 44
        case .phoneHomeButton: return 20
        case .pad, .mac: return 24
        case .tv: return 0
        }
    }

    /// Top inset for something drawn edge to edge under the status bar. `safeTop` is the live
    /// inset (0 in landscape, where the island/notch sits on the side and the horizontal safe
    /// area already keeps content clear of it).
    func topClearance(safeTop: CGFloat, isLandscape: Bool) -> CGFloat {
        guard !isLandscape, kind != .tv else { return max(0, safeTop) }
        return max(safeTop, minimumTopClearance)
    }

    /// Refines an unknown phone once a real safe area is known (portrait top inset).
    func refined(withPortraitSafeTop top: CGFloat) -> DeviceProfile {
        guard isPhone, Self.phoneKind(for: model) == nil, top > 0 else { return self }
        let kind: Kind = top >= 55 ? .phoneDynamicIsland : top >= 40 ? .phoneNotch : .phoneHomeButton
        return DeviceProfile(kind: kind, model: model, screen: screen)
    }

    @MainActor private static func detect() -> DeviceProfile {
        let model = hardwareModel()
        #if os(tvOS)
        return DeviceProfile(kind: .tv, model: model, screen: UIScreen.main.bounds.size)
        #else
        let bounds = UIScreen.main.bounds.size
        let screen = CGSize(width: min(bounds.width, bounds.height), height: max(bounds.width, bounds.height))
        if ProcessInfo.processInfo.isiOSAppOnMac || ProcessInfo.processInfo.isMacCatalystApp {
            return DeviceProfile(kind: .mac, model: model, screen: screen)
        }
        if UIDevice.current.userInterfaceIdiom != .phone {
            return DeviceProfile(kind: .pad, model: model, screen: screen)
        }
        if let kind = phoneKind(for: model) {
            return DeviceProfile(kind: kind, model: model, screen: screen)
        }
        // Unknown (newer) phone: every iPhone since the 14 Pro line has the Dynamic Island;
        // `refined(withPortraitSafeTop:)` corrects this from the real safe area.
        return DeviceProfile(kind: .phoneDynamicIsland, model: model, screen: screen)
        #endif
    }

    /// Known iPhone identifiers → kind; nil for unknown models.
    static func phoneKind(for model: String) -> Kind? {
        guard model.hasPrefix("iPhone") else { return nil }
        let numbers = model.dropFirst("iPhone".count).split(separator: ",").compactMap { Int($0) }
        guard numbers.count == 2 else { return nil }
        let (major, minor) = (numbers[0], numbers[1])
        switch (major, minor) {
        case (10, 3), (10, 6): return .phoneNotch                       // X
        case (...10, _): return .phoneHomeButton                        // 8 and earlier
        case (12, 8), (14, 6): return .phoneHomeButton                  // SE 2nd / 3rd gen
        case (11, _), (12, _), (13, _), (14, _): return .phoneNotch     // XS – 14 (incl. 13 mini)
        case (15, 2), (15, 3): return .phoneDynamicIsland               // 14 Pro / Pro Max
        case (15, _): return .phoneDynamicIsland                        // 15 / 15 Plus (15,4 / 15,5)
        case (16, _): return .phoneDynamicIsland                        // 15 Pro / Pro Max
        case (17, 5): return .phoneNotch                                // 16e
        case (17, _): return .phoneDynamicIsland                        // 16 / Plus / Pro / Pro Max
        case (18, 1), (18, 2), (18, 3), (18, 4): return .phoneDynamicIsland // 17 / Air / 17 Pro / Pro Max
        default: return nil
        }
    }

    private static func hardwareModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

// MARK: - Title shadow

extension View {
    /// Soft dark halo behind title logos and text, like Stremio's: a wide, low-opacity glow
    /// for separation from bright artwork plus a tight contact shadow for crisp edges. Drawn
    /// once on the flattened title (compositingGroup), so it follows the logo's transparency.
    func titleShadow(_ strength: Double = 1) -> some View {
        self
            .compositingGroup()
            .shadow(color: .black.opacity(0.55 * strength), radius: 18, x: 0, y: 0)
            .shadow(color: .black.opacity(0.45 * strength), radius: 3, x: 0, y: 1)
    }

    /// Lighter version for the meta row and chips under the title.
    func metaShadow() -> some View {
        shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 1)
    }
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
                if contentMode == .fill {
                    // A filled image reports its own (wider) size and would stretch its parent past
                    // the screen; Color.clear takes exactly the offered size and the image only overlays it.
                    Color.clear
                        .overlay { image.resizable().aspectRatio(contentMode: .fill) }
                        .clipped()
                } else {
                    image.resizable().aspectRatio(contentMode: contentMode)
                }
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

/// Stremio-style title: the studio logo, left-aligned in a fixed box, with the title in bold
/// type underneath until (or unless) the logo arrives.
///
/// Kept snappy on purpose:
/// - the box never changes size, so nothing below it jumps when the logo loads;
/// - the logo is decoded at display size (studio PNGs are often 2000+ px wide) at high priority;
/// - text and logo crossfade in 0.18 s instead of popping, and a cached logo shows immediately
///   (the text only appears if the logo takes longer than a quarter second, or has none).
struct CinematicTitle: View {
    var item: MediaItem
    var width: CGFloat
    var height: CGFloat
    /// Point size for the text fallback; scaled down to fit the box when the title is long.
    var fallbackSize: CGFloat? = nil
    /// Holds the text back for a moment while a logo loads, so a disk-cached logo doesn't flash text first.
    @State private var fallbackDue = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let url = item.logo {
                LazyImage(request: ImageRequest(url: url, processors: [.resize(width: width)], priority: .high)) { state in
                    ZStack(alignment: .bottomLeading) {
                        fallbackText
                            .opacity(state.image == nil && (fallbackDue || !state.isLoading) ? 1 : 0)
                            .animation(.easeOut(duration: 0.18), value: fallbackDue)
                        if let image = state.image {
                            image.resizable().aspectRatio(contentMode: .fit)
                                .frame(maxWidth: width, maxHeight: height, alignment: .bottomLeading)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.18), value: state.image != nil)
                }
                .pipeline(ImagePipeline.shared)
            } else {
                fallbackText
            }
        }
        .frame(width: width, height: height, alignment: .bottomLeading)
        .titleShadow()
        .task(id: item.logo) {
            fallbackDue = false
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled { fallbackDue = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(.isHeader)
    }

    private var fallbackText: some View {
        Text(item.title)
            .font(.system(size: fallbackSize ?? min(40, height * 0.42), weight: .heavy))
            .tracking(-0.5)
            .lineLimit(3)
            .minimumScaleFactor(0.5)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: width, maxHeight: height, alignment: .bottomLeading)
    }
}

/// Round cast/crew photo. Fixed size so nothing shifts while it loads; shows the person's
/// initials only when there is no photo (no URL, or the image failed to load).
struct CastAvatar: View {
    var url: URL?
    var name: String
    var size: CGFloat

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.surfaceHigh, Theme.surface], startPoint: .top, endPoint: .bottom)
            if let url {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        // Profiles are portrait: keep the face (top) in the circle.
                        Color.clear
                            .overlay(alignment: .top) { image.resizable().aspectRatio(contentMode: .fill) }
                            .clipped()
                    } else if case .failure? = state.result {
                        initialsView
                    } else {
                        Color.clear
                    }
                }
                .pipeline(ImagePipeline.shared)
            } else {
                initialsView
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .accessibilityHidden(true)
    }

    private var initialsView: some View {
        Text(Self.initials(name))
            .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.75))
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .frame(width: size, height: size)
            .background(Theme.accentGradient.opacity(0.35))
    }

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." }).filter { $0.first?.isLetter == true }
        let letters = words.count > 1 ? [words.first!, words.last!].compactMap(\.first) : words.first.map { Array($0.prefix(2)) } ?? []
        let text = String(letters).uppercased()
        return text.isEmpty ? "?" : text
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
