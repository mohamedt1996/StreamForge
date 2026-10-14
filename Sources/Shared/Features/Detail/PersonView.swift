import SwiftUI

/// Actor / crew page from TMDB: photo, bio, known-for and a filmography marked with what is
/// on your Dispatcharr server or resolvable through your addons.
struct PersonView: View {
    var personID: Int
    var name: String
    @Environment(AppRouter.self) private var router
    @Environment(DispatcharrStore.self) private var store
    @State private var person: TMDBClient.PersonDetails?
    @State private var credits: [TMDBClient.PersonCredit] = []
    @State private var loading = true
    @State private var error: String?
    @State private var sort: Sort = .popular
    @State private var expandedBio = false

    enum Sort: String, CaseIterable, Identifiable {
        case popular = "Popular", newest = "Newest"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let bio = person?.biography, !bio.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(bio).font(.body).foregroundStyle(.white.opacity(0.85))
                            .lineLimit(expandedBio ? nil : 6)
                            .frame(maxWidth: 820, alignment: .leading)
                        if bio.count > 320 {
                            Button(expandedBio ? "Less" : "More") { withAnimation { expandedBio.toggle() } }
                                .font(.footnote.weight(.semibold)).buttonStyle(.plain).foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(.horizontal, Theme.gutter)
                }
                if !knownFor.isEmpty {
                    Shelf(title: "Known For", items: knownFor) { c in creditButton(c) }
                }
                if !credits.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            SectionHeader(title: "Filmography", subtitle: "\(credits.count) titles")
                            Picker("Sort", selection: $sort) {
                                ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 260)
                            .padding(.trailing, Theme.gutter)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.posterWidth, maximum: Theme.posterWidth * 1.25), spacing: gridSpacing, alignment: .top)],
                                  alignment: .leading, spacing: gridSpacing * 1.5) {
                            ForEach(sorted) { c in creditButton(c) }
                        }
                        .padding(.horizontal, Theme.gutter)
                    }
                }
                if loading { ProgressView().frame(maxWidth: .infinity).padding() }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Theme.secondaryText).padding(.horizontal, Theme.gutter)
                }
                Color.clear.frame(height: 30)
            }
            .padding(.top, 12)
        }
        .screenBackground()
        .navigationTitle(person?.name ?? name)
        .task { await load() }
    }

    private var gridSpacing: CGFloat {
        #if os(tvOS)
        return 48
        #else
        return 12
        #endif
    }

    private var photoSize: CGFloat {
        #if os(tvOS)
        return 260
        #else
        return 130
        #endif
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            ZStack {
                if let url = photoURL {
                    RemoteImage(url: url, placeholderSymbol: "person.fill")
                } else {
                    // Nobody has a photo: a large initials tile instead of an empty frame.
                    ZStack {
                        Theme.accentGradient.opacity(0.35)
                        Text(CastAvatar.initials(person?.name ?? name))
                            .font(.system(size: photoSize * 0.3, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .frame(width: photoSize, height: photoSize * 1.5)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                Text(person?.name ?? name).font(.largeTitle.weight(.heavy)).lineLimit(2)
                if let dept = person?.known_for_department { Text(dept).font(.headline).foregroundStyle(Theme.accent) }
                if let born = person?.birthday {
                    Text("Born \(born)\(person?.place_of_birth.map { " · \($0)" } ?? "")")
                        .font(.subheadline).foregroundStyle(Theme.secondaryText)
                }
                if let died = person?.deathday { Text("Died \(died)").font(.subheadline).foregroundStyle(Theme.secondaryText) }
                let onServer = credits.filter { serverItem(for: $0) != nil }.count
                if onServer > 0 {
                    Label("\(onServer) on your server", systemImage: "server.rack")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.gutter)
    }

    /// TMDB profile (or the first of its profile images), else the face from the cast card.
    private var photoURL: URL? {
        TMDBClient.image(person?.profile_path, size: "h632")
            ?? TMDBClient.image(person?.images?.profiles?.first?.file_path, size: "h632")
            ?? CastPhotoMemory.photo(named: person?.name ?? name)
    }

    private var knownFor: [TMDBClient.PersonCredit] {
        Array(credits.filter { $0.poster != nil }.sorted { $0.popularity > $1.popularity }.prefix(12))
    }

    private var sorted: [TMDBClient.PersonCredit] {
        switch sort {
        case .popular: return credits.sorted { $0.popularity > $1.popularity }
        case .newest: return credits.sorted { ($0.date ?? "") > ($1.date ?? "") }
        }
    }

    private var addonsCanResolve: Bool {
        AddonManager.shared.enabled.contains { $0.manifest.hasStreams }
    }

    private func serverItem(for c: TMDBClient.PersonCredit) -> MediaItem? {
        guard let serverID = store.activeServer?.id else { return nil }
        if c.mediaType == "tv" {
            return store.matchSeries(tmdbID: c.tmdbID, imdbID: nil, title: c.title).map { $0.mediaItem(serverID: serverID) }
        }
        return store.matchMovie(tmdbID: c.tmdbID, imdbID: nil, title: c.title, year: c.year).map { $0.mediaItem(serverID: serverID) }
    }

    private func creditButton(_ c: TMDBClient.PersonCredit) -> some View {
        let server = serverItem(for: c)
        return Button { router.push(.detail(server ?? c.mediaItem)) } label: {
            VStack(alignment: .leading, spacing: 4) {
                PosterCard(item: c.mediaItem)
                    .overlay(alignment: .topLeading) {
                        if server != nil {
                            Pill(text: "ON SERVER", color: Color.green.opacity(0.85), foreground: .black, icon: "server.rack").padding(6)
                        } else if addonsCanResolve {
                            Pill(text: "ADDONS", color: .black.opacity(0.6), icon: "puzzlepiece.extension").padding(6)
                        }
                    }
                if let role = c.role, !role.isEmpty {
                    Text(role).font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(1)
                        .frame(width: Theme.posterWidth, alignment: .leading)
                }
            }
        }
        .cardButtonStyle()
    }

    private func load() async {
        guard person == nil else { return }
        let tmdb = MetadataService.shared.tmdb
        guard tmdb.isConfigured else {
            loading = false
            error = "Add a TMDB key in Settings → Metadata to see cast pages."
            return
        }
        do {
            var id = personID
            if id <= 0 {
                // Cast from provider strings has no TMDB id: search by name first (exact name,
                // actors first, most popular; same rule the cast photos use).
                let results = try await tmdb.searchPerson(name)
                guard let match = CastPhotoResolver.pick(results, for: CastPhotoResolver.normalize(name)) ?? results.first.map({
                    CastPhotoResolver.Match(id: $0.id, name: $0.name, photo: nil)
                }) else {
                    loading = false
                    error = "Couldn't find \(name) on TMDB."
                    return
                }
                id = match.id
            }
            let p = try await tmdb.person(id: id)
            person = p
            var seen = Set<String>()
            let all = (p.combined_credits?.cast?.elements ?? []) + (p.combined_credits?.crew?.elements ?? [])
            credits = KidsFilterCredits.apply(all.filter { c in
                guard !c.title.isEmpty, c.mediaType == "movie" || c.mediaType == "tv" else { return false }
                // Talk shows and award ceremonies clutter filmographies.
                if c.genreIDs.contains(10767) || c.genreIDs.contains(10763) { return false }
                return seen.insert("\(c.mediaType)-\(c.tmdbID)").inserted
            })
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

/// Kids profiles only see family-friendly credits.
private enum KidsFilterCredits {
    @MainActor
    static func apply(_ credits: [TMDBClient.PersonCredit]) -> [TMDBClient.PersonCredit] {
        guard ProfileStore.shared.isKidsMode else { return credits }
        return credits.filter { KidsFilter.allows($0.mediaItem) }
    }
}
