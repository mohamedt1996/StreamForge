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

    func testDirectPreviewSelection() {
        XCTAssertNotNil(TrailerSelection.directURL(URL(string: "https://media.example/trailer.m3u8?token=test")))
        XCTAssertNil(TrailerSelection.directURL(URL(string: "https://youtube.com/watch?v=abc_DEF-1234")))
        XCTAssertNil(TrailerSelection.directURL(URL(string: "file:///tmp/trailer.mp4")))
    }

    func testTrailerMetadataSeparatesNativeAndYouTubeSources() {
        let item = MediaItem(id: "test", type: .movie, title: "Test", origin: .tmdb(id: 1))
        var details = MediaDetails(item: item)
        details.addTrailers(["https://media.example/trailer.mp4", "https://youtu.be/abc_DEF-1234", "abc_DEF-1234"])
        XCTAssertEqual(details.item.trailerURL?.absoluteString, "https://media.example/trailer.mp4")
        XCTAssertEqual(details.trailerKeys, ["abc_DEF-1234"])
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

}
