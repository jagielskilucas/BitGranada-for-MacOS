//
//  HomeView.swift / SearchView.swift / LibraryView.swift / ExploreView.swift
//  BitChord for macOS
//
//  The four tabs. Layout, metrics and copy follow the phone's screens
//  (sharedUi HomeScreen.kt, SearchScreen.kt, LibraryScreen.kt), widened for a
//  desktop window and given pointer affordances.
//

import SwiftUI
import AppKit

// MARK: - Home

struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryStore
    var theme: BitTheme

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 96)

                // The mixes row opens the home: it is the personalised list the
                // listener reaches for, and it used to sit at the very bottom.
                ForEach(mixShelves) { shelf in
                    shelfView(shelf, hero: true)
                }

                // Last.fm's account rows lead the home.
                ForEach(model.lastFMUserShelves) { shelf in
                    shelfView(shelf, hero: false)
                }

                // Built from the imported listening archive: no network needed,
                // and the rows are the listener's own history.
                if let taste = library.archiveTaste {
                    archiveRow("Para você", items: taste.tracks.prefix(16).map { track in
                        ShelfItem(
                            title: track.title,
                            subtitle: track.artist,
                            thumbnailURL: track.art,
                            videoId: track.id,
                            browseId: nil,
                            playlistId: nil,
                            duration: track.ms > 0 ? track.ms / 1000 : nil,
                            pageKind: nil
                        )
                    })
                    archiveRow("Seus artistas", items: taste.artists.prefix(16).compactMap { artist -> ShelfItem? in
                        guard let id = artist.id else { return nil }
                        return ShelfItem(title: artist.name, subtitle: "Artista",
                                         thumbnailURL: artist.art, videoId: nil,
                                         browseId: id, playlistId: nil, duration: nil,
                                         pageKind: .artist)
                    })
                    archiveRow("Com base no seu gosto", items: model.tasteRecommendations)
                    if let lastFM = model.lastFMShelf, !lastFM.items.isEmpty {
                        shelfView(lastFM, hero: false)
                    }
                    ForEach(topArtistShelves(taste), id: \.title) { shelf in
                        archiveRow(shelf.title, items: shelf.items)
                    }
                    archiveRow("Álbuns que você ouviu", items: taste.albums.prefix(16).compactMap { album -> ShelfItem? in
                        guard let id = album.id else { return nil }
                        return ShelfItem(title: album.name, subtitle: album.sub ?? "Álbum",
                                         thumbnailURL: album.art, videoId: nil,
                                         browseId: id, playlistId: nil, duration: nil,
                                         pageKind: .album)
                    })
                }

                if model.homeLoading && model.homeShelves.isEmpty {
                    homeSkeleton
                } else if let error = model.homeError, model.homeShelves.isEmpty {
                    MessageState(
                        title: "Couldn't reach YouTube Music",
                        subtitle: error,
                        theme: theme,
                        actionTitle: "Try again",
                        action: { model.refreshHome() }
                    )
                } else {
                    moodRow
                    ForEach(otherShelves) { shelf in
                        shelfView(shelf, hero: false)
                    }
                }
            }
            .padding(.bottom, 176)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .task {
            // Refreshes when stale; cheap no-op otherwise.
            await model.loadTasteRecommendations()
        }
        .tracksScrollDirection { up in
            guard model.isPlayerBarExpanded != up else { return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                model.isPlayerBarExpanded = up
            }
        }
    }

    /// The YouTube Music feed with the community/trending rows dropped: those
    /// are other people's playlists, not recommendations, and they crowded out
    /// the rows the listener's own history built.
    private var curatedShelves: [Shelf] {
        // Only other people's playlists are hidden now: "Em alta" and the video
        // rows are what the phone's home shows, and the listener wants them.
        // "Playlists em destaque para você" (paradas do YouTube) veio sem capa e
        // sem destino: sai da home.
        let banned = ["comunidade", "community", "destaque", "parada", "ranking"]
        let kept = model.homeShelves.filter { shelf in
            let title = shelf.title.lowercased()
            return !banned.contains { title.contains($0) }
        }
        // Mixes lead here too: in the feed they arrive near the bottom, and the
        // "Clássicos da madrugada" row is the one the listener opens first.
        return kept.sorted { a, b in isMixTitle(a.title) && !isMixTitle(b.title) }
    }

    /// The mix rows, wherever they came from (signed-in page or public feed).
    private var mixShelves: [Shelf] {
        var seen = Set<String>()
        return (model.highlightShelves + curatedShelves).filter { shelf in
            let lower = shelf.title.lowercased()
            guard !lower.contains("destaque"), !lower.contains("parada"),
                  !lower.contains("ranking") else { return false }
            guard isMixTitle(shelf.title) else { return false }
            if seen.contains(shelf.title) { return false }
            // A row whose cards carry neither an id nor artwork cannot be
            // opened or seen: it would lead the home as a dead block.
            let usable = shelf.items.contains { item in
                item.browseId != nil || item.playlistId != nil || item.videoId != nil
            }
            let hasArt = shelf.items.contains { $0.thumbnailURL != nil }
            guard usable, hasArt else { return false }
            seen.insert(shelf.title)
            return true
        }
    }

    /// Everything else, in the order the network gave it.
    private var otherShelves: [Shelf] {
        (model.highlightShelves + curatedShelves).filter { !isMixTitle($0.title) }
    }

    private func isMixTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        return lower.contains("mixtape") || lower.contains("mix") || lower.contains("para você")
            || lower.contains("madrugada") || lower.contains("feito para")
    }

    /// A shelf made of local data (the listening archive), drawn with the same
    /// cards as the network shelves.
    /// The phone's "Find Your Mood": the same tiles as Explore, on Home.
    @ViewBuilder
    private var moodRow: some View {
        if !model.moods.isEmpty {
            SectionHeader(title: "Find Your Mood", subtitle: nil, theme: theme) {
            }
            CarouselScroller(count: min(10, model.moods.count), theme: theme) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(model.moods.prefix(10).enumerated()), id: \.offset) { index, mood in
                        Button { model.openMood(mood) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack(alignment: .topTrailing) {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(LinearGradient(colors: [mood.color.opacity(0.9), mood.color.opacity(0.55)],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                                    if let cover = mood.thumbnailURL, let url = URL(string: cover) {
                                        CoverArt(url: url, size: 150, radius: 12, theme: theme)
                                            .allowsHitTesting(false)
                                            .overlay {
                                                LinearGradient(colors: [.black.opacity(0.45), .clear],
                                                               startPoint: .bottom, endPoint: .center)
                                            }
                                    }
                                    Image(systemName: "waveform")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.95))
                                        .shadow(color: .black.opacity(0.4), radius: 3)
                                        .padding(10)
                                }
                                .frame(width: 150, height: 150)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                Text(mood.title)
                                    .bitStyle(.titleMedium)
                                    .foregroundStyle(theme.colors.onSurface)
                                    .lineLimit(1)
                            }
                            .frame(width: 150, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .id("carousel-\(index)")
                    }
                }
                .padding(.horizontal, BitMetrics.gutter)
                .padding(.bottom, 26)
            }
        }
    }

    /// "Mais de <artista>" for the three artists the archive plays most — the
    /// recommendation is the history itself, not a catalogue guess.
    private func topArtistShelves(_ taste: LibraryStore.ArchiveTaste) -> [Shelf] {
        let top = taste.artists.prefix(3)
        return top.compactMap { artist in
            let tracks = taste.tracks
                .filter { $0.artist.localizedCaseInsensitiveContains(artist.name) }
                .prefix(12)
            guard tracks.count >= 3 else { return nil }
            return Shelf(title: "Mais de \(artist.name)", items: tracks.map { track in
                ShelfItem(
                    title: track.title,
                    subtitle: track.artist,
                    thumbnailURL: track.art,
                    videoId: track.id,
                    browseId: nil,
                    playlistId: nil,
                    duration: track.ms > 0 ? track.ms / 1000 : nil,
                    pageKind: nil
                )
            })
        }
    }

    @ViewBuilder
    private func archiveRow(_ title: String, items: [ShelfItem]) -> some View {
        if !items.isEmpty {
            SectionHeader(title: title, subtitle: nil, theme: theme)
            CarouselScroller(count: items.count, theme: theme) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        ShelfCard(item: item, theme: theme, isPlaying: isPlaying(item),
                                  fallbackArt: true) {
                            // Imported Spotify cards carry no video id: play the
                            // first YouTube Music match for the title/artist.
                            if item.videoId == nil, item.browseId == nil {
                                model.playBySearch(title: item.title, artist: item.subtitle)
                            } else {
                                model.activate(item)
                            }
                        }
                        .id("carousel-\(index)")
                    }
                }
                .padding(.horizontal, BitMetrics.gutter)
                .padding(.bottom, 26)
            }
        }
    }

    /// The titles the phone draws as rows of 48 pt artwork rather than cards.
    private var listShelfTitles: [String] {
        ["recente", "recent", "ouvir de novo", "escolha a dedo", "picked", "history", "histórico"]
    }

    @ViewBuilder
    private func shelfView(_ shelf: Shelf, hero: Bool) -> some View {
        let title = shelf.title.lowercased()
        if shelf.items.contains(where: \.isVideo) {
            videoRow(shelf)
        } else if listShelfTitles.contains(where: { title.contains($0) }),
                  !shelf.items.contains(where: { $0.thumbnailURL != nil }) {
            listShelf(shelf)
        } else if hero && shelf.items.count > 1 {
            heroRow(shelf)
        } else {
            SectionHeader(title: shelf.title, subtitle: nil, theme: theme)
            CarouselScroller(count: shelf.items.count, theme: theme) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(shelf.items.enumerated()), id: \.offset) { index, item in
                        ShelfCard(item: item, theme: theme, isPlaying: isPlaying(item),
                                  fallbackArt: true) {
                            // Imported Spotify cards carry no video id: play the
                            // first YouTube Music match for the title/artist.
                            if item.videoId == nil, item.browseId == nil {
                                model.playBySearch(title: item.title, artist: item.subtitle)
                            } else {
                                model.activate(item)
                            }
                        }
                        .id("carousel-\(index)")
                    }
                }
                .padding(.horizontal, BitMetrics.gutter)
                .padding(.bottom, 26)
            }
        }
    }

    /// Music videos: 16:9 artwork and the view count, as in the 1.9 feed.
    private func videoRow(_ shelf: Shelf) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: shelf.title, subtitle: nil, theme: theme)
            CarouselScroller(count: shelf.items.count, theme: theme) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(shelf.items.enumerated()), id: \.offset) { index, item in
                        VideoShelfCard(item: item, theme: theme) {
                            // Straight into the clip, as on the phone.
                            model.playVideo(item, theme: theme)
                        }
                        .id("carousel-\(index)")
                    }
                }
                .padding(.horizontal, BitMetrics.gutter)
                .padding(.bottom, 26)
            }
            .scrollIndicators(.never)
        }
    }

    /// "Recentes", "Ouvir de novo": rows, not cards — the phone's LIST layout.
    private func listShelf(_ shelf: Shelf) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: shelf.title, subtitle: nil, theme: theme)
            VStack(spacing: 0) {
                ForEach(shelf.items.prefix(6)) { item in
                    Button {
                        model.activate(item)
                    } label: {
                        HStack(spacing: 12) {
                            CoverArt(url: item.artwork(96), size: 48, radius: 7, theme: theme,
                                     isPlaying: isPlaying(item))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                    .bitStyle(.titleMedium)
                                    .foregroundStyle(theme.colors.onSurface)
                                    .lineLimit(1)
                                if !item.subtitle.isEmpty {
                                    Text(item.subtitle)
                                        .bitStyle(.bodyMedium)
                                        .foregroundStyle(theme.colors.onSurfaceVariant)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.colors.onSurfaceVariant.opacity(0.8))
                        }
                        .padding(.horizontal, BitMetrics.gutter)
                        .frame(height: 60)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 18)
        }
    }

    private func heroRow(_ shelf: Shelf) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: shelf.title, subtitle: nil, theme: theme)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(shelf.items) { item in
                        // min(0.70 × row, 320) on the phone; a desktop window is
                        // always past the cap, so the cap is the size.
                        HeroCard(item: item, theme: theme, width: 320) {
                            model.activate(item)
                        }
                    }
                }
                .padding(.horizontal, BitMetrics.gutter)
                .padding(.bottom, 26)
            }
            .scrollIndicators(.never)
            .frame(height: 320 / 0.92 + 26)
        }
    }

    private func isPlaying(_ item: ShelfItem) -> Bool {
        guard let song = item.song, let current = model.player.current else { return false }
        return song.id == current.id && model.player.isPlaying
    }

    private var homeSkeleton: some View {
        VStack(alignment: .leading, spacing: 26) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    ShimmerBlock(width: 160, height: 18, theme: theme)
                        .padding(.horizontal, BitMetrics.gutter)
                    HStack(spacing: 14) {
                        ForEach(0..<5, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 8) {
                                ShimmerBlock(width: 150, height: 150, radius: 12, theme: theme)
                                ShimmerBlock(width: 110, height: 14, theme: theme)
                                ShimmerBlock(width: 80, height: 12, theme: theme)
                            }
                        }
                    }
                    .padding(.horizontal, BitMetrics.gutter)
                }
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 40)
    }
}

// MARK: - Search

struct SearchView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryStore
    var theme: BitTheme

    @Environment(\.l10n) private var l10n

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 100)

                if model.query.trimmingCharacters(in: .whitespaces).count < 2 {
                    idle
                } else if model.isSearching && model.results.isEmpty {
                    searchSkeleton
                } else if let error = model.searchError, model.results.isEmpty {
                    MessageState(title: "Search failed", subtitle: error, theme: theme,
                                 actionTitle: "Try again", action: { model.searchNow() })
                } else if model.results.isEmpty {
                    MessageState(title: "No results", subtitle: "Nothing matched “\(model.query)”.",
                                 theme: theme)
                } else {
                    results
                }
            }
            .padding(.bottom, 176)
        }
        .scrollIndicators(.never)
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !library.recentSearches.isEmpty {
                HStack {
                    Text(l10n.t(.recentSearches))
                        .bitStyle(.headlineMedium)
                        .foregroundStyle(theme.colors.onSurface)
                    Spacer()
                    Button(l10n.t(.clear)) { library.clearSearches() }
                        .buttonStyle(.plain)
                        .bitStyle(.titleMedium)
                        .foregroundStyle(theme.colors.primary)
                }
                .padding(.horizontal, BitMetrics.gutter)
                .padding(.top, 12)

                ForEach(library.recentSearches, id: \.self) { term in
                    HStack(spacing: 14) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(theme.colors.onSurfaceVariant)
                            .frame(width: 26)
                        Text(term)
                            .bitStyle(.titleMedium)
                            .foregroundStyle(theme.colors.onSurface)
                        Spacer()
                        Button {
                            library.clearSearches()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.colors.onSurfaceVariant)
                                .frame(width: 28, height: 28)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .opacity(0.001)
                    }
                    .padding(.horizontal, BitMetrics.gutter)
                    .frame(height: 52)
                    .contentShape(Rectangle())
                    .onTapGesture { model.searchNow(term) }
                }
            }

            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(theme.colors.onSurfaceVariant.opacity(0.7))
                Text("Search millions of songs on YouTube Music.")
                    .bitStyle(.bodyLarge)
                    .foregroundStyle(theme.colors.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, library.recentSearches.isEmpty ? 120 : 60)
            .padding(.bottom, 40)
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SearchFilter.allCases) { filter in
                        FilterChip(title: label(for: filter), isSelected: model.filter == filter, theme: theme) {
                            withAnimation(.easeInOut(duration: 0.18)) { model.filter = filter }
                        }
                    }
                }
                .padding(.horizontal, BitMetrics.gutter)
            }
            .scrollIndicators(.never)
            .padding(.top, 8)
            .padding(.bottom, 10)

            ForEach(groupedSections, id: \.title) { section in
                Text(section.title)
                    .bitStyle(.labelMedium)
                    .foregroundStyle(theme.colors.onSurfaceVariant)
                    .padding(.horizontal, BitMetrics.gutter)
                    .padding(.top, 18)
                    .padding(.bottom, 6)

                ForEach(section.rows) { row in
                    resultRow(row)
                    Rectangle()
                        .fill(theme.colors.outline)
                        .frame(height: 0.5)
                        .padding(.leading, 84)
                }
            }
        }
    }

    private func label(for filter: SearchFilter) -> String {
        switch filter {
        case .all: return l10n.t(.all)
        case .songs: return l10n.t(.songs)
        case .albums: return l10n.t(.albums)
        case .artists: return l10n.t(.artists)
        case .playlists: return l10n.t(.playlists)
        }
    }

    private var groupedSections: [(title: String, rows: [SearchRow])] {
        let rows = model.filteredResults
        switch model.filter {
        case .songs:
            return [("Songs", rows)]
        case .albums:
            return [("Albums", rows)]
        case .artists:
            return [("Artists", rows)]
        case .playlists:
            return [("Playlists", rows)]
        case .all:
            var sections: [(String, [SearchRow])] = []
            let songs = rows.filter { $0.kind == .song || $0.kind == .video }
            let albums = rows.filter { $0.kind == .album }
            let artists = rows.filter { $0.kind == .artist }
            let playlists = rows.filter { $0.kind == .playlist }
            if !songs.isEmpty { sections.append(("Songs", songs)) }
            if !albums.isEmpty { sections.append(("Albums", albums)) }
            if !artists.isEmpty { sections.append(("Artists", artists)) }
            if !playlists.isEmpty { sections.append(("Playlists", playlists)) }
            return sections
        }
    }

    @ViewBuilder
    private func resultRow(_ row: SearchRow) -> some View {
        let isCurrent = row.videoId != nil && row.videoId == model.player.current?.videoId
        Button {
            model.activate(row)
        } label: {
            HStack(spacing: 14) {
                CoverArt(url: row.artwork(104), size: 52, radius: 8, theme: theme,
                         isPlaying: isCurrent && model.player.isPlaying)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .bitStyle(.titleMedium)
                        .foregroundStyle(isCurrent ? theme.colors.primary : theme.colors.onSurface)
                        .lineLimit(1)
                    Text(row.subtitle.isEmpty ? row.kind.rawValue.capitalized : row.subtitle)
                        .bitStyle(.bodyMedium)
                        .foregroundStyle(theme.colors.onSurfaceVariant)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                if let duration = row.duration {
                    Text(TimeFormat.playback(duration))
                        .bitStyle(.labelMedium)
                        .foregroundStyle(theme.colors.onSurfaceVariant)
                        .monospacedDigit()
                }
                Image(systemName: row.kind == .song || row.kind == .video ? "ellipsis" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.colors.onSurfaceVariant.opacity(0.7))
                    .frame(width: 24, height: 24)
            }
            .padding(.horizontal, BitMetrics.gutter)
            .padding(.vertical, 4)
            .frame(height: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .songActionsIfSong(row: row, model: model, library: library)
    }

    private var searchSkeleton: some View {
        VStack(spacing: 6) {
            ForEach(0..<8, id: \.self) { _ in
                HStack(spacing: 14) {
                    ShimmerBlock(width: 52, height: 52, radius: 8, theme: theme)
                    VStack(alignment: .leading, spacing: 6) {
                        ShimmerBlock(width: 220, height: 14, theme: theme)
                        ShimmerBlock(width: 140, height: 12, theme: theme)
                    }
                    Spacer()
                }
                .padding(.horizontal, BitMetrics.gutter)
                .frame(height: 60)
            }
        }
        .padding(.top, 16)
    }
}

// MARK: - Library

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryStore
    var theme: BitTheme

    @Environment(\.l10n) private var l10n

    @State private var showNewPlaylistDialog = false
    @State private var newPlaylistName = ""

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text(l10n.t(.libraryTitle))
                    .bitStyle(.displayLarge)
                    .foregroundStyle(theme.colors.onBackground)
                    .padding(.horizontal, BitMetrics.gutter)
                    .padding(.top, 104)
                    .padding(.bottom, 8)

                folderRows

                if !model.spotifyPlaylists.isEmpty {
                    SectionHeader(title: "Playlists do Spotify", subtitle: nil, theme: theme)
                    CarouselScroller(count: model.spotifyPlaylists.count, theme: theme) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(Array(model.spotifyPlaylists.enumerated()), id: \.offset) { index, playlist in
                                Button {
                                    model.openSpotifyPlaylist = playlist
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(LinearGradient(colors: [Color(hex: 0x1DB954).opacity(0.85),
                                                                          Color(hex: 0x14833B).opacity(0.7)],
                                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                                            .frame(width: 150, height: 150)
                                            .overlay {
                                                Image(systemName: "music.note.list")
                                                    .font(.system(size: 34, weight: .semibold))
                                                    .foregroundStyle(.white.opacity(0.9))
                                            }
                                        Text(playlist.name)
                                            .bitStyle(.titleMedium)
                                            .foregroundStyle(theme.colors.onSurface)
                                            .lineLimit(1)
                                        Text("\(playlist.tracks.count) músicas")
                                            .bitStyle(.bodyMedium)
                                            .foregroundStyle(theme.colors.onSurfaceVariant)
                                    }
                                    .frame(width: 150, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .id("carousel-\(index)")
                            }
                        }
                        .padding(.horizontal, BitMetrics.gutter)
                        .padding(.bottom, 14)
                    }
                }

                SectionHeader(title: "Playlists", subtitle: nil, theme: theme)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        newPlaylistCard
                        ForEach(library.playlists) { playlist in
                            ShelfCard(
                                item: ShelfItem(
                                    title: playlist.name,
                                    subtitle: playlist.songs.isEmpty ? "Empty" : "\(playlist.songs.count) songs",
                                    thumbnailURL: playlist.songs.first?.thumbnailURL,
                                    browseId: "local:" + playlist.id.uuidString,
                                    pageKind: .playlist
                                ),
                                theme: theme
                            ) {
                                model.push(.localPlaylist(playlist.id))
                            }
                        }
                    }
                    .padding(.horizontal, BitMetrics.gutter)
                    .padding(.bottom, 26)
                }
                .scrollIndicators(.never)

                if !library.favourites.isEmpty {
                    SectionHeader(title: "Favourite songs", subtitle: "\(library.favourites.count) tracks", theme: theme)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(library.favourites.prefix(20)) { song in
                                ShelfCard(
                                    item: ShelfItem(
                                        title: song.title,
                                        subtitle: song.artist,
                                        thumbnailURL: song.thumbnailURL,
                                        videoId: song.videoId,
                                        playlistId: song.playlistId,
                                        duration: song.duration,
                                        pageKind: .mix
                                    ),
                                    theme: theme
                                ) {
                                    model.playFavourites(startingAt: song)
                                }
                            }
                        }
                        .padding(.horizontal, BitMetrics.gutter)
                        .padding(.bottom, 26)
                    }
                    .scrollIndicators(.never)
                }

                if !library.recentlyPlayed.isEmpty {
                    Text("Recently played")
                        .bitStyle(.titleMedium)
                        .foregroundStyle(theme.colors.onSurface)
                        .padding(.horizontal, BitMetrics.gutter)
                        .padding(.vertical, 6)
                    ForEach(library.recentlyPlayed.prefix(8)) { song in
                        SongRow(song: song, theme: theme,
                                isCurrent: song.id == model.player.current?.id,
                                isPlaying: model.player.isPlaying) {
                            model.player.play(song, startRadio: true)
                            model.isRailVisible = true
                        }
                        .songActions(song: song, model: model, library: library)
                    }
                }

                if !library.localSongs.isEmpty {
                    SectionHeader(title: "Local files", subtitle: "\(library.localSongs.count) tracks", theme: theme)
                    ForEach(library.localSongs.prefix(30)) { song in
                        SongRow(song: song, theme: theme,
                                isCurrent: song.id == model.player.current?.id,
                                isPlaying: model.player.isPlaying) {
                            model.playLocal(song)
                        }
                        .songActions(song: song, model: model, library: library)
                    }
                }

                Color.clear.frame(height: 176)
            }
        }
        .scrollIndicators(.never)
        .alert("New playlist", isPresented: $showNewPlaylistDialog) {
            TextField("Name", text: $newPlaylistName)
            Button("Create") {
                let playlist = library.createPlaylist(named: newPlaylistName)
                newPlaylistName = ""
                model.push(.localPlaylist(playlist.id))
            }
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
        }
    }

    private var folderRows: some View {
        VStack(spacing: 0) {
            folderRow(icon: "heart.fill", title: "Favourite songs",
                      detail: "\(library.favourites.count)") {
                model.playFavourites()
            }
            divider
            folderRow(icon: "clock.arrow.circlepath", title: l10n.t(.recent),
                      detail: "\(library.recentlyPlayed.count)") { }
            divider
            folderRow(icon: "chart.bar.xaxis", title: "Replay",
                      detail: library.listeningMonths.isEmpty ? "" : "\(library.listeningMonths.count)") {
                model.push(.replay)
            }
            divider
            folderRow(icon: "folder.fill", title: "Local files",
                      detail: library.isScanning ? "Scanning…" : "\(library.localSongs.count)") {
                chooseFolder()
            }
            if !library.localFolders.isEmpty {
                ForEach(library.localFolders, id: \.self) { path in
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.colors.onSurfaceVariant)
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .bitStyle(.labelMedium)
                            .foregroundStyle(theme.colors.onSurfaceVariant)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            library.removeLocalFolder(path)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(theme.colors.onSurfaceVariant)
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, BitMetrics.gutter + 8)
                    .padding(.bottom, 6)
                }
            }
            divider
            folderRow(icon: "arrow.down.circle.fill", title: l10n.t(.downloads),
                      detail: DownloadStore.shared.downloadedSongs.isEmpty
                        ? l10n.t(.empty)
                        : "\(DownloadStore.shared.downloadedSongs.count)") {
                model.push(.downloads)
            }
        }
        .padding(.bottom, 8)
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.colors.outline)
            .frame(height: 0.5)
            .padding(.leading, 16 + 24 + 16)
    }

    private func folderRow(icon: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(theme.colors.primary)
                    .frame(width: 24)
                Text(title)
                    .bitStyle(.bodyLarge)
                    .foregroundStyle(theme.colors.onSurface)
                Spacer()
                Text(detail)
                    .bitStyle(.labelMedium)
                    .foregroundStyle(theme.colors.onSurfaceVariant)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.colors.onSurfaceVariant.opacity(0.6))
            }
            .padding(.horizontal, BitMetrics.gutter)
            .frame(minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var newPlaylistCard: some View {
        Button {
            showNewPlaylistDialog = true
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.colors.surfaceVariant)
                    .frame(width: 150, height: 150)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(theme.colors.primary)
                    }
                Text("New playlist")
                    .bitStyle(.titleMedium)
                    .foregroundStyle(theme.colors.onSurface)
                    .padding(.top, 10)
                Text("Create one")
                    .bitStyle(.bodyMedium)
                    .foregroundStyle(theme.colors.onSurfaceVariant)
            }
            .frame(width: 150, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch folder"
        panel.message = "Choose a folder of audio files to add to BitChord"
        if panel.runModal() == .OK, let url = panel.url {
            library.addLocalFolder(url)
        }
    }
}

// MARK: - Explore

struct ExploreView: View {
    @ObservedObject var model: AppModel
    var theme: BitTheme

    @Environment(\.l10n) private var l10n

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 12)]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text(l10n.t(.explore))
                    .bitStyle(.displayLarge)
                    .foregroundStyle(theme.colors.onBackground)
                    .padding(.horizontal, BitMetrics.gutter)
                    .padding(.top, 104)
                    .padding(.bottom, 14)

                if !model.exploreArtists.isEmpty {
                    SectionHeader(title: "Artistas", subtitle: nil, theme: theme)
                    CarouselScroller(count: model.exploreArtists.count, theme: theme,
                                     itemWidth: 130) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(Array(model.exploreArtists.enumerated()), id: \.offset) { index, artist in
                                Button {
                                    model.openArtist(named: artist.title)
                                } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        if let art = artist.thumbnailURL, let url = URL(string: art) {
                                            CoverArt(url: url, size: 130, radius: 65, theme: theme)
                                        } else {
                                            Circle().fill(theme.colors.surfaceVariant).frame(width: 130, height: 130)
                                        }
                                        Text(artist.title)
                                            .bitStyle(.titleMedium)
                                            .foregroundStyle(theme.colors.onSurface)
                                            .lineLimit(1)
                                            .frame(width: 130, alignment: .leading)
                                    }
                                }
                                .buttonStyle(.plain)
                                .id("carousel-\(index)")
                            }
                        }
                        .padding(.horizontal, BitMetrics.gutter)
                        .padding(.bottom, 18)
                    }
                }

                if model.moodsLoading && model.moods.isEmpty {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(0..<8, id: \.self) { _ in
                            ShimmerBlock(height: 92, radius: 12, theme: theme)
                        }
                    }
                    .padding(.horizontal, BitMetrics.gutter)
                } else if model.moods.isEmpty {
                    MessageState(title: "No categories right now",
                                 subtitle: "Explore needs a connection to YouTube Music.",
                                 theme: theme, actionTitle: "Reload", action: { model.loadMoods() })
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(model.moods) { mood in
                            Button {
                                model.openMood(mood)
                            } label: {
                                ZStack(alignment: .bottomLeading) {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [mood.color.opacity(0.85), mood.color.opacity(0.45)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing
                                            )
                                        )
                                    // The category's own artwork, with the gradient
                                    // kept underneath as the loading state.
                                    if let cover = mood.thumbnailURL, let url = URL(string: cover) {
                                        Color.clear
                                            .overlay {
                                                CoverArt(url: url, size: 260, radius: 0, theme: theme)
                                                    .allowsHitTesting(false)
                                            }
                                            .clipped()
                                            .allowsHitTesting(false)
                                        LinearGradient(
                                            colors: [.black.opacity(0.55), .black.opacity(0.15)],
                                            startPoint: .bottom, endPoint: .top
                                        )
                                        .allowsHitTesting(false)
                                    }
                                    Text(mood.title)
                                        .bitStyle(.titleMedium)
                                        .foregroundStyle(.white)
                                        .lineLimit(2)
                                        .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                                        .padding(14)
                                }
                                .frame(height: 92)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                // The cover layers must not swallow the tap.
                                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, BitMetrics.gutter)
                }

                Color.clear.frame(height: 176)
            }
        }
        .scrollIndicators(.never)
    }
}

/// A Spotify playlist imported from CSV: the tracks it came with, played by
/// searching YouTube Music for each one.
struct SpotifyPlaylistSheet: View {
    var playlist: SpotifyTasteImport.Playlist
    @ObservedObject var model: AppModel
    var theme: BitTheme

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .bitStyle(.titleLarge)
                        .foregroundStyle(theme.colors.onSurface)
                    Text("\(playlist.tracks.count) músicas do Spotify")
                        .bitStyle(.bodyMedium)
                        .foregroundStyle(theme.colors.onSurfaceVariant)
                }
                Spacer()
                Button("Fechar") { dismiss() }
                    .buttonStyle(.plain)
                    .bitStyle(.labelMedium)
                    .foregroundStyle(theme.colors.primary)
            }
            .padding(20)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(playlist.tracks.enumerated()), id: \.offset) { index, track in
                        Button {
                            model.playBySearch(title: track.title, artist: track.artist)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Text("\(index + 1)")
                                    .font(BitFont.font(.medium, 12))
                                    .foregroundStyle(theme.colors.onSurfaceVariant)
                                    .frame(width: 26, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(track.title)
                                        .bitStyle(.titleMedium)
                                        .foregroundStyle(theme.colors.onSurface)
                                        .lineLimit(1)
                                    Text(track.artist)
                                        .bitStyle(.bodyMedium)
                                        .foregroundStyle(theme.colors.onSurfaceVariant)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            .frame(height: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .frame(width: 560, height: 620)
        .background(theme.colors.background)
    }
}
