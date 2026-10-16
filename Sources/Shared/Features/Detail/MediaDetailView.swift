import SwiftUI

@MainActor
@Observable
final class DetailModel {
    var details: MediaDetails
    var loading = true
    var season: Int?
    var episodes: [EpisodeRef] = []
    var loadingEpisodes = false
    var sources: SourcesModel?

    init(item: MediaItem) { 
        self.details = MediaDetails(item: item) 
    }

    func load() async {
        guard loading else { return }
        let d = await MetadataService.shared.details(for: details.item)
        details = d
        loading = false
        Task { await resolveCastPhotos() }
        if d.item.type == .series {
            let lib = LibraryStore.shared
            let resumeSeason = lib.latestEpisodeProgress(for: d.item)?.episode?.season
            let first = d.seasons.first { $0.number > 0 }?.number ?? d.seasons.first?.number
            await selectSeason(resumeSeason ?? first ?? 1)
        } else if d.item.type == .movie {
            let s = SourcesModel(item: d.item, episode: nil)
            sources = s
            await s.load()
        }
    }

    func resolveCastPhotos() async {
        let snapshot = details
        let resolved = await MetadataService.shared.castWithPhotos(for: snapshot)
        guard resolved != details.cast, details.item.id == snapshot.item.id else { return }
        details.cast = resolved
    }

    func selectSeason(_ number: Int) async {
        season = number
        loadingEpisodes = true
        let eps = await MetadataService.shared.episodes(for: details, season: number)
        if season == number { episodes = eps }
        loadingEpisodes = false
    }

    func upcoming(after episode: EpisodeRef) -> [EpisodeRef] {
        guard let i = episodes.firstIndex(where: { $0.id == episode.id }) else { return [] }
        return Array(episodes.dropFirst(i + 1))
    }

    func nextEpisodeToWatch() -> EpisodeRef? {
        let lib = LibraryStore.shared
        if let p = lib.latestEpisodeProgress(for: details.item), let ep = p.episode {
            if !p.isFinished, let match = episodes.first(where: { $0.season == ep.season && $0.episode == ep.episode }) { return match }
            if p.isFinished, let index = episodes.firstIndex(where: { $0.id == ep.id }),
               let next = episodes.dropFirst(index + 1).first(where: { !lib.isWatched(details.item, episode: $0) }) { return next }
        }
        return episodes.first { !lib.isWatched(details.item, episode: $0) } ?? episodes.first
    }
}

public struct MediaDetailView: View {
    let media: MediaItem

    // Stremio Animated Title States
    @State private var animateTitle: Bool = false
    @State private var ambientGlow: Bool = false

    public init(media: MediaItem) {
        self.media = media
    }

    public var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Hero Backdrop with Stremio-Style Animated Shadowed Title
                    ZStack(alignment: .bottomLeading) {
                        TrailerBackdrop(media: media)
                            .frame(height: 340)
                            .clipped()

                        // Dark Stremio vignette gradient overlay
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color.black.opacity(0.4),
                                Color.black.opacity(0.85),
                                Color.black
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )

                        VStack(alignment: .leading, spacing: 10) {
                            // Logo or Stremio-Style Animated Title Text
                            if let logoURL = media.logoURL {
                                AsyncImage(url: logoURL) { image in
                                    image
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxHeight: 90)
                                        .shadow(color: .black.opacity(0.8), radius: 8, x: 0, y: 4)
                                        .scaleEffect(animateTitle ? 1.0 : 0.88)
                                        .opacity(animateTitle ? 1.0 : 0.0)
                                        .animation(.spring(response: 0.6, dampingFraction: 0.75), value: animateTitle)
                                } placeholder: {
                                    stremioShadowTitleView
                                }
                            } else {
                                stremioShadowTitleView
                            }

                            // Metadata Line (Year, Runtime, Content Rating)
                            HStack(spacing: 8) {
                                if let year = media.year {
                                    Text(String(year))
                                }
                                if let runtime = media.runtime {
                                    Text("• \(runtime)")
                                }
                                if let rating = media.contentRating {
                                    Text("• \(rating)")
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.white.opacity(0.18))
                                        .cornerRadius(4)
                                }
                            }
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.white.opacity(0.7))

                            // Genres
                            if let genres = media.genres, !genres.isEmpty {
                                Text(genres.joined(separator: " • "))
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.white.opacity(0.6))
                            }

                            // Rating Badges (IMDb & TMDB)
                            HStack(spacing: 10) {
                                if let imdbRating = media.imdbRating {
                                    HStack(spacing: 4) {
                                        Text("IMDb")
                                            .font(.system(size: 10, weight: .black))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 3)
                                            .background(Color(red: 0.96, green: 0.76, blue: 0.15))
                                            .foregroundColor(.black)
                                            .cornerRadius(3)

                                        Text(String(format: "%.1f", imdbRating))
                                            .font(.caption)
                                            .bold()
                                            .foregroundColor(.white)
                                    }
                                }

                                if let tmdbRating = media.tmdbRating {
                                    HStack(spacing: 4) {
                                        Text("TMDB")
                                            .font(.system(size: 10, weight: .black))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 3)
                                            .background(Color(red: 0.0, green: 0.8, blue: 0.7))
                                            .foregroundColor(.black)
                                            .cornerRadius(3)

                                        Text(String(format: "%.1f", tmdbRating))
                                            .font(.caption)
                                            .bold()
                                            .foregroundColor(.white)
                                    }
                                }
                            }
                            .padding(.top, 2)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 14)
                    }

                    // Stremio-Style Primary Play Action
                    HStack(spacing: 12) {
                        Button(action: {}) {
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 16, weight: .bold))
                                Text("Play")
                                    .font(.system(size: 17, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(red: 0.54, green: 0.35, blue: 0.95))
                            .cornerRadius(12)
                            .shadow(color: Color(red: 0.54, green: 0.35, blue: 0.95).opacity(0.4), radius: 10, x: 0, y: 4)
                        }
                    }
                    .padding(.horizontal, 20)

                    // Secondary Stremio Buttons
                    HStack(spacing: 10) {
                        ActionButton(icon: "plus", title: "My List")
                        ActionButton(icon: "play.rectangle", title: "Trailer")
                        ActionButton(icon: "list.bullet", title: "Sources")
                    }
                    .padding(.horizontal, 20)

                    // Overview Text
                    if let overview = media.overview {
                        Text(overview)
                            .font(.system(size: 15, weight: .regular))
                            .lineSpacing(4)
                            .foregroundColor(.white.opacity(0.82))
                            .lineLimit(4)
                            .padding(.horizontal, 20)
                    }
                }
            }
            .ignoresSafeArea(.container, edges: .top)

            // Dynamic Island Safe Top Header Bar
            HStack {
                Button(action: {
                    // Back Navigation Action
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .padding(11)
                        .background(Circle().fill(Color.black.opacity(0.65)))
                        .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 54) // Dynamic Island inset offset
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.7)) {
                animateTitle = true
            }
            
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                ambientGlow = true
            }
        }
    }

    // Professional Shadowed Stremio Title View
    private var stremioShadowTitleView: some View {
        let cleanTitle = media.title
            .replacingOccurrences(of: "-", with: " ")
            .capitalized

        return Text(cleanTitle)
            .font(.system(size: 34, weight: .heavy, design: .default))
            .tracking(-0.5)
            .foregroundColor(.white)
            .shadow(color: Color.black.opacity(0.95), radius: 10, x: 0, y: 5)
            .shadow(color: Color.black.opacity(0.8), radius: 3, x: 0, y: 1)
            .shadow(
                color: Color(red: 0.54, green: 0.35, blue: 0.95).opacity(ambientGlow ? 0.6 : 0.15),
                radius: ambientGlow ? 16 : 6,
                x: 0,
                y: 0
            )
            .offset(y: animateTitle ? 0 : 25)
            .scaleEffect(animateTitle ? 1.0 : 0.92, anchor: .bottomLeading)
            .opacity(animateTitle ? 1.0 : 0.0)
    }
}

struct ActionButton: View {
    let icon: String
    let title: String

    var body: some View {
        Button(action: {}) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.12))
            .cornerRadius(10)
        }
    }
}