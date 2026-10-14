import Foundation
import Observation

struct CatalogEntry: Identifiable {
    var addon: InstalledAddon
    var catalog: StremioManifest.Catalog
    var id: String { "\(addon.id)/\(catalog.identity)" }
}

/// Installs, orders and queries Stremio addons.
@MainActor
@Observable
final class AddonManager {
    static let shared = AddonManager()

    static let cinemetaURL = "https://v3-cinemeta.strem.io/manifest.json"
    static let openSubtitlesURL = "https://opensubtitles-v3.strem.io/manifest.json"

    private(set) var addons: [InstalledAddon] = []
    private let http = HTTPClient(timeout: 20)

    var enabled: [InstalledAddon] { addons.filter(\.enabled) }

    private init() {
        if let saved = FileStore.load([InstalledAddon].self, "addons.json") {
            addons = saved
        } else {
            Task { await installDefaults() }
        }
    }

    private func save() {
        FileStore.save(addons, "addons.json", mirrorToDefaults: true)
        CloudSync.shared.schedulePush()
        ServerSync.shared.noteLocalChange()
    }

    private func installDefaults() async {
        for url in [Self.cinemetaURL, Self.openSubtitlesURL] {
            _ = try? await install(from: url)
        }
    }

    /// Accepts https://…/manifest.json, stremio://…/manifest.json, or a bare addon base URL.
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmed
        if s.lowercased().hasPrefix("stremio://") { s = "https://" + s.dropFirst("stremio://".count) }
        if !s.contains("://") { s = "https://" + s }
        guard var url = URL(string: s) else { return nil }
        if url.lastPathComponent != "manifest.json" { url = url.appendingRawPath("manifest.json") }
        return url
    }

    @discardableResult
    func install(from raw: String) async throws -> InstalledAddon {
        guard let manifestURL = Self.normalize(raw) else { throw HTTPError.badURL(raw) }
        let manifest = try await http.get(StremioManifest.self, manifestURL)
        if manifest.behaviorHints?.configurationRequired == true {
            throw HTTPError.transport("“\(manifest.name)” must be configured on its website first. Paste the configured manifest link instead.")
        }
        let base = manifestURL.deletingLastPathComponent()
        let addon = InstalledAddon(baseURL: base, manifest: manifest)
        if let i = addons.firstIndex(where: { $0.id == addon.id }) {
            var updated = addon
            updated.enabled = addons[i].enabled
            addons[i] = updated
        } else {
            addons.append(addon)
        }
        save()
        return addon
    }

    func remove(_ addon: InstalledAddon) {
        addons.removeAll { $0.id == addon.id }
        save()
    }

    func setEnabled(_ addon: InstalledAddon, _ on: Bool) {
        guard let i = addons.firstIndex(where: { $0.id == addon.id }) else { return }
        addons[i].enabled = on
        save()
    }

    func move(from: IndexSet, to: Int) {
        addons.move(fromOffsets: from, toOffset: to)
        save()
    }

    /// Adds addons from a backup / another device, keeping the incoming order for new ones.
    func importAddons(_ incoming: [InstalledAddon]) {
        for addon in incoming {
            if let i = addons.firstIndex(where: { $0.id == addon.id }) {
                addons[i] = addon
            } else {
                addons.append(addon)
            }
        }
        save()
    }

    func refreshManifests() async {
        for addon in addons {
            if let m = try? await http.get(StremioManifest.self, addon.manifestURL),
               let i = addons.firstIndex(where: { $0.id == addon.id }) {
                addons[i].manifest = m
            }
        }
        save()
    }

    // MARK: Resource requests

    private func resourceURL(_ addon: InstalledAddon, _ resource: String, _ type: String, _ id: String, extra: [String: String] = [:]) -> URL {
        let encID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?&"))) ?? id
        var path = "\(resource)/\(type)/\(encID)"
        if !extra.isEmpty {
            let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=/?+"))
            let parts = extra.sorted { $0.key < $1.key }.map { k, v in
                "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
            }
            path += "/" + parts.joined(separator: "&")
        }
        return addon.baseURL.appendingRawPath(path + ".json")
    }

    var catalogs: [CatalogEntry] {
        enabled.flatMap { a in (a.manifest.catalogs ?? []).filter { !$0.requiresExtra }.map { CatalogEntry(addon: a, catalog: $0) } }
    }

    var searchableCatalogs: [CatalogEntry] {
        enabled.flatMap { a in (a.manifest.catalogs ?? []).filter(\.supportsSearch).map { CatalogEntry(addon: a, catalog: $0) } }
    }

    func catalog(_ addon: InstalledAddon, _ catalog: StremioManifest.Catalog, extra: [String: String] = [:]) async throws -> [StremioMetaPreview] {
        struct Res: Decodable { var metas: LossyArray<StremioMetaPreview>? }
        let res = try await http.get(Res.self, resourceURL(addon, "catalog", catalog.type, catalog.id, extra: extra))
        return res.metas?.elements ?? []
    }

    func search(_ query: String) async -> [(addon: InstalledAddon, catalog: StremioManifest.Catalog, metas: [StremioMetaPreview])] {
        let targets = searchableCatalogs
        return await withTaskGroup(of: (Int, [StremioMetaPreview]).self) { group in
            for (i, t) in targets.enumerated() {
                group.addTask { [self] in
                    let metas = (try? await self.catalog(t.addon, t.catalog, extra: ["search": query])) ?? []
                    return (i, metas)
                }
            }
            var results: [(Int, [StremioMetaPreview])] = []
            for await r in group where !r.1.isEmpty { results.append(r) }
            return results.sorted { $0.0 < $1.0 }.map { (targets[$0.0].addon, targets[$0.0].catalog, $0.1) }
        }
    }

    /// Fetches a full meta from the first addon that supports it (Cinemeta for tt ids).
    func meta(type: String, id: String, preferredAddonID: String? = nil) async -> (InstalledAddon, StremioMetaPreview)? {
        struct Res: Decodable { var meta: StremioMetaPreview? }
        var candidates = enabled.filter { $0.manifest.supports("meta", type: type, id: id) }
        if let preferredAddonID, let i = candidates.firstIndex(where: { $0.id == preferredAddonID }) {
            candidates.insert(candidates.remove(at: i), at: 0)
        }
        for addon in candidates {
            if let res = try? await http.get(Res.self, resourceURL(addon, "meta", type, id)), let meta = res.meta {
                return (addon, meta)
            }
        }
        return nil
    }

    /// Streams from every enabled addon, fetched in parallel; slow addons don't block fast ones
    /// because results are delivered incrementally.
    func streams(type: String, id: String, onBatch: @escaping @MainActor (InstalledAddon, [StremioStream]) -> Void) async {
        struct Res: Decodable { var streams: LossyArray<StremioStream>? }
        let targets = enabled.filter { $0.manifest.supports("stream", type: type, id: id) }
        await withTaskGroup(of: Void.self) { group in
            for addon in targets {
                let url = resourceURL(addon, "stream", type, id)
                group.addTask { [http] in
                    let list = (try? await http.get(Res.self, url, timeout: 25))?.streams?.elements ?? []
                    await onBatch(addon, list)
                }
            }
        }
    }

    func subtitles(type: String, id: String, videoHash: String? = nil, videoSize: Int64? = nil, filename: String? = nil) async -> [StremioSubtitle] {
        struct Res: Decodable { var subtitles: LossyArray<StremioSubtitle>? }
        let targets = enabled.filter { $0.manifest.supports("subtitles", type: type, id: id) }
        var extra: [String: String] = [:]
        if let videoHash { extra["videoHash"] = videoHash }
        if let videoSize { extra["videoSize"] = String(videoSize) }
        if let filename { extra["filename"] = filename }
        let urls = targets.map { resourceURL($0, "subtitles", type, id, extra: extra) }
        return await withTaskGroup(of: [StremioSubtitle].self) { group in
            for url in urls {
                group.addTask { [http] in (try? await http.get(Res.self, url))?.subtitles?.elements ?? [] }
            }
            var all: [StremioSubtitle] = []
            for await list in group { all.append(contentsOf: list) }
            var seen = Set<String>()
            return all.filter { seen.insert($0.url.absoluteString).inserted }
        }
    }
}
