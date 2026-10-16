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

    func testTrailerMetadataKeepsOnlyYouTubeSources() {
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

    func testTrailerSourceParsingIsYouTubeOnly() {
        let youtube = TrailerSource.youtube("abcdefghijk")
        XCTAssertEqual(TrailerSource.ordered([youtube, youtube]), [youtube])
        XCTAssertEqual(TrailerSource.parse("https://youtu.be/abcdefghijk"), youtube)
        XCTAssertNil(TrailerSource.parse("https://www.imdb.com/video/vi12345/"))
        XCTAssertNil(TrailerSource.parse("https://cdn.example.com/trailer.m3u8"))
        XCTAssertNil(TrailerSource.parse("javascript:alert(1)"))
    }
}
