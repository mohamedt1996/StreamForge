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
}
