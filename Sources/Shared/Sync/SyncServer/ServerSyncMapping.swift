import Foundation

// Mapping between the app's stores and sync-server records (PROTOCOL.md §3).

extension ServerSync {
    struct LocalRecord {
        var collection: String
        var id: String
        var data: SyncJSON
        /// The record's own change time (ms) when the store keeps one (watch progress).
        var stamp: Int64?
    }

    static var syncedSettingKeys: Set<String> {
        var keys: Set<String> = ["metadataLanguage", "metadataSource", "maxResolution", "excludeCam", "streamSort",
                                 "autoplayNext", "resumePlayback", "seekStep", "audioLanguage", "subtitleLanguage",
                                 "autoSubtitles", "subtitleScale", "hideAdult", "trailerAutoplay", "remoteTorrServer"]
        // Apple TV can't run torrents itself; its "remote" mode must not switch phones over.
        #if !os(tvOS)
        keys.insert("torrentMode")
        #endif
        return keys
    }

    // MARK: Profiles

    /// The first profile is the household's "default" profile on every device; others use
    /// their lowercase UUID.
    func profileKey(_ id: UUID) -> String {
        id == ProfileStore.shared.profiles.first?.id ? "default" : id.uuidString.lowercased()
    }

    func profileID(forKey key: String) -> UUID? {
        key == "default" ? ProfileStore.shared.profiles.first?.id : UUID(uuidString: key)
    }

    static func authModeString(_ mode: DispatcharrAuthMode) -> String {
        switch mode {
        case .xc: return "xc"
        case .account: return "web"
        case .apiKey: return "apiKey"
        }
    }

    static func authMode(_ raw: String?) -> DispatcharrAuthMode {
        switch raw {
        case "web", "account": return .account
        case "apiKey": return .apiKey
        default: return .xc
        }
    }

    // MARK: Building local records

    func buildLocalRecords() -> [String: LocalRecord] {
        var out: [String: LocalRecord] = [:]
        func add(_ collection: String, _ id: String, _ data: SyncJSON, stamp: Int64? = nil) {
            out[Self.recordKey(collection, id)] = LocalRecord(collection: collection, id: id, data: data, stamp: stamp)
        }
        let secrets = hasSecretsScope
        let store = DispatcharrStore.shared
        let library = LibraryStore.shared
        let profileStore = ProfileStore.shared
        let activeServer = store.activeServer?.id.uuidString.lowercased()
        let serverIDs = store.servers.map(\.id)

        // Profiles and their libraries
        for profile in profileStore.profiles {
            let pk = profileKey(profile.id)
            add("profiles", pk, .object([
                "name": .string(profile.name),
                "avatar": .string(profile.emoji),
                "color": .integer(profile.colorIndex),
                "kids": .bool(profile.isKids),
            ]))
            if secrets {
                let pin = profile.pin
                if !pin.isEmpty { add("secrets", "pin:\(pk)", .object(["value": .string(pin)])) }
            }

            let lib = library.syncLibrary(for: profile.id)

            // Progress: one record per canonical key (the newest local entry wins).
            var best: [String: (stamp: Int64, local: String)] = [:]
            for (localKey, p) in lib.progress {
                guard let itemKey = SyncKeys.itemKey(p.item) else { continue }
                let full = p.episode.map { itemKey + SyncKeys.episodeSuffix(season: $0.season, episode: $0.episode) } ?? itemKey
                let id = pk + "|" + full
                let stamp = Int64((p.updatedAt.timeIntervalSince1970 * 1000).rounded())
                if let b = best[id], (b.stamp, b.local) >= (stamp, localKey) { continue }
                best[id] = (stamp, localKey)
                add("progress", id, progressData(pk, p, itemKey: itemKey), stamp: stamp)
            }

            // Watched marks
            var itemsByID: [String: MediaItem]?
            for localKey in lib.watched {
                var canonical = lib.watchedCanonical[localKey] ?? state.legacyWatched["\(profile.id.uuidString)|\(localKey)"]
                if canonical == nil {
                    if itemsByID == nil {
                        var map: [String: MediaItem] = [:]
                        for p in lib.progress.values { map[p.item.id] = p.item }
                        for f in lib.favorites { map[f.id] = f }
                        itemsByID = map
                    }
                    let parts = localKey.components(separatedBy: "#")
                    if let item = itemsByID?[parts[0]], let key = SyncKeys.itemKey(item) {
                        if parts.count > 1 {
                            let se = parts[1].split(separator: "x")
                            if se.count == 2, let s = Int(se[0]), let e = Int(se[1]) {
                                canonical = key + SyncKeys.episodeSuffix(season: s, episode: e)
                            }
                        } else {
                            canonical = key
                        }
                    }
                    if canonical == nil { canonical = SyncKeys.legacyKey(forLocalKey: localKey, serverIDs: serverIDs) }
                    if let found = canonical { state.legacyWatched["\(profile.id.uuidString)|\(localKey)"] = found }
                }
                guard let resolved = canonical else { continue }
                add("watched", pk + "|" + resolved, .object(["profile": .string(pk), "key": .string(resolved)]))
            }

            // Favorites
            for item in lib.favorites {
                guard let itemKey = SyncKeys.itemKey(item) else { continue }
                let id = pk + "|" + itemKey
                if out[Self.recordKey("favorites", id)] != nil { continue }
                add("favorites", id, .object([
                    "profile": .string(pk),
                    "item": itemJSON(item, key: itemKey),
                    "addedAt": .number(lib.favoriteDates[item.id] ?? SyncKeys.legacyFavoriteBase),
                ]))
            }

            // Favorite channels belong to the active Dispatcharr server.
            if let activeServer {
                for channelID in lib.favoriteChannelIDs {
                    add("channels", "\(pk)|\(activeServer)|\(channelID)", .object([
                        "profile": .string(pk),
                        "serverId": .string(activeServer),
                        "channelId": .integer(channelID),
                        "favorite": .bool(true),
                    ]))
                }
            }
        }
        if secrets {
            let parent = profileStore.parentPIN
            if !parent.isEmpty { add("secrets", "parentPin", .object(["value": .string(parent)])) }
        }

        // Addons
        for (i, addon) in AddonManager.shared.addons.enumerated() {
            let url = addon.manifestURL.absoluteString
            add("addons", url, .object([
                "transportUrl": .string(url),
                "name": .string(addon.manifest.name),
                "enabled": .bool(addon.enabled),
                "order": .integer(i),
            ]))
        }

        // Dispatcharr servers (+ their secrets)
        for (i, server) in store.servers.enumerated() {
            let sid = server.id.uuidString.lowercased()
            add("servers", sid, .object([
                "name": .string(server.name),
                "url": .string(server.baseURL),
                "username": .string(server.username),
                "authMode": .string(Self.authModeString(server.authMode)),
                "order": .integer(i),
            ]))
            if secrets {
                let xc = server.xcPassword, web = server.webPassword, key = server.apiKey
                if !xc.isEmpty || !web.isEmpty || !key.isEmpty {
                    add("secrets", "server:\(sid)", .object([
                        "xcPassword": .string(xc), "webPassword": .string(web), "apiKey": .string(key),
                    ]))
                }
            }
        }

        // API keys and Trakt
        if secrets {
            let settings = AppSettings.shared
            for (name, value) in [("tmdb", settings.tmdbKey), ("omdb", settings.omdbKey), ("fanart", settings.fanartKey)] where !value.isEmpty {
                add("secrets", "key:\(name)", .object(["value": .string(value)]))
            }
            if let raw = TraktService.shared.exportedToken, let data = raw.data(using: .utf8),
               let token = try? JSONDecoder().decode(SyncJSON.self, from: data), case .object = token {
                add("secrets", "trakt", token)
            }
        }

        // Settings
        for (key, value) in settingsValues(AppSettings.shared.values) {
            add("settings", key, .object(["value": value]))
        }
        return out
    }

    // MARK: Items

    func itemJSON(_ item: MediaItem, key: String) -> SyncJSON {
        var o: [String: SyncJSON] = [
            "key": .string(key),
            "type": .string(key.hasPrefix("series") ? "series" : "movie"),
            "title": .string(item.title),
        ]
        if let y = item.year { o["year"] = .integer(y) }
        if let u = item.poster { o["poster"] = .string(u.absoluteString) }
        if let u = item.backdrop { o["backdrop"] = .string(u.absoluteString) }
        if let u = item.logo { o["logo"] = .string(u.absoluteString) }
        if let i = SyncKeys.imdbID(of: item) { o["imdbId"] = .string(i) }
        if let t = SyncKeys.tmdbID(of: item) { o["tmdbId"] = .integer(t) }
        if let r = item.runtimeMinutes { o["runtimeMinutes"] = .integer(r) }
        let origin: [String: SyncJSON]
        switch item.origin {
        case .dispatcharrMovie(let serverID, let streamID, let ext):
            origin = ["kind": .string("dispatcharrMovie"), "serverId": .string(serverID.uuidString.lowercased()),
                      "streamId": .integer(streamID), "ext": .string(ext)]
        case .dispatcharrSeries(let serverID, let seriesID):
            origin = ["kind": .string("dispatcharrSeries"), "serverId": .string(serverID.uuidString.lowercased()),
                      "streamId": .integer(seriesID)]
        case .stremio(let addonID, let metaID):
            origin = ["kind": .string("addon"), "addonId": .string(addonID), "metaId": .string(metaID),
                      "metaType": .string(item.type.stremioType)]
        case .tmdb:
            origin = ["kind": .string("tmdb")]
        case .dispatcharrChannel:
            origin = ["kind": .string("other")]
        }
        o["origin"] = .object(origin)
        return .object(o)
    }

    private func progressData(_ pk: String, _ p: WatchProgress, itemKey: String) -> SyncJSON {
        var o: [String: SyncJSON] = [
            "profile": .string(pk),
            "item": itemJSON(p.item, key: itemKey),
            "position": .number((p.position * 10).rounded() / 10),
            "duration": .number((p.duration * 10).rounded() / 10),
        ]
        if let ep = p.episode {
            var e: [String: SyncJSON] = [
                "season": .integer(ep.season),
                "episode": .integer(ep.episode),
                "title": .string(ep.title),
            ]
            if let s = ep.still { e["still"] = .string(s.absoluteString) }
            if let id = ep.dispatcharrEpisodeID { e["dispatcharrEpisodeId"] = .integer(id) }
            if let ext = ep.ext { e["ext"] = .string(ext) }
            o["episode"] = .object(e)
        }
        return .object(o)
    }

    /// Builds a MediaItem for a record from another device. The result always maps back to the
    /// same canonical key. Prefers a copy this device can play from its own Dispatcharr server.
    func mediaItem(from json: SyncJSON?, key: String) -> MediaItem? {
        guard let parsed = SyncKeys.parse(key) else { return nil }
        let j = json ?? .object([:])
        let type = parsed.type
        let title = j["title"]?.stringValue ?? "Untitled"
        let year = j["year"]?.intValue
        let poster = j["poster"]?.stringValue.flatMap(URL.init(string:))
        let backdrop = j["backdrop"]?.stringValue.flatMap(URL.init(string:))
        let logo = j["logo"]?.stringValue.flatMap(URL.init(string:))
        let runtime = j["runtimeMinutes"]?.intValue
        let origin = j["origin"]
        let kind = origin?["kind"]?.stringValue
        let addonID = kind == "addon" ? origin?["addonId"]?.stringValue : nil

        // Only ids that keep the canonical key unchanged.
        var imdb: String?
        var tmdb: Int?
        switch parsed.id {
        case .imdb(let i):
            imdb = i
            tmdb = j["tmdbId"]?.intValue
        case .tmdb(let n):
            tmdb = n
        case .dispatcharr, .meta:
            break
        }
        let typeWord = type == .series ? "series" : "movie"

        func make(_ id: String, _ origin: MediaOrigin) -> MediaItem {
            MediaItem(id: id, type: type, title: title, year: year, poster: poster, backdrop: backdrop, logo: logo,
                      imdbID: imdb, tmdbID: tmdb, origin: origin, runtimeMinutes: runtime)
        }

        let store = DispatcharrStore.shared
        // 1. The sender's Dispatcharr item, when this device has that server.
        if kind == "dispatcharrMovie" || kind == "dispatcharrSeries",
           let sid = origin?["serverId"]?.stringValue.flatMap(UUID.init(uuidString:)),
           store.servers.contains(where: { $0.id == sid }),
           let stream = (origin?["streamId"] ?? origin?["seriesId"])?.intValue {
            let o: MediaOrigin = kind == "dispatcharrMovie"
                ? .dispatcharrMovie(serverID: sid, streamID: stream, ext: origin?["ext"]?.stringValue ?? "mp4")
                : .dispatcharrSeries(serverID: sid, seriesID: stream)
            let item = make("xc:\(sid.uuidString.prefix(8)):\(typeWord):\(stream)", o)
            if SyncKeys.itemKey(item) == key { return item }
        }

        // 2. The same title on this device's active Dispatcharr server.
        if let sid = store.activeServer?.id, imdb != nil || tmdb != nil {
            var local: MediaItem?
            if type == .movie, let m = store.movies.first(where: { ($0.tmdbID != nil && $0.tmdbID == tmdb) || ($0.imdbID != nil && $0.imdbID == imdb) }) {
                local = m.mediaItem(serverID: sid)
            } else if type == .series, let s = store.series.first(where: { ($0.tmdbID != nil && $0.tmdbID == tmdb) || ($0.imdbID != nil && $0.imdbID == imdb) }) {
                local = s.mediaItem(serverID: sid)
            }
            if var l = local {
                if let imdb { l.imdbID = imdb }
                if let tmdb { l.tmdbID = tmdb }
                if l.poster == nil { l.poster = poster }
                if l.backdrop == nil { l.backdrop = backdrop }
                if l.logo == nil { l.logo = logo }
                if l.runtimeMinutes == nil { l.runtimeMinutes = runtime }
                if SyncKeys.itemKey(l) == key { return l }
            }
        }

        // 3. Straight from the key.
        let item: MediaItem
        switch parsed.id {
        case .imdb(let i):
            item = make(i, .stremio(addonID: addonID ?? "com.linvo.cinemeta", metaID: i))
        case .tmdb(let n):
            item = make("tmdb:\(type.rawValue):\(n)", .tmdb(id: n))
        case .dispatcharr(let sid, let n):
            let o: MediaOrigin = type == .series
                ? .dispatcharrSeries(serverID: sid, seriesID: n)
                : .dispatcharrMovie(serverID: sid, streamID: n, ext: origin?["ext"]?.stringValue ?? "mp4")
            item = make("xc:\(sid.uuidString.prefix(8)):\(typeWord):\(n)", o)
        case .meta(let m):
            let addon = addonID ?? ""
            item = make(m.hasPrefix("tt") ? m : "stremio:\(addon):\(m)", .stremio(addonID: addon, metaID: m))
        }
        return item
    }

    private func episodeRef(_ j: SyncJSON?, season: Int, episode: Int, item: MediaItem, senderOrigin: SyncJSON?) -> EpisodeRef {
        var episodeID: Int?
        // A Dispatcharr episode id only plays on the server it came from.
        if case .dispatcharrSeries(let sid, _) = item.origin,
           senderOrigin?["serverId"]?.stringValue.flatMap(UUID.init(uuidString:)) == sid {
            episodeID = j?["dispatcharrEpisodeId"]?.intValue
        }
        var ref = EpisodeRef(id: episodeID.map { "xc-ep-\($0)" } ?? "sync-\(item.id)-\(season)-\(episode)",
                             season: season, episode: episode,
                             title: j?["title"]?.stringValue ?? "Episode \(episode)",
                             still: j?["still"]?.stringValue.flatMap(URL.init(string:)),
                             dispatcharrEpisodeID: episodeID,
                             ext: episodeID == nil ? nil : (j?["ext"]?.stringValue ?? "mp4"))
        if let imdb = SyncKeys.imdbID(of: item) { ref.stremioVideoID = "\(imdb):\(season):\(episode)" }
        return ref
    }

    // MARK: Settings

    func settingsValues(_ v: AppSettings.Values) -> [String: SyncJSON] {
        var out: [String: SyncJSON] = [
            "metadataLanguage": .string(v.metadataLanguage),
            "metadataSource": .string((v.metadataPriority.first ?? .tmdb).rawValue),
            "maxResolution": .integer(v.maxStreamResolution),
            "excludeCam": .bool(v.excludeCam),
            "streamSort": .string(v.streamSort.rawValue),
            "autoplayNext": .bool(v.autoplayNext),
            "resumePlayback": .bool(v.resumePlayback),
            "seekStep": .integer(v.seekStep),
            "audioLanguage": .string(v.preferredAudioLanguage),
            "subtitleLanguage": .string(v.preferredSubtitleLanguage),
            "autoSubtitles": .bool(v.autoSubtitles),
            "subtitleScale": .number((v.subtitleScale * 100).rounded() / 100),
            "hideAdult": .bool(v.hideAdult),
            "trailerAutoplay": .bool(v.trailerAutoplay),
            "remoteTorrServer": .string(v.remoteTorrServerURL),
        ]
        #if !os(tvOS)
        out["torrentMode"] = .string(v.torrentMode.rawValue)
        #endif
        return out
    }

    /// Returns true when the value was understood.
    private func applySetting(_ key: String, _ value: SyncJSON, to v: inout AppSettings.Values) -> Bool {
        switch key {
        case "metadataLanguage":
            guard let s = value.stringValue, !s.isEmpty else { return false }
            v.metadataLanguage = s
        case "metadataSource":
            guard let s = value.stringValue, let source = MetadataSource(rawValue: s) else { return false }
            var list = v.metadataPriority.filter { $0 != source }
            list.insert(source, at: 0)
            v.metadataPriority = list
        case "maxResolution":
            guard let n = value.intValue, n > 0 else { return false }
            v.maxStreamResolution = n
        case "excludeCam":
            guard let b = value.boolValue else { return false }
            v.excludeCam = b
        case "streamSort":
            guard let s = value.stringValue, let sort = StreamSort(rawValue: s) else { return false }
            v.streamSort = sort
        case "autoplayNext":
            guard let b = value.boolValue else { return false }
            v.autoplayNext = b
        case "resumePlayback":
            guard let b = value.boolValue else { return false }
            v.resumePlayback = b
        case "seekStep":
            guard let n = value.intValue, n > 0, n <= 600 else { return false }
            v.seekStep = n
        case "audioLanguage":
            guard let s = value.stringValue else { return false }
            v.preferredAudioLanguage = s
        case "subtitleLanguage":
            guard let s = value.stringValue else { return false }
            v.preferredSubtitleLanguage = s
        case "autoSubtitles":
            guard let b = value.boolValue else { return false }
            v.autoSubtitles = b
        case "subtitleScale":
            guard let d = value.doubleValue, d >= 0.3, d <= 4 else { return false }
            v.subtitleScale = d
        case "hideAdult":
            guard let b = value.boolValue else { return false }
            v.hideAdult = b
        case "trailerAutoplay":
            guard let b = value.boolValue else { return false }
            v.trailerAutoplay = b
        case "torrentMode":
            #if os(tvOS)
            return false
            #else
            guard let s = value.stringValue, let mode = TorrentMode(rawValue: s) else { return false }
            if mode == .embedded, !Platform.supportsEmbeddedTorrents { return false }
            v.torrentMode = mode
            #endif
        case "remoteTorrServer":
            guard let s = value.stringValue else { return false }
            // Never wipe this device's TorrServer just because the sender has none.
            if s.isEmpty, !v.remoteTorrServerURL.isEmpty { return false }
            v.remoteTorrServerURL = s
        default:
            return false
        }
        return true
    }

    // MARK: Applying server records

    /// A profile library being edited while a batch of records is applied.
    @MainActor
    final class LibraryBatch {
        var lib: LibraryStore.SyncLibrary
        var dirty = false
        var sortFavorites = false
        /// canonical full key → local progress keys
        var progress: [String: [String]] = [:]
        /// canonical full key → local watched keys
        var watched: [String: [String]] = [:]
        /// item key → favorite item ids
        var favorites: [String: [String]] = [:]
        /// item key → an item this device already has
        var items: [String: MediaItem] = [:]

        init(lib: LibraryStore.SyncLibrary) {
            self.lib = lib
            for (localKey, p) in lib.progress {
                guard let itemKey = SyncKeys.itemKey(p.item) else { continue }
                let full = p.episode.map { itemKey + SyncKeys.episodeSuffix(season: $0.season, episode: $0.episode) } ?? itemKey
                progress[full, default: []].append(localKey)
                if items[itemKey] == nil { items[itemKey] = p.item }
            }
            for f in lib.favorites {
                guard let itemKey = SyncKeys.itemKey(f) else { continue }
                favorites[itemKey, default: []].append(f.id)
                items[itemKey] = f
            }
        }
    }

    func apply(_ records: [SyncRecord]) {
        let priority: [String: Int] = ["profiles": 0, "servers": 1, "secrets": 2, "settings": 3, "addons": 4]
        let sorted = records.sorted {
            let a = priority[$0.collection] ?? 5, b = priority[$1.collection] ?? 5
            return a != b ? a < b : $0.rev < $1.rev
        }
        var batches: [UUID: LibraryBatch] = [:]
        var settings: AppSettings.Values?
        var addonOrders: [(url: String, order: Int)] = []
        var reactivate: Set<UUID> = []
        var traktToken: String?
        var addonsChanged = false

        func batch(_ profileKey: String) -> LibraryBatch? {
            guard let id = profileID(forKey: profileKey) else { return nil }
            if let b = batches[id] { return b }
            let b = LibraryBatch(lib: LibraryStore.shared.syncLibrary(for: id))
            // Watched marks need the canonical resolution used when building records.
            for localKey in b.lib.watched {
                if let c = b.lib.watchedCanonical[localKey] ?? state.legacyWatched["\(id.uuidString)|\(localKey)"] {
                    b.watched[c, default: []].append(localKey)
                } else if let c = SyncKeys.legacyKey(forLocalKey: localKey, serverIDs: DispatcharrStore.shared.servers.map(\.id)) {
                    b.watched[c, default: []].append(localKey)
                }
            }
            batches[id] = b
            return b
        }

        for r in sorted {
            if r.collection == "secrets", !hasSecretsScope { continue }
            let key = Self.recordKey(r.collection, r.id)
            if let known = state.known[key], r.updatedAt <= known.t { continue }
            if !r.deleted, r.data == nil { continue }
            let data = r.data ?? .null

            switch r.collection {
            case "progress", "watched", "favorites":
                guard let bar = r.id.firstIndex(of: "|") else { break }
                let pk = String(r.id[..<bar])
                let canonical = String(r.id[r.id.index(after: bar)...])
                guard let b = batch(pk) else { break }
                switch r.collection {
                case "progress": applyProgress(b, canonical, r, data)
                case "watched": applyWatched(b, canonical, deleted: r.deleted)
                default: applyFavorite(b, canonical, r, data)
                }

            case "channels":
                let parts = r.id.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 3, let channelID = Int(parts[2]),
                      parts[1] == DispatcharrStore.shared.activeServer?.id.uuidString.lowercased(),
                      let b = batch(parts[0]) else { break }
                let favorite = !r.deleted && (data["favorite"]?.boolValue ?? true)
                if favorite {
                    if !b.lib.favoriteChannelIDs.contains(channelID) { b.lib.favoriteChannelIDs.append(channelID); b.dirty = true }
                } else if b.lib.favoriteChannelIDs.contains(channelID) {
                    b.lib.favoriteChannelIDs.removeAll { $0 == channelID }
                    b.dirty = true
                }

            case "profiles":
                applyProfile(r, data)

            case "servers":
                guard let id = UUID(uuidString: r.id) else { break }
                if r.deleted {
                    DispatcharrStore.shared.removeSynced(id)
                } else {
                    let server = DispatcharrServer(id: id, name: data["name"]?.stringValue ?? "Dispatcharr",
                                                   baseURL: data["url"]?.stringValue ?? "", username: data["username"]?.stringValue ?? "",
                                                   authMode: Self.authMode(data["authMode"]?.stringValue))
                    DispatcharrStore.shared.upsertSynced(server, order: data["order"]?.intValue)
                }

            case "secrets":
                applySecret(r, data, reactivate: &reactivate, traktToken: &traktToken)

            case "settings":
                var values = settings ?? AppSettings.shared.values
                if !r.deleted, let value = data["value"], applySetting(r.id, value, to: &values) { settings = values }

            case "addons":
                let url = r.id
                let manager = AddonManager.shared
                let installed = manager.addons.first { $0.manifestURL.absoluteString == url }
                if r.deleted {
                    state.pendingAddons[url] = nil
                    if let installed { manager.remove(installed); addonsChanged = true }
                } else {
                    let enabled = data["enabled"]?.boolValue ?? true
                    let order = data["order"]?.intValue
                    if let installed {
                        if installed.enabled != enabled { manager.setEnabled(installed, enabled); addonsChanged = true }
                        if let order { addonOrders.append((url, order)) }
                    } else {
                        state.pendingAddons[url] = PendingAddon(enabled: enabled, order: order)
                    }
                }

            default:
                break
            }
            state.known[key] = Known(h: r.deleted ? "" : Self.fingerprint(data), t: r.updatedAt, d: r.deleted)
            outbox[key] = nil
        }

        // Write everything back in one go per store.
        for (id, b) in batches where b.dirty {
            if b.sortFavorites {
                let dates = b.lib.favoriteDates
                let order = Dictionary(b.lib.favorites.enumerated().map { pair in (pair.element.id, pair.offset) },
                                       uniquingKeysWith: { first, _ in first })
                b.lib.favorites.sort { a, c in
                    let da = dates[a.id] ?? 0, dc = dates[c.id] ?? 0
                    return da != dc ? da > dc : (order[a.id] ?? 0) < (order[c.id] ?? 0)
                }
            }
            LibraryStore.shared.applySyncLibrary(b.lib, for: id)
        }
        if let settings { AppSettings.shared.values = settings }
        if !addonOrders.isEmpty { reorderAddons(addonOrders); addonsChanged = true }
        for id in reactivate where DispatcharrStore.shared.activeServer?.id == id {
            DispatcharrStore.shared.activate(id)
        }
        rebaseline()
        if !batches.isEmpty || addonsChanged { SnapshotPublisher.schedule() }

        if let traktToken {
            Task { [weak self] in
                await TraktService.shared.importToken(traktToken)
                self?.rebaseline(only: ["secrets"])
            }
        }
        if !state.pendingAddons.isEmpty { installPendingAddons() }
    }

    private func applyProgress(_ b: LibraryBatch, _ canonical: String, _ r: SyncRecord, _ data: SyncJSON) {
        let existing = b.progress[canonical] ?? []
        if r.deleted {
            for k in existing { b.lib.progress[k] = nil }
            b.progress[canonical] = nil
            if !existing.isEmpty { b.dirty = true }
            return
        }
        guard let position = data["position"]?.doubleValue, let duration = data["duration"]?.doubleValue else { return }
        let split = SyncKeys.splitEpisode(canonical)
        let itemKey = split?.item ?? canonical
        let current = existing.compactMap { b.lib.progress[$0] }.max { $0.updatedAt < $1.updatedAt }
        guard let item = current?.item ?? b.items[itemKey] ?? mediaItem(from: data["item"], key: itemKey) else { return }
        var episode: EpisodeRef?
        if let split {
            episode = current?.episode ?? episodeRef(data["episode"], season: split.season, episode: split.episode,
                                                     item: item, senderOrigin: data["item"]?["origin"])
        }
        for k in existing { b.lib.progress[k] = nil }
        let localKey = LibraryStore.key(item, episode)
        b.lib.progress[localKey] = WatchProgress(key: localKey, item: item, episode: episode, position: position, duration: duration,
                                                 updatedAt: Date(timeIntervalSince1970: TimeInterval(r.updatedAt) / 1000))
        b.progress[canonical] = [localKey]
        if b.items[itemKey] == nil { b.items[itemKey] = item }
        b.dirty = true
    }

    private func applyWatched(_ b: LibraryBatch, _ canonical: String, deleted: Bool) {
        let existing = b.watched[canonical] ?? []
        if deleted {
            for k in existing {
                b.lib.watched.remove(k)
                b.lib.watchedCanonical[k] = nil
            }
            b.watched[canonical] = nil
            if !existing.isEmpty { b.dirty = true }
            return
        }
        guard existing.isEmpty else { return }
        let split = SyncKeys.splitEpisode(canonical)
        let itemKey = split?.item ?? canonical
        let itemID = b.items[itemKey]?.id ?? SyncKeys.localItemID(forItemKey: itemKey)
        let localKey = split.map { "\(itemID)#\($0.season)x\($0.episode)" } ?? itemID
        b.lib.watched.insert(localKey)
        b.lib.watchedCanonical[localKey] = canonical
        b.watched[canonical] = [localKey]
        b.dirty = true
    }

    private func applyFavorite(_ b: LibraryBatch, _ itemKey: String, _ r: SyncRecord, _ data: SyncJSON) {
        let existing = b.favorites[itemKey] ?? []
        if r.deleted {
            guard !existing.isEmpty else { return }
            b.lib.favorites.removeAll { existing.contains($0.id) }
            for id in existing { b.lib.favoriteDates[id] = nil }
            b.favorites[itemKey] = nil
            b.dirty = true
            return
        }
        let added = data["addedAt"]?.doubleValue ?? Double(r.updatedAt)
        if let first = existing.first {
            b.lib.favoriteDates[first] = added
        } else {
            guard let item = b.items[itemKey] ?? mediaItem(from: data["item"], key: itemKey) else { return }
            if !b.lib.favorites.contains(where: { $0.id == item.id }) { b.lib.favorites.append(item) }
            b.lib.favoriteDates[item.id] = added
            b.favorites[itemKey] = [item.id]
            if b.items[itemKey] == nil { b.items[itemKey] = item }
        }
        b.sortFavorites = true
        b.dirty = true
    }

    private func applyProfile(_ r: SyncRecord, _ data: SyncJSON) {
        let store = ProfileStore.shared
        if r.deleted {
            // The default profile can't be deleted from another device.
            if r.id != "default", let id = UUID(uuidString: r.id), id != store.profiles.first?.id { store.deleteSynced(id) }
            return
        }
        guard let id = profileID(forKey: r.id) else { return }
        var profile = store.profiles.first { $0.id == id }
            ?? UserProfile(id: id, name: "Profile", emoji: "🍿", colorIndex: 0, isKids: false, allowedCategoryIDs: [])
        if let name = data["name"]?.stringValue, !name.isEmpty { profile.name = name }
        if let avatar = data["avatar"]?.stringValue, !avatar.isEmpty { profile.emoji = avatar }
        if let color = data["color"]?.intValue { profile.colorIndex = max(0, color) % UserProfile.colorCount }
        if let kids = data["kids"]?.boolValue { profile.isKids = kids }
        store.upsertSynced(profile)
    }

    private func applySecret(_ r: SyncRecord, _ data: SyncJSON, reactivate: inout Set<UUID>, traktToken: inout String?) {
        let value = r.deleted ? "" : (data["value"]?.stringValue ?? "")
        let settings = AppSettings.shared
        switch r.id {
        case "key:tmdb": if settings.tmdbKey != value { settings.tmdbKey = value }
        case "key:omdb": if settings.omdbKey != value { settings.omdbKey = value }
        case "key:fanart": if settings.fanartKey != value { settings.fanartKey = value }
        case "parentPin":
            if ProfileStore.shared.parentPIN != value { ProfileStore.shared.parentPIN = value }
        case "trakt":
            if r.deleted {
                if TraktService.shared.isSignedIn { TraktService.shared.signOut() }
            } else if case .object = data, let encoded = try? JSONEncoder().encode(data),
                      let raw = String(data: encoded, encoding: .utf8), raw != TraktService.shared.exportedToken {
                traktToken = raw
            }
        default:
            if r.id.hasPrefix("server:"), let id = UUID(uuidString: String(r.id.dropFirst("server:".count))) {
                // Secrets are stored by server id, so they can arrive before the server itself.
                let server = DispatcharrStore.shared.servers.first { $0.id == id }
                    ?? DispatcharrServer(id: id, name: "", baseURL: "", username: "")
                let xc = r.deleted ? "" : (data["xcPassword"]?.stringValue ?? "")
                let web = r.deleted ? "" : (data["webPassword"]?.stringValue ?? "")
                let key = r.deleted ? "" : (data["apiKey"]?.stringValue ?? "")
                var changed = false
                if server.xcPassword != xc { server.xcPassword = xc; changed = true }
                if server.webPassword != web { server.webPassword = web; changed = true }
                if server.apiKey != key { server.apiKey = key; changed = true }
                if changed { reactivate.insert(id) }
            } else if r.id.hasPrefix("pin:") {
                let pk = String(r.id.dropFirst("pin:".count))
                if let id = profileID(forKey: pk) {
                    // Same Keychain item as UserProfile.pin.
                    let account = "profile.pin.\(id)"
                    if (Keychain.get(account) ?? "") != value { Keychain.set(value, for: account) }
                }
            }
        }
    }

    // MARK: Addons

    private func reorderAddons(_ orders: [(url: String, order: Int)]) {
        let manager = AddonManager.shared
        for entry in orders.sorted(by: { $0.order < $1.order }) {
            guard let from = manager.addons.firstIndex(where: { $0.manifestURL.absoluteString == entry.url }) else { continue }
            let target = max(0, min(entry.order, manager.addons.count - 1))
            guard target != from else { continue }
            manager.move(from: IndexSet(integer: from), to: target > from ? target + 1 : target)
        }
    }

    /// Installs addons added on another device (each client fetches the manifest itself).
    func installPendingAddons() {
        let pending = state.pendingAddons
        guard !pending.isEmpty else { return }
        Task { [weak self] in
            for (url, info) in pending.sorted(by: { ($0.value.order ?? 0) < ($1.value.order ?? 0) }) {
                guard let self, self.isSignedIn, self.state.pendingAddons[url] != nil else { continue }
                let manager = AddonManager.shared
                if !manager.addons.contains(where: { $0.manifestURL.absoluteString == url }) {
                    guard let addon = try? await manager.install(from: url) else { continue }
                    if addon.enabled != info.enabled { manager.setEnabled(addon, info.enabled) }
                }
                self.state.pendingAddons[url] = nil
                if let order = info.order { self.reorderAddons([(url, order)]) }
                // The installed copy is what the server has: don't upload it again.
                self.rebaseline(only: ["addons"])
            }
        }
    }
}
