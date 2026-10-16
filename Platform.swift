import UIKit

enum Platform {
    static let name = "iOS"
    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    static let supportsEmbeddedTorrents = TorrentEngine.embeddedAvailable
}
