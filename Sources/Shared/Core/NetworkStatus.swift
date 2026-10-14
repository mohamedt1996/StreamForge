import Foundation
import Network
import Observation

/// Tracks whether the current network path is expensive (cellular / hotspot) or constrained
/// (Low Data Mode), so bandwidth-hungry extras like trailer autoplay can stay off.
@MainActor
@Observable
final class NetworkStatus {
    static let shared = NetworkStatus()

    private(set) var isExpensive = false
    private(set) var isConstrained = false
    private(set) var isOnline = true
    /// "wifi", "cellular", "wired" or "other" — used to keep separate learned speeds per network type.
    private(set) var linkType = "wifi"

    @ObservationIgnored private let monitor = NWPathMonitor()

    /// True when it is fine to stream non-essential video.
    var allowsAutoplayMedia: Bool { isOnline && !isExpensive && !isConstrained }

    private init() {
        monitor.pathUpdateHandler = { path in
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            let online = path.status == .satisfied
            let link = path.usesInterfaceType(.wiredEthernet) ? "wired"
                : path.usesInterfaceType(.wifi) ? "wifi"
                : path.usesInterfaceType(.cellular) ? "cellular" : "other"
            Task { @MainActor in
                NetworkStatus.shared.update(expensive: expensive, constrained: constrained, online: online)
                if NetworkStatus.shared.linkType != link { NetworkStatus.shared.linkType = link }
            }
        }
        monitor.start(queue: DispatchQueue(label: "streamforge.network-status"))
    }

    private func update(expensive: Bool, constrained: Bool, online: Bool) {
        if isExpensive != expensive { isExpensive = expensive }
        if isConstrained != constrained { isConstrained = constrained }
        if isOnline != online { isOnline = online }
    }
}
