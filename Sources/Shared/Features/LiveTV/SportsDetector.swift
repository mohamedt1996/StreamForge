import Foundation

/// Heuristics that flag sports and live-event programmes from XMLTV categories and titles.
enum SportsDetector {
    /// Lower-cased XMLTV category words that mean sport.
    private static let categoryWords: [String] = [
        "sport", "football", "soccer", "basketball", "baseball", "hockey", "tennis", "golf", "rugby",
        "cricket", "boxing", "mma", "ufc", "wrestling", "motorsport", "formula 1", "f1", "nascar", "racing",
        "cycling", "athletics", "olympic", "volleyball", "handball", "darts", "snooker", "esports",
        "american football", "fútbol", "futbol", "calcio", "fußball", "fussball", "deportes",
    ]

    /// League / competition names that appear in titles.
    private static let leagueWords: [String] = [
        "premier league", "champions league", "europa league", "conference league", "la liga", "laliga",
        "serie a", "bundesliga", "ligue 1", "eredivisie", "mls", "nba", "nfl", "nhl", "mlb", "ncaa",
        "wnba", "efl", "fa cup", "carabao", "copa ", "uefa", "fifa", "world cup", "euro 20", "super bowl",
        "grand prix", "motogp", "wimbledon", "us open", "roland garros", "australian open", "pga", "ryder cup",
        "six nations", "ipl", "ashes", "ufc ", "wwe", "aew", "boxing:", "fight night", "matchday",
        "match of the day", "monday night football", "sunday night football", "thursday night football",
        "saudi pro league", "liga mx", "a-league", "super league", "scottish premiership",
    ]

    private static let versusPattern = try! NSRegularExpression(
        pattern: #"\S\s+(vs\.?|v\.?|x|@)\s+\S"#, options: [.caseInsensitive])

    static func isSports(_ p: XCEPGListing) -> Bool {
        isSports(title: p.title, categories: p.categories)
    }

    static func isSports(title: String, categories: [String]) -> Bool {
        for c in categories {
            let lc = c.lowercased()
            if categoryWords.contains(where: { lc.contains($0) }) { return true }
        }
        let t = title.lowercased()
        if t.hasPrefix("live:") || t.hasPrefix("live ") && t.contains(" v") { return true }
        if leagueWords.contains(where: { t.contains($0) }) { return true }
        let range = NSRange(t.startIndex..., in: t)
        if versusPattern.firstMatch(in: t, range: range) != nil {
            // "Kramer vs. Kramer" style films are rare in live guides; require a hint of a fixture.
            return categories.isEmpty || t.count < 70
        }
        return false
    }

    /// Category names (live TV groups) that are clearly sport.
    static func isSportsCategory(_ name: String) -> Bool {
        let lc = name.lowercased()
        return lc.contains("sport") || lc.contains("ppv") || lc.contains("event") || lc.contains("dazn")
            || lc.contains("espn") || lc.contains("football") || lc.contains("soccer") || lc.contains("nba")
            || lc.contains("nfl") || lc.contains("nhl") || lc.contains("mlb") || lc.contains("racing")
    }
}
