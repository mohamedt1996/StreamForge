import UIKit

enum Platform {
    static let name = "tvOS"
    static let isPad = false
    /// gomobile has no tvOS target, so Apple TV uses a remote TorrServer.
    static let supportsEmbeddedTorrents = false
}
