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

/// What the app is running on, read once from the hardware model identifier ("iPhone17,1";
/// the simulator reports the model it simulates) and the screen size. The model table gives
/// the exact iPhone and whether it has a Dynamic Island, notch or Home button; phones newer
/// than the table are classified from their real safe area instead. `HeroMetrics` turns this
/// plus the live window size into the trailer, header and title sizes for every device.
struct DeviceProfile: Equatable, CustomStringConvertible {
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

    /// Screen width class: drives title, header and trailer sizes.
    enum SizeClass: Equatable {
        /// 320–375 pt wide: SE, 8, mini, X/XS/11 Pro.
        case compact
        /// 390–402 pt: 12–17, Pro models.
        case regular
        /// 414 pt and up: Plus, Pro Max, XR/11, Air.
        case large
        case pad
        case tv
    }

    let kind: Kind
    /// Hardware identifier, e.g. "iPhone17,1" (empty when unavailable).
    let model: String
    /// Marketing name when the model is known ("iPhone 16 Pro"), otherwise the identifier.
    let name: String
    /// Portrait screen size in points.
    let screen: CGSize

    @MainActor static let current: DeviceProfile = {
        let profile = DeviceProfile.detect()
        #if DEBUG
        print("StreamForge device:", profile)
        #endif
        return profile
    }()

    var isPhone: Bool { [.phoneDynamicIsland, .phoneNotch, .phoneHomeButton].contains(kind) }
    var isPadLike: Bool { kind == .pad || kind == .mac }
    var hasDynamicIsland: Bool { kind == .phoneDynamicIsland }

    var sizeClass: SizeClass {
        switch kind {
        case .tv: return .tv
        case .pad, .mac: return .pad
        default: return screen.width >= 414 ? .large : screen.width >= 390 ? .regular : .compact
        }
    }
    var isLargePhone: Bool { isPhone && sizeClass == .large }
    var isSmallPhone: Bool { isPhone && (sizeClass == .compact || screen.height <= 700) }

    var description: String {
        "\(name) [\(model.isEmpty ? "?" : model)] \(kind) \(sizeClass) \(Int(screen.width))×\(Int(screen.height))pt"
    }

    /// Portrait height to keep video and overlays below when nothing better is known: the
    /// Dynamic Island ends ~48 pt down (safe area 59–62 pt), a notch ~30 pt (safe area 44–50 pt).
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

    /// The window's own top inset: just the status bar / Dynamic Island / notch. A view's
    /// GeometryProxy inset also counts the navigation bar, which would push a trailer that
    /// should sit right under the island down below the back button.
    @MainActor static var windowSafeTop: CGFloat? {
        #if os(iOS)
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
            .flatMap(\.windows)
        return (windows.first(where: \.isKeyWindow) ?? windows.first)?.safeAreaInsets.top
        #else
        return 0
        #endif
    }

    /// Refines a phone the table doesn't know once a real portrait safe area is known.
    func refined(withPortraitSafeTop top: CGFloat) -> DeviceProfile {
        guard isPhone, Self.knownPhones[model] == nil, top > 0 else { return self }
        let kind: Kind = top >= 55 ? .phoneDynamicIsland : top >= 40 ? .phoneNotch : .phoneHomeButton
        return DeviceProfile(kind: kind, model: model, name: name, screen: screen)
    }

    @MainActor private static func detect() -> DeviceProfile {
        let model = hardwareModel()
        let bounds = UIScreen.main.bounds.size
        let screen = CGSize(width: min(bounds.width, bounds.height), height: max(bounds.width, bounds.height))
        #if os(tvOS)
        return DeviceProfile(kind: .tv, model: model, name: "Apple TV", screen: bounds)
        #else
        if ProcessInfo.processInfo.isiOSAppOnMac || ProcessInfo.processInfo.isMacCatalystApp {
            return DeviceProfile(kind: .mac, model: model, name: "Mac", screen: screen)
        }
        if UIDevice.current.userInterfaceIdiom != .phone {
            return DeviceProfile(kind: .pad, model: model, name: model.isEmpty ? "iPad" : model, screen: screen)
        }
        if let known = knownPhones[model] {
            return DeviceProfile(kind: known.kind, model: model, name: known.name, screen: screen)
        }
        let kind = phoneKind(for: model) ?? .phoneDynamicIsland
        return DeviceProfile(kind: kind, model: model, name: model.isEmpty ? "iPhone" : model, screen: screen)
        #endif
    }

    /// Kind for an iPhone identifier: the table first, then older-model rules; nil if unknown.
    static func phoneKind(for model: String) -> Kind? {
        if let known = knownPhones[model] { return known.kind }
        guard model.hasPrefix("iPhone") else { return nil }
        let numbers = model.dropFirst("iPhone".count).split(separator: ",").compactMap { Int($0) }
        guard numbers.count == 2, numbers[0] < 10 else { return nil }
        return .phoneHomeButton // iPhone 7 and earlier
    }

    static let knownPhones: [String: (name: String, kind: Kind)] = [
        "iPhone10,1": ("iPhone 8", .phoneHomeButton), "iPhone10,4": ("iPhone 8", .phoneHomeButton),
        "iPhone10,2": ("iPhone 8 Plus", .phoneHomeButton), "iPhone10,5": ("iPhone 8 Plus", .phoneHomeButton),
        "iPhone10,3": ("iPhone X", .phoneNotch), "iPhone10,6": ("iPhone X", .phoneNotch),
        "iPhone11,2": ("iPhone XS", .phoneNotch), "iPhone11,4": ("iPhone XS Max", .phoneNotch),
        "iPhone11,6": ("iPhone XS Max", .phoneNotch), "iPhone11,8": ("iPhone XR", .phoneNotch),
        "iPhone12,1": ("iPhone 11", .phoneNotch), "iPhone12,3": ("iPhone 11 Pro", .phoneNotch),
        "iPhone12,5": ("iPhone 11 Pro Max", .phoneNotch), "iPhone12,8": ("iPhone SE (2nd gen)", .phoneHomeButton),
        "iPhone13,1": ("iPhone 12 mini", .phoneNotch), "iPhone13,2": ("iPhone 12", .phoneNotch),
        "iPhone13,3": ("iPhone 12 Pro", .phoneNotch), "iPhone13,4": ("iPhone 12 Pro Max", .phoneNotch),
        "iPhone14,4": ("iPhone 13 mini", .phoneNotch), "iPhone14,5": ("iPhone 13", .phoneNotch),
        "iPhone14,2": ("iPhone 13 Pro", .phoneNotch), "iPhone14,3": ("iPhone 13 Pro Max", .phoneNotch),
        "iPhone14,6": ("iPhone SE (3rd gen)", .phoneHomeButton),
        "iPhone14,7": ("iPhone 14", .phoneNotch), "iPhone14,8": ("iPhone 14 Plus", .phoneNotch),
        "iPhone15,2": ("iPhone 14 Pro", .phoneDynamicIsland), "iPhone15,3": ("iPhone 14 Pro Max", .phoneDynamicIsland),
        "iPhone15,4": ("iPhone 15", .phoneDynamicIsland), "iPhone15,5": ("iPhone 15 Plus", .phoneDynamicIsland),
        "iPhone16,1": ("iPhone 15 Pro", .phoneDynamicIsland), "iPhone16,2": ("iPhone 15 Pro Max", .phoneDynamicIsland),
        "iPhone17,3": ("iPhone 16", .phoneDynamicIsland), "iPhone17,4": ("iPhone 16 Plus", .phoneDynamicIsland),
        "iPhone17,1": ("iPhone 16 Pro", .phoneDynamicIsland), "iPhone17,2": ("iPhone 16 Pro Max", .phoneDynamicIsland),
        "iPhone17,5": ("iPhone 16e", .phoneNotch),
        "iPhone18,3": ("iPhone 17", .phoneDynamicIsland), "iPhone18,4": ("iPhone Air", .phoneDynamicIsland),
        "iPhone18,1": ("iPhone 17 Pro", .phoneDynamicIsland), "iPhone18,2": ("iPhone 17 Pro Max", .phoneDynamicIsland),
    ]

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

// MARK: - Hero metrics

/// Every size the hero headers need, worked out per device from `DeviceProfile` and the live
/// window (rotation, iPad split view / Stage Manager). The phone detail header is built from
/// the trailer outwards: status bar / Dynamic Island clearance, then an exact 16:9 video, then
/// just enough room under it for the title, meta row and genre chips, so the title only
/// overlaps the bottom edge of the video and nothing is pushed off or cut on any iPhone.
struct HeroMetrics: Equatable {
    /// Total header height (artwork / trailer area).
    var height: CGFloat
    /// Where the trailer picture starts (below the status bar / Dynamic Island).
    var videoTop: CGFloat
    /// Trailer sized 16:9 under `videoTop` (phones) instead of centred in the header (iPad).
    var pinsVideoToTop: Bool
    /// Fraction of the header height where the trailer picture ends (for the fade-to-page gradient).
    var videoBottomFraction: CGFloat
    /// Title logo box.
    var title: CGSize
    /// Point size of the text title when there's no logo.
    var titleFont: CGFloat
    /// Lines the text title may wrap to.
    var titleLines: Int
    var showsPoster: Bool
    /// Tagline under the genres (iPad / Apple TV; phones keep the header compact like Stremio).
    var showsTagline: Bool

    /// Detail page header. `container` is the page's safe-area size and `safeTop` its top
    /// inset (status bar + navigation bar); `statusTop` is the window's own inset (status bar /
    /// Dynamic Island only), which is where the trailer can start.
    static func detail(device: DeviceProfile, container: CGSize, safeTop: CGFloat, statusTop: CGFloat, regularWidth: Bool) -> HeroMetrics {
        let width = max(container.width, 1)
        let landscape = container.width > container.height
        let fullHeight = container.height + safeTop

        if device.kind == .tv {
            return HeroMetrics(height: 700, videoTop: 0, pinsVideoToTop: false, videoBottomFraction: 1,
                               title: CGSize(width: 600, height: 200), titleFont: 64, titleLines: 2,
                               showsPoster: false, showsTagline: true)
        }

        if device.isPadLike && regularWidth {
            let height = min(560, max(320, fullHeight * 0.62))
            return HeroMetrics(height: height, videoTop: statusTop, pinsVideoToTop: false, videoBottomFraction: 1,
                               title: CGSize(width: 420, height: 150), titleFont: 48, titleLines: 2,
                               showsPoster: height >= 400, showsTagline: true)
        }

        let (title, font): (CGSize, CGFloat) = {
            switch device.sizeClass {
            case .compact: return (CGSize(width: 240, height: 84), 30)
            case .large: return (CGSize(width: 320, height: 112), 40)
            default: return (CGSize(width: 290, height: 100), 36)
            }
        }()

        if landscape {
            // Short and wide: keep the actions on screen; the video fills the header height.
            let height = min(width * 9 / 16, max(220, fullHeight * 0.78))
            let short = CGSize(width: min(title.width, 260), height: min(title.height, 84))
            return HeroMetrics(height: height, videoTop: statusTop, pinsVideoToTop: true, videoBottomFraction: 1,
                               title: short, titleFont: min(font, 32), titleLines: 1,
                               showsPoster: false, showsTagline: false)
        }

        // Portrait phone (or a narrow iPad window): trailer first, then the title band.
        let videoTop = device.topClearance(safeTop: statusTop, isLandscape: false)
        let videoHeight = width * 9 / 16
        // Title box + 12 + meta row (~24) + 12 + chips (~28) + a little air.
        let content = title.height + 12 + 24 + 12 + 28 + 8
        let overlap = title.height * 0.4
        let height = max(videoTop + videoHeight + content - overlap, device.isSmallPhone ? 330 : 380)
        return HeroMetrics(height: height, videoTop: videoTop, pinsVideoToTop: true,
                           videoBottomFraction: min(1, (videoTop + videoHeight) / height),
                           title: title, titleFont: font, titleLines: device.sizeClass == .compact ? 2 : 3,
                           showsPoster: false, showsTagline: false)
    }

    /// Home billboard (sits under the navigation bar, so no status-bar clearance needed).
    static func home(device: DeviceProfile, width: CGFloat) -> HeroMetrics {
        switch device.sizeClass {
        case .tv:
            return HeroMetrics(height: 620, videoTop: 0, pinsVideoToTop: false, videoBottomFraction: 1,
                               title: CGSize(width: 480, height: 160), titleFont: 56, titleLines: 2,
                               showsPoster: false, showsTagline: false)
        case .pad:
            return HeroMetrics(height: 340, videoTop: 0, pinsVideoToTop: false, videoBottomFraction: 1,
                               title: CGSize(width: 320, height: 110), titleFont: 40, titleLines: 2,
                               showsPoster: false, showsTagline: false)
        default:
            let (title, font): (CGSize, CGFloat) = {
                switch device.sizeClass {
                case .compact: return (CGSize(width: 230, height: 80), 28)
                case .large: return (CGSize(width: 290, height: 100), 34)
                default: return (CGSize(width: 260, height: 90), 32)
                }
            }()
            let video = max(1, width) * 9 / 16
            // 16:9 trailer at the top, plus room for the meta line and the page dots below it.
            let height = min(340, max(device.isSmallPhone ? 230 : 250, video + 64))
            return HeroMetrics(height: height, videoTop: 0, pinsVideoToTop: true,
                               videoBottomFraction: min(1, video / height),
                               title: title, titleFont: font, titleLines: 2,
                               showsPoster: false, showsTagline: false)
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
    /// Lines the text title may wrap to (fewer on small phones / landscape).
    var fallbackLines = 3
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
            .lineLimit(fallbackLines)
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
