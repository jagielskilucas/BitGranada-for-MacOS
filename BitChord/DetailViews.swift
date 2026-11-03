//
//  DetailViews.swift
//  BitChord for macOS
//
//  Album / playlist / artist pages, local playlists, the moods grid and
//  Settings.
//
//  Android counterpart: ui/screens/DetailScreen.kt, LibraryScreen's Show-all
//  pages and SettingsSheet.kt.
//

import SwiftUI
import AppKit

// MARK: - Release (album / playlist / artist)

struct ReleaseView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryStore
    var theme: BitTheme

    var kind: Release.Kind
    var browseId: String
    var fallbackTitle: String
    var fallbackSubtitle: String
    var fallbackThumbnail: String?

    @State private var release: Release?
    @State private var failed = false
    @State private var signature: ArtistSignature?
    @State private var wordmark: ArtistWordmark?
    @State private var artistBanner: AppleArtistLogoService.Banner?
    @State private var heroPalette: ArtworkPalette?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // An artist page's photograph runs to the top of the window, so
                // it gets no spacer; albums and playlists keep clear of the bar.
                Color.clear.frame(height: (release?.kind ?? kind) == .artist ? 0 : 96)

                if let release {
                    header(release)
                    trackList(release)
                    carousels(release)
                } else if failed {
                    MessageState(
                        title: "Couldn't load this page",
                        subtitle: "YouTube Music didn't answer for “\(fallbackTitle)”.",
                        theme: theme,
                        actionTitle: "Try again",
                        action: { Task { await load(force: true) } }
                    )
                } else {
                    loadingHeader
                }

                Color.clear.frame(height: 176)
            }
        }
        .background {
            if let heroPalette, (release?.kind ?? kind) == .artist {
                // A long, even falloff rather than a quick fade to black: the
                // whole page stays in the artist's colour, dimming slowly.
                LinearGradient(
                    stops: [
                        .init(color: heroPalette.accent.opacity(0.62), location: 0),
                        .init(color: heroPalette.accent.opacity(0.52), location: 0.25),
                        .init(color: heroPalette.accent.opacity(0.40), location: 0.50),
                        .init(color: heroPalette.accent.opacity(0.26), location: 0.75),
                        .init(color: heroPalette.accent.opacity(0.12), location: 0.92),
                        .init(color: theme.colors.background.opacity(0.9), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
            }
        }
        .scrollIndicators(.never)
        .task(id: browseId) { await load() }
        .task(id: release?.title) {
            guard let release, release.kind == .artist else { return }
            // Apple's artist wordmark first — it is the handwritten name Apple
            // draws over the hero. The signature API is the fallback for the
            // artists Apple only typesets.
            if let art = release.bannerURL ?? release.thumbnailURL,
               let url: URL = ArtworkURL.resized(art, 600) {
                if let (data, _) = try? await URLSession.shared.data(from: url),
                   let image = NSImage(data: data) {
                    heroPalette = PaletteExtractor.extract(from: image, key: art)
                }
            }
            var banner = await AppleArtistLogoService.shared.banner(
                for: release.title, titles: release.songs.map(\.title)
            )
            if banner == nil {
                // One more try a moment later: the first attempt can lose a race
                // with Apple's CDN or with the page's own load.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                banner = await AppleArtistLogoService.shared.banner(
                    for: release.title, titles: release.songs.map(\.title)
                )
            }
            artistBanner = banner
            wordmark = banner?.logo
            guard model.settings.signatureApiEnabled else { return }
            signature = await ArtistSignatureService.shared.signature(
                for: release.title, baseURL: model.settings.signatureApiURL
            )
        }
    }

    private func load(force: Bool = false) async {
        if !force, release != nil { return }
        failed = false
        if let loaded = await model.release(browseId: browseId, kind: kind) {
            release = loaded
        } else {
            failed = true
        }
    }

    @ViewBuilder
    private func header(_ release: Release) -> some View {
        if release.kind == .artist {
            artistHeader(release)
        } else {
            releaseHeader(release)
        }
    }

    /// The 1.9 artist page: a full-bleed portrait with the name over it in the
    /// handwritten face Apple Music signs artists with, then shuffle, play and
    /// favourite, then the top songs.
    /// Shuffle, play and favourite. They straddle the bottom edge of the
    /// photograph, the way the phone lays them over it.
    private func artistControls(_ release: Release) -> some View {
        HStack(spacing: 22) {
            Button {
                let shuffled = release.songs.shuffled()
                model.player.playAll(shuffled)
                model.isRailVisible = true
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.colors.onSurface)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(theme.colors.onSurface.opacity(0.10)))
            }
            .buttonStyle(.plain)

            Button {
                model.playRelease(release)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(theme.colors.onPrimary)
                    .frame(width: 62, height: 62)
                    .background(Circle().fill(theme.colors.primary))
            }
            .buttonStyle(.plain)

            Button {
                if let first = release.songs.first { library.toggleFavourite(first) }
            } label: {
                Image(systemName: "star")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.colors.onSurface)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(theme.colors.onSurface.opacity(0.10)))
            }
            .buttonStyle(.plain)
        }
        // Centred under the name, like the phone's artist page.
        .padding(.horizontal, BitMetrics.gutter)
    }

    private func artistHeader(_ release: Release) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    // Some artists carry a looping clip instead of a still: the
                    // page plays it behind the name, as the phone does.
                    if let motion = artistBanner?.videoURL {
                        CanvasVideoView(url: motion)
                    } else {
                        FillArtwork(url: ArtworkURL.resized(release.bannerURL ?? release.thumbnailURL, 1600),
                                    theme: theme)
                    }
                }
                    // Taller than it used to be: the portrait now reaches the
                    // first list, so the artist page opens like the phone's.
                    .frame(height: 660)
                    // The photograph dissolves into the page instead of ending
                    // on a hard edge: the last third fades to transparent, so
                    // whatever gradient the page carries shows through.
                    .mask {
                        // A long, eased fade: the photograph has to disappear
                        // into the page gradient, not stop at its edge.
                        LinearGradient(
                            stops: [
                                .init(color: .white, location: 0),
                                .init(color: .white, location: 0.55),
                                .init(color: .white.opacity(0.94), location: 0.70),
                                .init(color: .white.opacity(0.76), location: 0.80),
                                .init(color: .white.opacity(0.46), location: 0.89),
                                .init(color: .white.opacity(0.16), location: 0.96),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    }
                // Only enough shading for the name to read; the fade itself is
                // the photograph's mask, not a painted band.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.10), location: 0.45),
                        .init(color: .black.opacity(0.22), location: 0.80),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                Group {
                    if let wordmark {
                        AsyncImage(url: wordmark.url) { phase in
                            if let image = phase.image {
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: 530, maxHeight: 105)
                            } else {
                                Color.clear.frame(height: 150)
                            }
                        }
                        .shadow(color: .black.opacity(0.45), radius: 14, y: 5)
                    } else if let signature {
                        SignatureView(signature: signature, height: 105)
                            .frame(maxWidth: .infinity)
                            .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
                    } else {
                        // Nothing handwritten for this artist: set the name in
                        // the app's own display face rather than pretending a
                        // script font is a signature.
                        Text(release.title)
                            .font(BitFont.font(.bold, 40))
                            .tracking(-0.8)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 620)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, BitMetrics.gutter)
                // Sits low in the photograph, on the same visual band as the
                // controls that overlap its bottom edge.
                .padding(.bottom, 58)
            }
            .overlay(alignment: .bottom) {
                artistControls(release)
                    .offset(y: 31)
            }
            .padding(.bottom, 31)



            if !release.songs.isEmpty {
                Text("Músicas mais tocadas")
                    .bitStyle(.titleLarge)
                    .foregroundStyle(theme.colors.onSurface)
                    .padding(.horizontal, BitMetrics.gutter)
                    .padding(.bottom, 6)
            }
        }
    }

    /// Apple Music signs an artist with a script; macOS ships a few, and the
    /// first available is used so no font has to be bundled.
    static func signatureFont(size: CGFloat) -> Font {
        for name in ["Snell Roundhand", "Savoye LET", "Bradley Hand", "Noteworthy"] {
            if NSFont(name: name, size: size) != nil {
                return .custom(name, size: size)
            }
        }
        return .system(size: size, weight: .semibold, design: .serif).italic()
    }

    private func releaseHeader(_ release: Release) -> some View {
        HStack(alignment: .bottom, spacing: 24) {
            CoverArt(url: release.artwork(480), size: 220, radius: 12, theme: theme)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)

            VStack(alignment: .leading, spacing: 6) {
                Text(release.kind.displayName.uppercased())
                    .bitStyle(.labelMedium)
                    .foregroundStyle(theme.colors.onSurfaceVariant)
                    .tracking(1.0)
                Text(release.title)
                    .font(BitFont.font(.bold, 34))
                    .tracking(-0.5)
                    .foregroundStyle(theme.colors.onSurface)
                    .lineLimit(3)
                if !release.subtitle.isEmpty {
                    Text(release.subtitle)
                        .bitStyle(.bodyLarge)
                        .foregroundStyle(theme.colors.onSurfaceVariant)
                        .lineLimit(2)
                }
                if let year = release.year {
                    Text(year)
                        .bitStyle(.labelMedium)
                        .foregroundStyle(theme.colors.onSurfaceVariant)
                }

                HStack(spacing: 12) {
                    Button {
                        model.playRelease(release)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "play.fill").font(.system(size: 12, weight: .bold))
                            Text("Play").bitStyle(.labelMedium)
                        }
                        .foregroundStyle(theme.colors.onPrimary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(theme.colors.primary))
                    }
                    .buttonStyle(.plain)
                    .disabled(release.songs.isEmpty)

                    Button {
                        let shuffled = release.songs.shuffled()
                        model.player.playAll(shuffled)
                        model.isRailVisible = true
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "shuffle").font(.system(size: 12, weight: .bold))
                            Text("Shuffle").bitStyle(.labelMedium)
                        }
                        .foregroundStyle(theme.colors.onSurface)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Capsule().strokeBorder(theme.colors.outline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(release.songs.isEmpty)

                    if !release.songs.isEmpty {
                        Button {
                            library.createPlaylist(named: release.title, songs: release.songs)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.colors.onSurface)
                                .frame(width: 38, height: 38)
                                .background(Circle().strokeBorder(theme.colors.outline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("Save as a playlist")
                    }
                }
                .padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, BitMetrics.gutter)
        .padding(.bottom, 22)
    }

    /// The "Releases for you" style row an album page ends with.
    @ViewBuilder
    private func carousels(_ release: Release) -> some View {
        ForEach(release.shelves) { shelf in
            SectionHeader(title: shelf.title, subtitle: nil, theme: theme)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(shelf.items) { item in
                        ShelfCard(item: item, theme: theme, isPlaying: false) {
                            model.activate(item)
                        }
                    }
                }
                .padding(.horizontal, BitMetrics.gutter)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.never)
        }
    }

    @ViewBuilder
    private func trackList(_ release: Release) -> some View {
        if release.songs.isEmpty {
            MessageState(title: "Nothing to play", subtitle: "This page has no playable tracks.",
                         theme: theme)
        } else {
            ForEach(Array((release.kind == .artist ? Array(release.songs.prefix(10)) : release.songs).enumerated()), id: \.element.id) { index, song in
                let isCurrent = song.id == model.player.current?.id
                SongRow(
                    song: song,
                    theme: theme,
                    isCurrent: isCurrent,
                    isPlaying: model.player.isPlaying,
                    showArtwork: true,
                    fallbackArtwork: release.artwork(104),
                    index: index + 1
                ) {
                    model.playRelease(release, from: song)
                } onMenu: {
                    let playlist = library.playlists.first { $0.name == "Saved from \(release.title)" }
                        ?? library.createPlaylist(named: "Saved from \(release.title)")
                    library.add(song, to: playlist)
                }
                .songActions(song: song, model: model, library: library)
            }
        }
    }

    private var loadingHeader: some View {
        HStack(alignment: .bottom, spacing: 24) {
            ShimmerBlock(width: 220, height: 220, radius: 12, theme: theme)
            VStack(alignment: .leading, spacing: 10) {
                ShimmerBlock(width: 80, height: 12, theme: theme)
                ShimmerBlock(width: 320, height: 30, theme: theme)
                ShimmerBlock(width: 200, height: 16, theme: theme)
                ShimmerBlock(width: 140, height: 38, radius: 19, theme: theme)
            }
            Spacer()
        }
        .padding(.horizontal, BitMetrics.gutter)
        .padding(.bottom, 22)
    }
}

extension Release.Kind {
    var displayName: String {
        switch self {
        case .album: return "Album"
        case .playlist: return "Playlist"
        case .artist: return "Artist"
        case .mix: return "Mix"
        }
    }
}

// MARK: - Local playlist

struct LocalPlaylistView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryStore
    var theme: BitTheme
    var playlistID: UUID

    private var playlist: LibraryPlaylist? {
        library.playlists.first { $0.id == playlistID }
    }

    var body: some View {
        releaseScroll
    }

    private var releaseScroll: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 96)
                if let playlist {
                    header(playlist)
                    if playlist.songs.isEmpty {
                        MessageState(title: "This playlist is empty",
                                     subtitle: "Add songs from any track's menu, or from Search.",
                                     theme: theme)
                    } else {
                        ForEach(playlist.songs) { song in
                            SongRow(song: song, theme: theme,
                                    isCurrent: song.id == model.player.current?.id,
                                    isPlaying: model.player.isPlaying) {
                                model.player.playAll(playlist.songs, startingAt: song)
                                model.isRailVisible = true
                            } onMenu: {
                                library.remove(song, from: playlist)
                            }
                        }
                    }
                } else {
                    MessageState(title: "Playlist not found", theme: theme)
                }
                Color.clear.frame(height: 176)
            }
        }
        .scrollIndicators(.never)
    }

    private func header(_ playlist: LibraryPlaylist) -> some View {
        HStack(alignment: .bottom, spacing: 24) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.colors.surfaceVariant)
                if let first = playlist.songs.first {
                    CoverArt(url: first.artwork(400), size: 220, radius: 12, theme: theme)
                } else {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 54, weight: .light))
                        .foregroundStyle(theme.colors.onSurfaceVariant)
                }
            }
            .frame(width: 220, height: 220)

            VStack(alignment: .leading, spacing: 6) {
                Text("PLAYLIST")
                    .bitStyle(.labelMedium)
                    .tracking(1.0)
                    .foregroundStyle(theme.colors.onSurfaceVariant)
                Text(playlist.name)
                    .font(BitFont.font(.bold, 34))
                    .tracking(-0.5)
                    .foregroundStyle(theme.colors.onSurface)
                    .lineLimit(3)
                Text("\(playlist.songs.count) songs")
                    .bitStyle(.bodyLarge)
                    .foregroundStyle(theme.colors.onSurfaceVariant)

                HStack(spacing: 12) {
                    Button {
                        model.player.playAll(playlist.songs)
                        model.isRailVisible = true
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "play.fill").font(.system(size: 12, weight: .bold))
                            Text("Play").bitStyle(.labelMedium)
                        }
                        .foregroundStyle(theme.colors.onPrimary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(theme.colors.primary))
                    }
                    .buttonStyle(.plain)
                    .disabled(playlist.songs.isEmpty)

                    Menu {
                        Button("Delete playlist", role: .destructive) {
                            library.deletePlaylist(playlist)
                            model.pop()
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.colors.onSurface)
                            .frame(width: 38, height: 38)
                            .background(Circle().strokeBorder(theme.colors.outline, lineWidth: 1))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 38, height: 38)
                }
                .padding(.top, 10)
            }
            Spacer()
        }
        .padding(.horizontal, BitMetrics.gutter)
        .padding(.bottom, 22)
    }
}

// MARK: - Moods

struct MoodsGridView: View {
    @ObservedObject var model: AppModel
    var theme: BitTheme

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 12)]

    var body: some View {
        releaseScroll
    }

    private var releaseScroll: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 92)
                Text("Moods & activities")
                    .font(BitFont.font(.bold, 30))
                    .tracking(-0.4)
                    .foregroundStyle(theme.colors.onSurface)
                    .padding(.horizontal, BitMetrics.gutter)
                    .padding(.bottom, 14)

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.moods) { mood in
                        Button { model.openMood(mood) } label: {
                            ZStack(alignment: .bottomLeading) {
                                LinearGradient(
                                    colors: [mood.color.opacity(0.85), mood.color.opacity(0.45)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                                Text(mood.title)
                                    .bitStyle(.titleMedium)
                                    .foregroundStyle(.white)
                                    .padding(14)
                            }
                            .frame(height: 92)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, BitMetrics.gutter)
                Color.clear.frame(height: 176)
            }
        }
        .scrollIndicators(.never)
    }
}

struct MoodView: View {
    @ObservedObject var model: AppModel
    var theme: BitTheme
    var browseId: String
    var params: String
    var title: String

    var body: some View {
        releaseScroll
    }

    private var releaseScroll: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 92)
                Text(title)
                    .font(BitFont.font(.bold, 30))
                    .tracking(-0.4)
                    .foregroundStyle(theme.colors.onSurface)
                    .padding(.horizontal, BitMetrics.gutter)
                    .padding(.bottom, 8)

                if model.moodLoading {
                    ForEach(0..<2, id: \.self) { _ in
                        HStack(spacing: 14) {
                            ForEach(0..<6, id: \.self) { _ in
                                ShimmerBlock(width: 150, height: 150, radius: 12, theme: theme)
                            }
                        }
                        .padding(.horizontal, BitMetrics.gutter)
                        .padding(.vertical, 12)
                    }
                } else {
                    ForEach(model.moodShelves) { shelf in
                        SectionHeader(title: shelf.title, subtitle: nil, theme: theme)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(shelf.items) { item in
                                    ShelfCard(item: item, theme: theme) { model.activate(item) }
                                }
                            }
                            .padding(.horizontal, BitMetrics.gutter)
                            .padding(.bottom, 26)
                        }
                        .scrollIndicators(.never)
                    }
                }
                Color.clear.frame(height: 176)
            }
        }
        .scrollIndicators(.never)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var library: LibraryStore
    var theme: BitTheme

    @Environment(\.l10n) private var l10n
    @State private var importedReport: BackupReport?
    @State private var importError: String?
    @ObservedObject private var addonRegistry = AddonRegistry.shared
    @State private var addonDraft = ""
    @State private var spotifyCookie = ""
    @State private var spotifyStatus: String?
    @State private var spotifyBusy = false
    @State private var signatureStatus: String?
    @State private var cacheCleared = false
    @State private var spotifyClientID = SpotifyOAuth.shared.clientID
    @State private var lastFMUser = UserDefaults.standard.string(forKey: "lastfm.user") ?? "jagielskiluc"
    @State private var lastFMKey = UserDefaults.standard.string(forKey: "lastfm.apiKey") ?? ""
    @State private var lastFMStatus: String?
    @State private var googleCookie = UserDefaults.standard.string(forKey: "google.cookie") ?? ""
    @State private var spotifyManualToken = UserDefaults.standard.string(forKey: "spotify.manualToken") ?? ""

    var body: some View {
        releaseScroll
    }

    private var releaseScroll: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 92)
                Text(l10n.t(.settings))
                    .font(BitFont.font(.bold, 34))
                    .tracking(-0.5)
                    .foregroundStyle(theme.colors.onSurface)
                    .padding(.horizontal, BitMetrics.gutter)
                    .padding(.bottom, 10)

                section(l10n.t(.appearance)) {
                    row(l10n.t(.theme)) {
                        SegmentedPill(
                            options: AppAppearance.allCases,
                            selection: settings.appearance,
                            label: { language in
                                switch language {
                                case .system: return l10n.t(.systemLabel)
                                case .dark: return l10n.t(.dark)
                                case .light: return l10n.t(.light)
                                }
                            },
                            theme: theme
                        ) { settings.appearance = $0 }
                    }
                    row(l10n.t(.language)) {
                        Picker("", selection: $settings.language) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(language.label).tag(language)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 190)
                    }
                    toggle(l10n.t(.artworkBackdrop), detail: l10n.t(.artworkBackdropDetail),
                           isOn: $settings.artworkBackdrop)
                    toggle(l10n.t(.nowPlaying) + " — coluna à direita",
                           detail: "Mostra a letra ao lado da biblioteca",
                           isOn: $settings.showNowPlayingRail)
                }
                section(l10n.t(.playback)) {
                    row(l10n.t(.audioQuality)) {
                        SegmentedPill(
                            options: AudioQuality.allCases,
                            selection: settings.audioQuality,
                            label: { $0 == .high ? l10n.t(.high) : l10n.t(.standard) },
                            theme: theme
                        ) { settings.audioQuality = $0 }
                    }
                    row(l10n.t(.volume)) {
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.colors.onSurfaceVariant)
                            Slider(value: $model.player.volume, in: 0...1)
                                .frame(width: 150)
                                .tint(theme.colors.primary)
                            Image(systemName: "speaker.wave.3.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.colors.onSurfaceVariant)
                        }
                    }
                    toggle(l10n.t(.gapless), detail: l10n.t(.gaplessDetail),
                           isOn: $settings.gaplessEnabled)
                    row(l10n.t(.crossfade)) {
                        HStack(spacing: 10) {
                            Slider(value: $settings.crossfadeSeconds, in: 0...12, step: 1)
                                .frame(width: 140)
                                .tint(theme.colors.primary)
                            Text(settings.crossfadeSeconds == 0 ? l10n.t(.crossfadeOff)
                                 : "\(Int(settings.crossfadeSeconds))s")
                                .bitStyle(.labelMedium)
                                .foregroundStyle(theme.colors.onSurfaceVariant)
                                .frame(width: 64, alignment: .leading)
                        }
                    }
                    Text(l10n.t(.crossfadeNote))
                        .bitStyle(.labelSmall)
                        .foregroundStyle(theme.colors.onSurfaceVariant.opacity(0.8))
                        .padding(.horizontal, BitMetrics.gutter)
                        .padding(.bottom, 8)
                    toggle(l10n.t(.miniPlayerProgress), detail: nil, isOn: $settings.showMiniPlayerProgress)
                    toggle(l10n.t(.openLyricsOnStart), detail: nil, isOn: $settings.showLyricsOnOpen)
                }
                section(l10n.t(.lyricsProviders)) {
                    Text(l10n.t(.lyricsProvidersDetail))
                        .bitStyle(.labelSmall)
                        .foregroundStyle(theme.colors.onSurfaceVariant)
                        .padding(.horizontal, BitMetrics.gutter)
                        .padding(.bottom, 6)

                    ForEach(Array(settings.lyricsProviders.enumerated()), id: \.offset) { index, id in
                        providerRow(id: id, index: index)
                    }
                }
                section("Last.fm") {
                    row("API key") {
                        TextField("Chave de API do Last.fm",
                                  text: Binding(get: { lastFMKey },
                                                set: {
                                                    lastFMKey = $0
                                                    UserDefaults.standard.set($0, forKey: "lastfm.apiKey")
                                                }))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 340)
                        Spacer()
                        Button("Testar") {
                            Task {
                                lastFMStatus = "Consultando…"
                                do {
                                    let items = try await LastFM.shared
                                        .similarArtists(to: "ROSALÍA", limit: 3)
                                    lastFMStatus = "OK — " + items.map(\.name).joined(separator: ", ")
                                    model.loadLastFMRecommendations()
                                } catch {
                                    lastFMStatus = error.localizedDescription
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .bitStyle(.labelMedium)
                        .foregroundStyle(theme.colors.primary)
                    }
                    Text("Cria a prateleira “Parecido com …” na Home, com artistas e faixas semelhantes ao que está tocando. A chave é gratuita em last.fm/api/account/create.")
                        .bitStyle(.labelSmall)
                        .foregroundStyle(theme.colors.onSurfaceVariant)
                        .padding(.horizontal, BitMetrics.gutter)
                        .padding(.bottom, 8)
                    if let lastFMStatus {
                        Text(lastFMStatus)
                            .bitStyle(.labelSmall)
                            .foregroundStyle(theme.colors.onSurfaceVariant)
                            .textSelection(.enabled)
                            .padding(.horizontal, BitMetrics.gutter)
                            .padding(.bottom, 8)
                    }
                }

                section("Fontes de música (addons)") {
                    toggle("Preferir qualidade máxima", detail: "Usa FLAC do addon quando ele tiver a faixa",
                           isOn: $settings.preferAddonQuality)

                    ForEach(addonRegistry.sources) { source in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(source.isReachable ? Color.green.opacity(0.8) : BitColors.accentRed.opacity(0.7))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(source.name)
                                    .bitStyle(.bodyLarge)
                                    .foregroundStyle(theme.colors.onSurface)
                                Text(source.status)
                                    .bitStyle(.labelSmall)
                                    .foregroundStyle(theme.colors.onSurfaceVariant)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button(l10n.t(.remove)) {
                                settings.addonSources.removeAll { $0 == source.baseURL.absoluteString }
                            }
                            .buttonStyle(.plain)
                            .bitStyle(.labelMedium)
                            .foregroundStyle(BitColors.accentRed)
                        }
                        .padding(.horizontal, BitMetrics.gutter)
                        .frame(minHeight: 46)
                    }

                    HStack(spacing: 8) {
                        TextField("https://servidor/a", text: $addonDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 300)
                        Button(l10n.t(.create).isEmpty ? "Adicionar" : "Adicionar") {
                            var url = addonDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            if url.hasSuffix("/manifest.json") { url = String(url.dropLast("/manifest.json".count)) }
                            while url.hasSuffix("/") { url.removeLast() }
                            guard !url.isEmpty, !settings.addonSources.contains(url) else { return }
                            settings.addonSources.append(url)
                            addonDraft = ""
                        }
                        .buttonStyle(.plain)
                        .bitStyle(.labelMedium)
                        .foregroundStyle(theme.colors.primary)
                        .disabled(addonDraft.isEmpty)
                    }
                    .padding(.horizontal, BitMetrics.gutter)
                    .padding(.bottom, 10)
                }
                section("Seu gosto no Spotify") {
                    HStack(spacing: 8) {
                        TextField("Client ID do seu app Spotify",
                                  text: Binding(get: { spotifyClientID },
                                                set: { spotifyClientID = $0; SpotifyOAuth.shared.clientID = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 320)
                        Button(SpotifyOAuth.shared.isConnected ? "Reconectar" : "Conectar") {
                            Task {
                                spotifyStatus = "Abrindo o navegador…"
                                let ok = await SpotifyOAuth.shared.authorize()
                                spotifyStatus = ok ? "Conectado." : (SpotifyOAuth.shared.status ?? "Falhou.")
                            }
                        }
                        .buttonStyle(.plain)
                        .bitStyle(.labelMedium)
                        .foregroundStyle(theme.colors.primary)
                        Spacer()
                    }
                    .padding(.horizontal, BitMetrics.gutter)
                    .padding(.bottom, 6)
                    HStack(spacing: 8) {
                        TextField("Access token temporário (opcional)",
                                  text: Binding(get: { spotifyManualToken },
                                                set: {
                                                    spotifyManualToken = $0
                                                    UserDefaults.standard.set($0, forKey: "spotify.manualToken")
                                                }))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 420)
                        Button("Testar") {
                            Task { spotifyStatus = await SpotifyTasteService.shared.diagnose() }
                        }
                        .buttonStyle(.plain)
                        .bitStyle(.labelMedium)
                        .foregroundStyle(theme.colors.primary)
                        Spacer()
                    }
                    .padding(.horizontal, BitMetrics.gutter)
                    .padding(.bottom, 6)
                    if let spotifyStatus {
                        Text(spotifyStatus)
                            .bitStyle(.labelSmall)
                            .foregroundStyle(theme.colors.onSurfaceVariant)
                            .textSelection(.enabled)
                            .padding(.horizontal, BitMetrics.gutter)
                            .padding(.bottom, 4)
                    }
                    Text("Redirect URI para cadastrar no app do Spotify: \(SpotifyOAuth.redirectURI)")
                        .bitStyle(.labelSmall)
                        .foregroundStyle(theme.colors.onSurfaceVariant)
                        .textSelection(.enabled)
                        .padding(.horizontal, BitMetrics.gutter)
                        .padding(.bottom, 4)
                    if let spotifyStatus {
                        Text(spotifyStatus)
                            .bitStyle(.labelSmall)
                            .foregroundStyle(theme.colors.onSurfaceVariant)
                            .padding(.horizontal, BitMetrics.gutter)
                            .padding(.bottom, 4)
                    }
                    HStack(spacing: 10) {
                        if let taste = model.spotifyTaste {
                            Text("\(taste.artists.count) artistas · \(taste.tracks.count) faixas")
                                .bitStyle(.bodyMedium)
                                .foregroundStyle(theme.colors.onSurfaceVariant)
                        } else {
                            Text("Lê seus artistas mais ouvidos do Spotify — sem criar app, usando seu login")
                                .bitStyle(.bodyMedium)
                                .foregroundStyle(theme.colors.onSurfaceVariant)
                        }
                        Spacer()
                        Button("Playlists…") {
                            let panel = NSOpenPanel()
                            panel.allowsMultipleSelection = true
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = true
                            panel.allowedContentTypes = [.commaSeparatedText, .json, .plainText, .folder]
                            guard panel.runModal() == .OK else { return }
                            var urls: [URL] = []
                            for url in panel.urls {
                                // A folder of Exportify CSVs is the common case.
                                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                                    let files = (try? FileManager.default.contentsOfDirectory(
                                        at: url, includingPropertiesForKeys: nil)) ?? []
                                    urls.append(contentsOf: files.filter {
                                        ["csv", "json", "txt"].contains($0.pathExtension.lowercased())
                                    })
                                } else {
                                    urls.append(url)
                                }
                            }
                            model.importSpotifyPlaylistFiles(urls)
                        }
                        .buttonStyle(.plain)
                        .bitStyle(.labelMedium)
                        .foregroundStyle(theme.colors.onSurfaceVariant)
                        Button(model.spotifyTasteBusy ? "Lendo…" : "Importar") {
                            model.refreshSpotifyTaste()
                        }
                        .buttonStyle(.plain)
                        .bitStyle(.labelMedium)
                        .foregroundStyle(theme.colors.primary)
                        .disabled(model.spotifyTasteBusy)
                    }
                    .padding(.horizontal, BitMetrics.gutter)
                    .padding(.bottom, 6)
                    if let error = model.spotifyTasteError {
                        Text(error)
                            .bitStyle(.labelSmall)
                            .foregroundStyle(BitColors.accentRed)
                            .padding(.horizontal, BitMetrics.gutter)
                            .padding(.bottom, 8)
                    }
                }
                section("Canvas do Spotify") {
                    toggle("Mostrar canvas", detail: "Loop de vídeo da capa quando existe",
                           isOn: $settings.canvasEnabled)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(SpotifySecrets.hasCookie ? "Conectado" : "Não conectado")
                                .bitStyle(.bodyLarge)
                                .foregroundStyle(theme.colors.onSurface)
                            Text(spotifyStatus ?? "Cole o cookie sp_dc da sua conta para liberar os canvases da sua biblioteca.")
                                .bitStyle(.labelSmall)
                                .foregroundStyle(theme.colors.onSurfaceVariant)
                                .lineLimit(2)
                        }
                        Spacer()
                        if SpotifySecrets.hasCookie {
                            Button("Desconectar") {
                                SpotifySecrets.deleteCookie()
                                Task { await SpotifyCanvasService.shared.invalidate() }
                                spotifyStatus = nil
                            }
                            .buttonStyle(.plain)
                            .bitStyle(.labelMedium)
                            .foregroundStyle(BitColors.accentRed)
                        }
                    }
                    .padding(.horizontal, BitMetrics.gutter)
                    .frame(minHeight: 52)

                    if !SpotifySecrets.hasCookie {
                        HStack(spacing: 8) {
                            SecureField("sp_dc", text: $spotifyCookie)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 320)
                            Button(spotifyBusy ? "Conectando…" : "Conectar") {
                                guard !spotifyCookie.isEmpty else { return }
                                spotifyBusy = true
                                spotifyStatus = nil
                                SpotifySecrets.saveCookie(spotifyCookie)
                                let song = model.player.current
                                    ?? Song(videoId: "x", title: "Get Lucky", artist: "Daft Punk",
                                            album: "Random Access Memories", duration: 369, thumbnailURL: nil)
                                Task {
                                    let clip = await SpotifyCanvasService.shared.clip(for: song)
                                    await MainActor.run {
                                        spotifyBusy = false
                                        spotifyCookie = ""
                                        spotifyStatus = clip != nil
                                            ? "Conectado — canvas encontrado para “\(song.title)”."
                                            : "Token válido, mas o Spotify limitou a busca agora. O catálogo comunitário segue como reserva."
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .bitStyle(.labelMedium)
                            .foregroundStyle(theme.colors.primary)
                            .disabled(spotifyBusy)
                        }
                        .padding(.horizontal, BitMetrics.gutter)
                        .padding(.bottom, 10)
                    }
                }
                section("Assinaturas de artistas") {
                    toggle("Usar API de assinaturas",
                           detail: "Desenha a assinatura manuscrita na página do artista",
                           isOn: Binding(
                            get: { settings.signatureApiEnabled },
                            set: { settings.signatureApiEnabled = $0 }
                           ))
                    HStack(spacing: 8) {
                        TextField("https://sua-api-de-assinaturas", text: Binding(
                            get: { settings.signatureApiURL },
                            set: { settings.signatureApiURL = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 320)
                        Button("Testar") {
                            Task {
                                let ok = await ArtistSignatureService.shared.check(baseURL: settings.signatureApiURL)
                                signatureStatus = ok ? "API respondeu OK" : "API não respondeu"
                            }
                        }
                        .buttonStyle(.plain)
                        .bitStyle(.labelMedium)
                        .foregroundStyle(theme.colors.primary)
                    }
                    .padding(.horizontal, BitMetrics.gutter)
                    .padding(.bottom, 4)
                    if let signatureStatus {
                        Text(signatureStatus)
                            .bitStyle(.labelSmall)
                            .foregroundStyle(theme.colors.onSurfaceVariant)
                            .padding(.horizontal, BitMetrics.gutter)
                            .padding(.bottom, 8)
                    }
                }
                section(l10n.t(.library)) {
                    row(l10n.t(.watchedFolders)) {
                        Button(l10n.t(.addFolder)) {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.prompt = l10n.t(.addFolder)
                            if panel.runModal() == .OK, let url = panel.url {
                                library.addLocalFolder(url)
                            }
                        }
                        .buttonStyle(.plain)
                        .bitStyle(.labelMedium)
                        .foregroundStyle(theme.colors.primary)
                    }
                    row(l10n.t(.recent)) {
                        Button(l10n.t(.clear)) { library.clearHistory() }
                            .buttonStyle(.plain)
                            .bitStyle(.labelMedium)
                            .foregroundStyle(BitColors.accentRed)
                    }
                }
                section(l10n.t(.downloadsSection)) {
                    row(l10n.t(.downloadFolder)) {
                        HStack(spacing: 10) {
                            Text(ByteCountFormatter.string(
                                fromByteCount: DownloadStore.shared.totalBytes, countStyle: .file))
                                .bitStyle(.labelMedium)
                                .foregroundStyle(theme.colors.onSurfaceVariant)
                            Button(l10n.t(.openFolder)) { DownloadStore.shared.revealInFinder() }
                                .buttonStyle(.plain)
                                .bitStyle(.labelMedium)
                                .foregroundStyle(theme.colors.primary)
                        }
                    }
                    row(l10n.t(.queue)) {
                        Button(l10n.t(.downloads)) { model.push(.downloads) }
                            .buttonStyle(.plain)
                            .bitStyle(.labelMedium)
                            .foregroundStyle(theme.colors.primary)
                    }
                    row(l10n.t(.clearDownloads)) {
                        Button(l10n.t(.remove)) { DownloadStore.shared.removeAll() }
                            .buttonStyle(.plain)
                            .bitStyle(.labelMedium)
                            .foregroundStyle(BitColors.accentRed)
                    }
                }
                section("Armazenamento e cache") {
                    HStack(spacing: 10) {
                        Text("Cache de capas, canvas e letras: \(CacheMaintenance.formatted(CacheMaintenance.size()))")
                            .bitStyle(.bodyMedium)
                            .foregroundStyle(theme.colors.onSurfaceVariant)
                        Spacer()
                        Button("Limpar") {
                            Task {
                                _ = await CacheMaintenance.clear()
                                cacheCleared = true
                            }
                        }
                        .buttonStyle(.plain)
                        .bitStyle(.labelMedium)
                        .foregroundStyle(theme.colors.primary)
                    }
                    .padding(.horizontal, BitMetrics.gutter)
                    .padding(.bottom, 8)
                    if cacheCleared {
                        Text("Cache limpo.")
                            .bitStyle(.labelSmall)
                            .foregroundStyle(theme.colors.onSurfaceVariant)
                            .padding(.horizontal, BitMetrics.gutter)
                            .padding(.bottom, 8)
                    }
                }
                section("Backup e restauração") {
                    row("Backup do Android") {
                        Button("Importar JSON…") {
                            if let url = BackupPicker.choose() {
                                do {
                                    let object = try BackupImporter.read(from: url)
                                    let result = BackupImporter.apply(object, settings: settings, library: library)
                                    importedReport = result
                                } catch {
                                    importError = error.localizedDescription
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .bitStyle(.labelMedium)
                        .foregroundStyle(theme.colors.primary)
                    }
                    if let importedReport {
                        Text(importedReport.summary)
                            .bitStyle(.labelSmall)
                            .foregroundStyle(theme.colors.onSurfaceVariant)
                            .padding(.horizontal, BitMetrics.gutter)
                            .padding(.bottom, 8)
                    }
                    row("Replay") {
                        Button("Abrir") { model.push(.replay) }
                            .buttonStyle(.plain)
                            .bitStyle(.labelMedium)
                            .foregroundStyle(theme.colors.primary)
                    }
                }
                section(l10n.t(.about)) {
                    row(l10n.t(.version)) {
                        Text(AppInfo.version)
                            .bitStyle(.labelMedium)
                            .foregroundStyle(theme.colors.onSurfaceVariant)
                    }
                    row(l10n.t(.engine)) {
                        Text("AVFoundation · arm64")
                            .bitStyle(.labelMedium)
                            .foregroundStyle(theme.colors.onSurfaceVariant)
                    }
                    HStack(spacing: 10) {
                        Wordmark(height: 18, color: theme.colors.onSurface)
                        Text(l10n.t(.licensed))
                            .bitStyle(.labelSmall)
                            .foregroundStyle(theme.colors.onSurfaceVariant)
                        Spacer()
                    }
                    .padding(.horizontal, BitMetrics.gutter)
                    .padding(.vertical, 10)
                }

                Color.clear.frame(height: 176)
            }
        }
        .scrollIndicators(.never)
        .onAppear {}
    }

    private func providerRow(id: String, index: Int) -> some View {
        let source = LyricsSource(rawValue: id)
        let enabled = settings.lyricsProviders.contains(id)
        return HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(BitFont.font(.medium, 11))
                .foregroundStyle(theme.colors.onSurfaceVariant.opacity(0.6))
                .frame(width: 16)
            Toggle("", isOn: Binding(
                get: { enabled },
                set: { value in
                    if value, !settings.lyricsProviders.contains(id) {
                        settings.lyricsProviders.append(id)
                    } else if !value {
                        settings.lyricsProviders.removeAll { $0 == id }
                    }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(source?.label ?? id)
                    .bitStyle(.bodyLarge)
                    .foregroundStyle(theme.colors.onSurface)
                Text(source?.detail ?? "")
                    .bitStyle(.labelSmall)
                    .foregroundStyle(theme.colors.onSurfaceVariant)
            }
            Spacer()
            Button {
                move(id: id, by: -1)
            } label: {
                Image(systemName: "chevron.up").font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.colors.onSurfaceVariant.opacity(index > 0 ? 0.9 : 0.25))
            .disabled(index == 0)
            Button {
                move(id: id, by: 1)
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.colors.onSurfaceVariant.opacity(index < settings.lyricsProviders.count - 1 ? 0.9 : 0.25))
            .disabled(index == settings.lyricsProviders.count - 1)
        }
        .padding(.horizontal, BitMetrics.gutter)
        .frame(minHeight: 44)
    }


    private func move(id: String, by delta: Int) {
        guard let index = settings.lyricsProviders.firstIndex(of: id) else { return }
        let target = index + delta
        guard settings.lyricsProviders.indices.contains(target) else { return }
        var list = settings.lyricsProviders
        list.swapAt(index, target)
        settings.lyricsProviders = list
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .bitStyle(.labelSmall)
                .tracking(1.0)
                .foregroundStyle(theme.colors.onSurfaceVariant)
                .padding(.horizontal, BitMetrics.gutter)
                .padding(.top, 22)
                .padding(.bottom, 6)
            VStack(spacing: 0) { content() }
                .padding(.bottom, 6)
            Rectangle()
                .fill(theme.colors.outline)
                .frame(height: 0.5)
                .padding(.horizontal, BitMetrics.gutter)
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
                .bitStyle(.bodyLarge)
                .foregroundStyle(theme.colors.onSurface)
            Spacer()
            content()
        }
        .padding(.horizontal, BitMetrics.gutter)
        .frame(minHeight: 46)
    }

    private func toggle(_ title: String, detail: String?, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .bitStyle(.bodyLarge)
                    .foregroundStyle(theme.colors.onSurface)
                if let detail {
                    Text(detail)
                        .bitStyle(.labelSmall)
                        .foregroundStyle(theme.colors.onSurfaceVariant)
                }
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(theme.colors.primary)
        }
        .padding(.horizontal, BitMetrics.gutter)
        .frame(minHeight: 46)
    }
}

enum AppInfo {
    static var version: String {
        let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return bundleVersion ?? "2.0-macos"
    }
}
