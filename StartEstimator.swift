import Foundation
import Observation

/// Predicts how long a source takes to start, and whether it will play without stalling,
/// before connecting to it.
///
/// expected speed = min(connection ceiling, swarm speed from seeders)
/// start time     = peer discovery + (startup buffer ÷ expected speed)
/// smooth         = expected speed ≥ the file's bitrate (size ÷ runtime)
///
/// The connection ceiling and the seeder → speed curve are learned from real playback,
/// separately per network type (and for a remote TorrServer, whose network is not this device's).
@MainActor
@Observable
final class StartEstimator {
    static let shared = StartEstimator()

    struct Profile: Codable {
        /// Best sustained throughput seen on this network, bytes/s (slowly decays so it tracks changes).
        var capacity: Double?
        /// Multiplier on the default seeders → speed curve, learned from sessions not capped by the connection.
        var swarmFactor: Double = 1
        var sessions = 0
        var testedAt: Date?
    }

    struct Estimate: Hashable {
        enum Rating: Int { case instant, fast, okay, slow }
        var startSeconds: Double
        var expectedSpeed: Double
        var bitrate: Double
        var rating: Rating
        var mayBuffer: Bool
        /// True once real sessions or a speed test back the numbers.
        var learned: Bool

        var label: String {
            if rating == .instant { return "Instant" }
            let s = Int(startSeconds.rounded())
            if s < 60 { return "~\(max(s, 2))s" }
            return "~\(Int((startSeconds / 60).rounded()))m"
        }
    }

    private(set) var profiles: [String: Profile] = [:]
    private let storageKey = "startEstimator.profiles"

    private init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let p = try? JSONDecoder().decode([String: Profile].self, from: data) { profiles = p }
    }

    // MARK: Keys and defaults

    /// The network whose speed matters: a remote TorrServer downloads on its own connection.
    func profileKey(torrent: Bool) -> String {
        if torrent && AppSettings.shared.values.torrentMode == .remote { return "remote-torrserver" }
        return NetworkStatus.shared.linkType
    }

    var currentProfile: Profile { profiles[profileKey(torrent: false)] ?? Profile() }

    /// Conservative ceilings before anything is learned, bytes/s.
    private func defaultCapacity(_ key: String) -> Double {
        if NetworkStatus.shared.isConstrained { return 0.6e6 }
        switch key {
        case "wired": return 12e6
        case "cellular": return 2.5e6
        case "remote-torrserver": return 10e6
        default: return 5e6       // ~40 Mbps Wi-Fi
        }
    }

    /// Default swarm curve: diminishing returns per seeder. 10 → ~1.1 MB/s, 50 → ~4 MB/s, 200 → ~12 MB/s.
    private static func swarmSpeed(seeders: Int) -> Double {
        180_000 * pow(Double(max(seeders, 1)), 0.8)
    }

    // MARK: Estimate

    func estimate(_ source: PlaybackSource, runtimeMinutes: Int?, isEpisode: Bool) -> Estimate? {
        let runtime = Double(runtimeMinutes ?? (isEpisode ? 45 : 115)) * 60
        let bitrate = source.sizeBytes.map { Double($0) / runtime } ?? Self.typicalBitrate(source.resolution)
        switch source.kind {
        case .external: return nil
        case .direct, .dispatcharrRecording:
            let key = profileKey(torrent: false)
            let profile = profiles[key]
            let capacity = profile?.capacity ?? defaultCapacity(key)
            let mayBuffer = capacity * 0.85 < bitrate
            if source.isCached && !mayBuffer {
                return Estimate(startSeconds: 1, expectedSpeed: capacity, bitrate: bitrate, rating: .instant, mayBuffer: false, learned: profile?.capacity != nil)
            }
            let start = 1.5 + (bitrate * 6 + 2e6) / max(capacity * 0.85, 1)
            return Estimate(startSeconds: start, expectedSpeed: capacity, bitrate: bitrate, rating: Self.rating(start),
                            mayBuffer: mayBuffer, learned: profile?.capacity != nil)
        case .torrent:
            let key = profileKey(torrent: true)
            let profile = profiles[key] ?? Profile()
            let capacity = profile.capacity ?? defaultCapacity(key)
            let seeders = source.seeders ?? 8
            let swarm = Self.swarmSpeed(seeders: seeders) * profile.swarmFactor
            let expected = max(min(capacity * 0.85, swarm), 50_000)
            // Finding peers via trackers/DHT, slower for thin swarms.
            let discovery: Double = seeders < 3 ? 20 : seeders < 10 ? 9 : seeders < 30 ? 5 : 3
            // Container header plus ~15 s of video before mpv starts.
            let buffer = bitrate * 15 + 4e6
            let start = discovery + buffer / expected
            return Estimate(startSeconds: start, expectedSpeed: expected, bitrate: bitrate,
                            rating: Self.rating(start), mayBuffer: expected < bitrate * 1.05,
                            learned: profile.sessions > 0 || profile.capacity != nil)
        }
    }

    private static func rating(_ seconds: Double) -> Estimate.Rating {
        seconds < 12 ? .fast : seconds < 45 ? .okay : .slow
    }

    private static func typicalBitrate(_ resolution: Int) -> Double {
        switch resolution {
        case 2160...: return 2.5e6
        case 1080..<2160: return 0.75e6
        case 720..<1080: return 0.35e6
        default: return 0.2e6
        }
    }

    /// Sort key for "Fastest start": quick and smooth first, then by start time.
    func fastestKey(_ source: PlaybackSource, runtimeMinutes: Int?, isEpisode: Bool) -> Double {
        guard let e = estimate(source, runtimeMinutes: runtimeMinutes, isEpisode: isEpisode) else { return 1e9 }
        return e.startSeconds + (e.mayBuffer ? 1e5 : 0) - Double(source.resolution) / 1e5
    }

    // MARK: Learning

    /// Called when a playback session ends with its best sustained throughput.
    func record(peakSpeed: Double, seeders: Int?, torrent: Bool) {
        guard peakSpeed > 20_000 else { return }
        let key = profileKey(torrent: torrent)
        var p = profiles[key] ?? Profile()
        let oldCapacity = p.capacity
        // Ceiling: keep the best, decaying 10% per session so a slower network replaces an old record.
        p.capacity = max(peakSpeed, (p.capacity ?? 0) * 0.9)
        if torrent, let seeders, seeders > 0 {
            // Only sessions clearly below the connection ceiling tell us about the swarm.
            if peakSpeed < (oldCapacity ?? .infinity) * 0.7 || oldCapacity == nil {
                let ratio = min(max(peakSpeed / Self.swarmSpeed(seeders: seeders), 0.15), 6)
                p.swarmFactor = p.sessions == 0 ? ratio : p.swarmFactor * 0.7 + ratio * 0.3
            }
            p.sessions += 1
        }
        profiles[key] = p
        save()
    }

    func reset() {
        profiles = [:]
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: storageKey) }
    }

    // MARK: Speed test

    /// Downloads a test file (Cloudflare's speed endpoint) and stores the result as this network's ceiling.
    func runSpeedTest() async -> Double? {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        var best: Double?
        for bytes in [2_000_000, 25_000_000] {
            guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=\(bytes)") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 25
            let begin = Date()
            guard let (data, _) = try? await session.data(for: request), data.count > 0 else { continue }
            let speed = Double(data.count) / max(Date().timeIntervalSince(begin), 0.05)
            best = max(best ?? 0, speed)
        }
        guard let best else { return nil }
        let key = profileKey(torrent: false)
        var p = profiles[key] ?? Profile()
        p.capacity = best
        p.testedAt = Date()
        profiles[key] = p
        save()
        return best
    }
}

/// Tracks the best few-second average throughput during one playback session.
struct ThroughputTracker {
    private var window: [Double] = []
    private(set) var peak: Double = 0
    private(set) var samples = 0

    mutating func add(_ bytesPerSecond: Double) {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return }
        samples += 1
        window.append(bytesPerSecond)
        if window.count > 5 { window.removeFirst() }
        if window.count == 5 { peak = max(peak, window.reduce(0, +) / 5) }
    }
}
