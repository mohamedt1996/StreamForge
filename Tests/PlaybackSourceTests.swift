import XCTest
@testable import StreamForge

final class PlaybackSourceTests: XCTestCase {
    func testQualitySizeAndSeedParsing() {
        let parsed = StreamTextParser.parse("Movie 2160p HDR10+ REMUX [RD+] 1,5 GiB seeders: 42")
        XCTAssertEqual(parsed.resolution, 2160)
        XCTAssertEqual(parsed.size, 1_610_612_736)
        XCTAssertEqual(parsed.seeders, 42)
        XCTAssertTrue(parsed.cached)
        XCTAssertTrue(parsed.tags.contains("HDR10+"))
    }

    func testOversizedSizeDoesNotTrap() {
        XCTAssertNil(StreamTextParser.parse(String(repeating: "9", count: 100) + " GB").size)
    }

    func testTrailerMetadataKeepsOnlyYouTube() {
        let item = MediaItem(id: "test", type: .movie, title: "Test", origin: .tmdb(id: 1))
        var details = MediaDetails(item: item)
        details.addTrailers(["https://media.example/trailer.mp4", "https://www.imdb.com/video/vi12345/",
                             "https://youtu.be/abc_DEF-1234", "abc_DEF-1234"])
        XCTAssertNil(details.item.trailerURL)
        XCTAssertEqual(details.trailerKeys, ["abc_DEF-1234"])
        XCTAssertEqual(details.trailerSources, [.youtube("abc_DEF-1234")])
        XCTAssertNil(MediaDetails.cleanYouTubeKey("https://unrelated.example/abc_DEF-1234"))
    }

    func testOlderSavedItemsDecodeWithoutTrailer() throws {
        let item = MediaItem(id: "test", type: .movie, title: "Test", origin: .tmdb(id: 1))
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(MediaItem.self, from: data)
        XCTAssertNil(decoded.trailerURL)
        XCTAssertEqual(decoded.id, item.id)
    }
    func testContinueWatchingKeepsNewestEpisodeAndExcludesCompletedEntries() {
        let item = MediaItem(id: "show", type: .series, title: "Show", origin: .tmdb(id: 1))
        let old = WatchProgress(key: "old", item: item, position: 120, duration: 1800, updatedAt: Date(timeIntervalSince1970: 1))
        let next = WatchProgress(key: "next", item: item, position: 0, duration: 0, updatedAt: Date(timeIntervalSince1970: 2))
        let finished = WatchProgress(key: "finished", item: item, position: 1800, duration: 1800, updatedAt: Date(timeIntervalSince1970: 3))
        let entries = LibraryStore.continueWatchingEntries([old, next, finished], watched: [])
        XCTAssertEqual(entries.map(\.key), ["next"])
        XCTAssertEqual(entries.first?.remainingText, "Up next")
        XCTAssertFalse(next.isFinished)
        XCTAssertEqual(next.fraction, 0)
    }

    func testContinueWatchingExcludesExplicitlyWatchedEntries() {
        let item = MediaItem(id: "movie", type: .movie, title: "Movie", origin: .tmdb(id: 1))
        let entry = WatchProgress(key: "movie", item: item, position: 600, duration: 7200, updatedAt: Date())
        XCTAssertTrue(LibraryStore.continueWatchingEntries([entry], watched: ["movie"]).isEmpty)
    }

    func testTrailerSourcesAreYouTubeOnly() {
        let youtube = TrailerSource.youtube("abcdefghijk")
        XCTAssertEqual(TrailerSource.ordered([youtube, .youtube("zyxwvutsrqp"), youtube]), [youtube, .youtube("zyxwvutsrqp")])
        XCTAssertEqual(TrailerSource.parse("https://www.youtube.com/watch?v=abcdefghijk"), youtube)
        XCTAssertEqual(TrailerSource.parse("abcdefghijk"), youtube)
        XCTAssertNil(TrailerSource.parse("https://www.imdb.com/video/vi12345/"))
        XCTAssertNil(TrailerSource.parse("https://cdn.example.com/trailer.m3u8"))
        XCTAssertNil(TrailerSource.parse("javascript:alert(1)"))
    }

    func testIMDbTitlesGetNoTrailerLookup() {
        var item = MediaItem(id: "tt0111161", type: .movie, title: "Test", origin: .tmdb(id: 1))
        item.imdbID = "tt0111161"
        XCTAssertTrue(MediaDetails(item: item).trailerSources.isEmpty)
    }

    func testDeviceModelClassification() {
        XCTAssertEqual(DeviceProfile.phoneKind(for: "iPhone15,2"), .phoneDynamicIsland) // 14 Pro
        XCTAssertEqual(DeviceProfile.phoneKind(for: "iPhone17,1"), .phoneDynamicIsland) // 16 Pro
        XCTAssertEqual(DeviceProfile.phoneKind(for: "iPhone17,5"), .phoneNotch)         // 16e
        XCTAssertEqual(DeviceProfile.phoneKind(for: "iPhone14,7"), .phoneNotch)         // 14
        XCTAssertEqual(DeviceProfile.phoneKind(for: "iPhone10,6"), .phoneNotch)         // X
        XCTAssertEqual(DeviceProfile.phoneKind(for: "iPhone14,6"), .phoneHomeButton)    // SE 3
        XCTAssertEqual(DeviceProfile.phoneKind(for: "iPhone10,4"), .phoneHomeButton)    // 8
        XCTAssertNil(DeviceProfile.phoneKind(for: "iPhone99,1"))
        XCTAssertEqual(DeviceProfile.knownPhones["iPhone18,2"]?.name, "iPhone 17 Pro Max")
        XCTAssertNil(DeviceProfile.phoneKind(for: "iPad14,1"))
        let unknown = DeviceProfile(kind: .phoneDynamicIsland, model: "iPhone99,1", name: "iPhone99,1", screen: CGSize(width: 402, height: 874))
        XCTAssertEqual(unknown.refined(withPortraitSafeTop: 47).kind, .phoneNotch)
        XCTAssertEqual(unknown.topClearance(safeTop: 0, isLandscape: true), 0)
        XCTAssertEqual(unknown.topClearance(safeTop: 54, isLandscape: false), 59)
    }

    /// The phone detail header is built around the trailer: it starts right under the status
    /// bar / Dynamic Island (not the navigation bar), is exactly 16:9, and leaves room for the title.
    func testHeroMetricsPerPhone() {
        let phones: [(DeviceProfile, statusTop: CGFloat)] = [
            (DeviceProfile(kind: .phoneHomeButton, model: "iPhone14,6", name: "SE", screen: CGSize(width: 375, height: 667)), 20),
            (DeviceProfile(kind: .phoneNotch, model: "iPhone14,4", name: "13 mini", screen: CGSize(width: 375, height: 812)), 50),
            (DeviceProfile(kind: .phoneDynamicIsland, model: "iPhone16,1", name: "15 Pro", screen: CGSize(width: 393, height: 852)), 59),
            (DeviceProfile(kind: .phoneDynamicIsland, model: "iPhone17,2", name: "16 Pro Max", screen: CGSize(width: 440, height: 956)), 62),
        ]
        for (device, statusTop) in phones {
            let safeTop = statusTop + 44 // plus the navigation bar
            let container = CGSize(width: device.screen.width, height: device.screen.height - safeTop - 34)
            let m = HeroMetrics.detail(device: device, container: container, safeTop: safeTop, statusTop: statusTop, regularWidth: false)
            XCTAssertTrue(m.pinsVideoToTop, device.name)
            XCTAssertEqual(m.videoTop, max(statusTop, device.minimumTopClearance), device.name)
            let videoBottom = m.videoTop + device.screen.width * 9 / 16
            XCTAssertGreaterThanOrEqual(m.height - videoBottom, m.title.height * 0.6, "\(device.name): room for the title")
            XCTAssertLessThan(m.height, device.screen.height * 0.62, "\(device.name): actions stay on the first screen")
            XCTAssertLessThanOrEqual(m.title.width, device.screen.width - 32, device.name)

            let landscape = HeroMetrics.detail(device: device, container: CGSize(width: device.screen.height - 120, height: device.screen.width - 21),
                                               safeTop: 0, statusTop: 0, regularWidth: false)
            XCTAssertEqual(landscape.videoTop, 0)
            XCTAssertLessThanOrEqual(landscape.height, device.screen.width, "\(device.name): landscape header fits")
        }
    }

    func testCinemetaIMDbRatingParsing() {
        XCTAssertEqual(CinemetaRating.rating(fromCinemetaJSON: Data(#"{"meta":{"imdbRating":"8.8"}}"#.utf8)), "8.8")
        XCTAssertEqual(CinemetaRating.rating(fromCinemetaJSON: Data(#"{"meta":{"imdbRating":7.25}}"#.utf8)), "7.2")
        XCTAssertNil(CinemetaRating.rating(fromCinemetaJSON: Data(#"{"meta":{"imdbRating":""}}"#.utf8)))
        XCTAssertNil(CinemetaRating.rating(fromCinemetaJSON: Data(#"{"meta":{}}"#.utf8)))
        XCTAssertNil(CinemetaRating.rating(fromCinemetaJSON: Data("not json".utf8)))
    }
}
