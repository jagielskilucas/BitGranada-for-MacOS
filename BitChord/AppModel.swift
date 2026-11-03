//
//  AppModel.swift
//  BitChord for macOS
//
//  The one object the shell reads: which tab is up, what is pushed over it,
//  the feed caches, the search state and the player. The Android equivalent is
//  MainActivity + MainViewModel + AppNavigator, which this deliberately keeps
//  in the same shape so the two stay recognisably the same app.
//

import SwiftUI
import Combine
import WebKit
import AVFoundation
import AppKit

enum Tab: Int, CaseIterable, Identifiable {
    case home, explore, library, search
    var id: Int { rawValue }

    var labelKey: LKey {
        switch self {
        case .home: return .home
        case .explore: return .explore
        case .library: return .library
        case .search: return .search
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .explore: return "square.grid.2x2.fill"
        case .library: return "rectangle.stack.fill"
        case .search: return "magnifyingglass"
        }
    }
}

/// A page pushed over the tabs. Release pages are `release`; the rest are the
/// handful of utility pages the phone has routes for.
enum Route: Hashable, Identifiable {
    case release(kind: Release.Kind, browseId: String, title: String, subtitle: String, thumbnail: String?)
    case localPlaylist(UUID)
    case moods
    case mood(browseId: String, params: String, title: String)
    case settings
    case downloads
    case replay

    var id: String {
        switch self {
        case .release(let kind, let browseId, _, _, _): return "release:\(kind.rawValue):\(browseId)"
        case .localPlaylist(let id): return "localplaylist:\(id)"
        case .moods: return "moods"
        case .mood(let browseId, let params, _): return "mood:\(browseId):\(params)"
        case .settings: return "settings"
        case .downloads: return "downloads"
        case .replay: return "replay"
        }
    }
}

enum SearchFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case songs = "Songs"
    case albums = "Albums"
    case artists = "Artists"
    case playlists = "Playlists"
    var id: String { rawValue }
}

enum PlayerTab: String, CaseIterable, Identifiable {
    case nowPlaying = "Now Playing"
    case lyrics = "Lyrics"
    case queue = "Up Next"
    var id: String { rawValue }
}

struct MoodTile: Identifiable, Hashable {
    var id: String { params }
    var title: String
    var browseId: String
    var params: String
    var color: Color
    /// Cover art pulled from the mood's own playlist on YouTube Music.
    var thumbnailURL: String?
}

@MainActor
final class AppModel: ObservableObject {
    // MARK: Navigation

    @Published var tab: Tab = .home
    @Published var path: [Route] = []
    @Published var isPlayerOpen = false
    @Published var playerTab: PlayerTab = .nowPlaying
    @Published var isRailVisible = true
    /// The player bar grows when the listener scrolls up and shrinks on the way
    /// down, as the phone's mini player does.
    @Published var isPlayerBarExpanded = true
    /// The track whose video is open in the sheet, if any.
    @Published var videoSong: Song?

    // MARK: Data

    @Published private(set) var homeShelves: [Shelf] = []
    @Published private(set) var homeLoading = false
    @Published private(set) var homeError: String?

    @Published var lastBackupReport: BackupReport?
    /// Songs picked from the listener's favourite artists, minus what they
    /// already play — the "based on your taste" row on Home.
    @Published private(set) var tasteRecommendations: [ShelfItem] = []
    private var tasteLoadedAt = Date.distantPast
    /// Taste read from Spotify, when the listener connected it.
    @Published private(set) var spotifyTaste: SpotifyTaste? = SpotifyTasteService.cached()
    @Published private(set) var spotifyTasteBusy = false
    @Published private(set) var spotifyTasteError: String?

    /// The imported playlists, stored whole so they open as playlists rather
    /// than a row of loose tracks.
    /// Whether the clip is being watched. Shared by the side column and the big
    /// player, so opening one keeps what the other was showing.
    /// Play/pause for the music player.
    func togglePlayPause() {
        if player.current == nil {
            if let first = library.favourites.first { playFavourites(startingAt: first) }
            return
        }
        player.togglePlayPause()
    }

    @Published private(set) var spotifyShelf: [ShelfItem] = []
    /// The imported playlist being shown as a sheet, if any.
    @Published var openSpotifyPlaylist: SpotifyTasteImport.Playlist?
    @Published private(set) var spotifyPlaylists: [SpotifyTasteImport.Playlist] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(spotifyPlaylists) {
                UserDefaults.standard.set(data, forKey: "spotify.playlists")
            }
        }
    }

    /// Imports a folder (or a selection of CSVs) as playlists.
    func importSpotifyPlaylistFiles(_ urls: [URL]) {
        let loaded = SpotifyTasteImport.loadPlaylists(from: urls)
        guard !loaded.isEmpty else {
            spotifyTasteError = "Nenhum arquivo reconhecido."
            return
        }
        var merged = spotifyPlaylists.filter { existing in !loaded.contains { $0.name == existing.name } }
        merged.append(contentsOf: loaded)
        spotifyPlaylists = merged.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        spotifyTasteError = nil
    }

    /// The listener's own Last.fm shelves, in Portuguese: recent, artists,
    /// albums and tracks.
    @Published private(set) var lastFMUserShelves: [Shelf] = []

    /// The account whose listening history feeds the home. Seeded on first run,
    /// editable in Settings.
    static let defaultLastFMUser = "jagielskiluc"

    var lastFMUser: String {
        let stored = UserDefaults.standard.string(forKey: "lastfm.user")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty { return stored }
        UserDefaults.standard.set(Self.defaultLastFMUser, forKey: "lastfm.user")
        return Self.defaultLastFMUser
    }

    /// Pulls the four lists and resolves each entry on YouTube Music so every
    /// row is playable. Runs in the background, bounded per list.
    func loadLastFMUser() {
        let user = lastFMUser
        guard !user.isEmpty, LastFMKey.isConfigured else {
            lastFMUserShelves = []
            return
        }
        Task {
            var shelves: [Shelf] = []

            // Recent tracks and top tracks are playable by search; their covers
            // come from the YouTube Music match, resolved a few at a time.
            if let recent = try? await LastFM.shared.recentTracks(user: user, limit: 12), !recent.isEmpty {
                shelves.append(Shelf(title: "Ouvidas recentemente",
                                     items: await self.artworkResolved(recent)))
            }
            if let top = try? await LastFM.shared.topArtists(user: user, limit: 8), !top.isEmpty {
                var items: [ShelfItem] = []
                for artist in top {
                    guard let id = await InnerTubeClient.shared.artistBrowseId(named: artist.name),
                          let page = await self.release(browseId: id, kind: .artist) else { continue }
                    items.append(ShelfItem(title: artist.name, subtitle: "Artista",
                                           thumbnailURL: page.thumbnailURL, videoId: nil,
                                           browseId: id, playlistId: nil, duration: nil,
                                           pageKind: .artist))
                    if items.count >= 8 { break }
                }
                if !items.isEmpty { shelves.append(Shelf(title: "Artistas mais ouvidos", items: items)) }
            }
            if let albums = try? await LastFM.shared.topAlbums(user: user, limit: 8), !albums.isEmpty {
                var items: [ShelfItem] = []
                for album in albums {
                    let query = "\(album.album) \(album.artist)"
                    let rows = await InnerTubeClient.shared.searchAlbums(query: query, limit: 3)
                    guard let best = rows.first else { continue }
                    items.append(best)
                    if items.count >= 8 { break }
                }
                if !items.isEmpty { shelves.append(Shelf(title: "Álbuns mais ouvidos", items: items)) }
            }
            if let tracks = try? await LastFM.shared.topTracks(user: user, limit: 12), !tracks.isEmpty {
                shelves.append(Shelf(title: "Músicas mais ouvidas",
                                     items: await self.artworkResolved(tracks)))
            }

            let value = shelves
            await MainActor.run { self.lastFMUserShelves = value }
        }
    }

    /// Recommendation row built only from Spotify artists.
    private func buildRecommendationsFromSpotify(force: Bool) async {
        guard let spotify = spotifyTaste else { return }
        let stale = Date().timeIntervalSince(tasteLoadedAt) > 15 * 60
        guard force || tasteRecommendations.isEmpty || stale else { return }
        var items: [ShelfItem] = []
        for name in spotify.artists.prefix(4) {
            guard let id = await InnerTubeClient.shared.artistBrowseId(named: name),
                  let page = await release(browseId: id, kind: .artist) else { continue }
            for song in page.songs.prefix(6) {
                items.append(ShelfItem(title: song.title, subtitle: song.artist,
                                       thumbnailURL: song.thumbnailURL, videoId: song.videoId,
                                       browseId: nil, playlistId: nil,
                                       duration: song.duration, pageKind: nil))
            }
        }
        tasteRecommendations = Array(items.shuffled().prefix(18))
        tasteLoadedAt = Date()
    }

    /// "Parecido com <artista>", built from Last.fm's similarity graph.
    @Published private(set) var lastFMShelf: Shelf?

    /// Turns Last.fm names into playable cards: a YouTube Music match per track,
    /// in small batches so the row arrives quickly and keeps filling in.
    private func artworkResolved(_ scrobbles: [LastFM.Scrobble],
                                 limit: Int = 12) async -> [ShelfItem] {
        var items: [ShelfItem] = scrobbles.prefix(limit).map { item in
            ShelfItem(title: item.title, subtitle: item.artist, thumbnailURL: nil,
                      videoId: nil, browseId: nil, playlistId: nil,
                      duration: nil, pageKind: nil)
        }
        for start in stride(from: 0, to: items.count, by: 4) {
            let slice = Array(items[start..<min(start + 4, items.count)])
            let resolved = await withTaskGroup(of: (Int, Song?).self) { group in
                for (offset, item) in slice.enumerated() {
                    group.addTask {
                        let query = "\(item.title) \(item.subtitle)"
                        let match = await InnerTubeClient.shared.songCandidates(query, limit: 1).first
                        return (start + offset, match)
                    }
                }
                var output: [(Int, Song?)] = []
                for await pair in group { output.append(pair) }
                return output
            }
            for (index, song) in resolved {
                guard let song, items.indices.contains(index) else { continue }
                items[index].thumbnailURL = song.thumbnailURL
                items[index].videoId = song.videoId
                items[index].duration = song.duration
            }
        }
        return items
    }

    /// "Parecido com <artista>", from the similarity graph of what is playing.
    func loadLastFMRecommendations(seedArtist: String? = nil, title: String? = nil) {
        guard LastFMKey.isConfigured else { lastFMShelf = nil; return }
        let artist = seedArtist ?? player.current?.artist
        let trackTitle = title ?? player.current?.title
        guard let artist, !artist.isEmpty else { return }
        Task {
            var names: [String] = []
            if let trackTitle, !trackTitle.isEmpty {
                names = ((try? await LastFM.shared.similarTracks(title: trackTitle,
                                                                 artist: artist)) ?? []).map(\.name)
            }
            if names.isEmpty {
                names = ((try? await LastFM.shared.similarArtists(to: artist)) ?? []).map(\.name)
            }
            var items: [ShelfItem] = []
            for name in names.prefix(3) {
                guard let id = await InnerTubeClient.shared.artistBrowseId(named: name),
                      let page = await release(browseId: id, kind: .artist) else { continue }
                for song in page.songs.prefix(5) {
                    items.append(ShelfItem(title: song.title, subtitle: song.artist,
                                           thumbnailURL: song.thumbnailURL, videoId: song.videoId,
                                           browseId: nil, playlistId: nil,
                                           duration: song.duration, pageKind: nil))
                }
                if items.count >= 15 { break }
            }
            let shelf = items.isEmpty ? nil
                : Shelf(title: "Parecido com \(artist)", items: Array(items.prefix(15)))
            await MainActor.run { self.lastFMShelf = shelf }
        }
    }


    /// The imported playlists as cards: title/artist, played by searching.
    private func rebuildSpotifyShelf() {
        guard let taste = spotifyTaste else { spotifyShelf = []; return }
        spotifyShelf = taste.tracks.prefix(40).map { track in
            ShelfItem(title: track.title, subtitle: track.artist,
                      thumbnailURL: nil, videoId: nil, browseId: nil,
                      playlistId: nil, duration: nil, pageKind: nil)
        }
    }


    /// A card from a video row: now that the video pipeline is gone, it simply
    /// plays the track — the row is a shortcut to the audio.
    func playVideo(_ item: ShelfItem, theme: BitTheme) {
        if item.videoId == nil {
            playBySearch(title: item.title, artist: item.subtitle)
            return
        }
        activate(item)
    }

    /// Plays the first YouTube Music match for a title/artist pair — what the
    /// imported Spotify cards use, since they carry no video id.
    func playBySearch(title: String, artist: String) {
        Task {
            let query = artist.isEmpty ? title : "\(title) \(artist)"
            let candidates = await InnerTubeClient.shared.songCandidates(query, limit: 5)
            guard let song = candidates.first else { return }
            await MainActor.run {
                player.play(song, in: [song], startRadio: false)
                isRailVisible = true
            }
        }
    }

    /// Taste from a file the listener exports (Exportify CSV, Spotify data JSON).
    func importSpotifyTaste(from url: URL) {
        spotifyTasteError = nil
        do {
            let taste = try SpotifyTasteImport.load(from: url)
            spotifyTaste = taste
            rebuildSpotifyShelf()
            UserDefaults.standard.set(try? JSONEncoder().encode(taste), forKey: "spotify.taste")
            if let data = UserDefaults.standard.data(forKey: "spotify.playlists"),
           let saved = try? JSONDecoder().decode([SpotifyTasteImport.Playlist].self, from: data) {
            spotifyPlaylists = saved
        }
        loadLastFMRecommendations()
        loadLastFMUser()
        loadHighlights()
        loadExploreArtists()
        rebuildSpotifyShelf()
        print("spotify: gosto salvo com \(spotifyTaste?.artists.count ?? 0) artistas, \(spotifyTaste?.tracks.count ?? 0) faixas")
        Task { await loadTasteRecommendations(force: true) }
        } catch {
            spotifyTasteError = error.localizedDescription
        }
    }

    /// Reads the listener's top artists and tracks from Spotify and folds them
    /// into the Home recommendations.
    func refreshSpotifyTaste() {
        guard !spotifyTasteBusy else { return }
        spotifyTasteBusy = true
        spotifyTasteError = nil
        Task {
            defer { spotifyTasteBusy = false }
            do {
                spotifyTaste = try await SpotifyTasteService.shared.load()
                await loadTasteRecommendations(force: true)
            } catch {
                spotifyTasteError = error.localizedDescription
            }
        }
    }
    @Published private(set) var moods: [MoodTile] = []
    @Published private(set) var moodsLoading = false
    @Published private(set) var moodShelves: [Shelf] = []
    @Published private(set) var moodLoading = false

    @Published private(set) var releaseCache: [String: Release] = [:]

    // MARK: Search

    @Published var query: String = ""
    @Published private(set) var results: [SearchRow] = []
    @Published private(set) var isSearching = false
    @Published private(set) var searchError: String?
    @Published var filter: SearchFilter = .all
    private var searchTask: Task<Void, Never>?
    private var lastQuery = ""

    // MARK: Objects

    @Published var player = PlayerEngine()
    @Published var library = LibraryStore()
    @Published var settings = AppSettings()
    @Published var lyrics = LyricsStore()

    /// The app's single model. ScreenshotDriver and the menu commands reach it
    /// without threading bindings through the scene graph.
    static let shared = AppModel()

    private var didBootstrap = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        player.downloadResolver = { song in DownloadStore.shared.localURL(for: song) }
        player.externalResolver = { [weak self] song in
            guard let self, self.settings.preferAddonQuality else { return nil }
            return await AddonRegistry.shared.resolve(song)
        }
        player.crossfadeSeconds = settings.crossfadeSeconds
        player.gaplessEnabled = settings.gaplessEnabled
        settings.$crossfadeSeconds
            .sink { [weak self] value in self?.player.crossfadeSeconds = value }
            .store(in: &cancellables)
        settings.$gaplessEnabled
            .sink { [weak self] value in self?.player.gaplessEnabled = value }
            .store(in: &cancellables)
        settings.$addonSources
            .sink { urls in
                Task { await AddonRegistry.shared.load(urls: urls) }
            }
            .store(in: &cancellables)

        player.onTrackStarted = { [weak self] song in
            self?.library.recordPlay(song)
            if self?.settings.showLyricsOnOpen == true {
                self?.playerTab = .lyrics
            }
        }
    }

    // MARK: Lifecycle

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        importBackupIfRequested()
        runSpotifyDiagnosticIfRequested()
        Task { await AddonRegistry.shared.load(urls: settings.addonSources) }
        refreshHome()
        loadMoods()
        if let data = UserDefaults.standard.data(forKey: "spotify.playlists"),
           let saved = try? JSONDecoder().decode([SpotifyTasteImport.Playlist].self, from: data) {
            spotifyPlaylists = saved
        }
        loadLastFMRecommendations()
        loadLastFMUser()
        loadHighlights()
        loadExploreArtists()
        rebuildSpotifyShelf()
        print("spotify: gosto salvo com \(spotifyTaste?.artists.count ?? 0) artistas, \(spotifyTaste?.tracks.count ?? 0) faixas")
        Task { await loadTasteRecommendations(force: true) }
        loadLastFMRecommendations()
    }

    /// One-shot Spotify check for automation: mint the token, look up one
    /// canvas, print every step, quit.
    private func runSpotifyDiagnosticIfRequested() {
        if ProcessInfo.processInfo.environment["BITCHORD_ADDON_TEST"] == "1" {
            Task {
                await AddonRegistry.shared.load(urls: settings.addonSources)
                let song = Song(videoId: "Rgrt_8mXrK8", title: "Get Lucky", artist: "Daft Punk",
                                album: "Random Access Memories", duration: 369, thumbnailURL: nil)
                let info = await AddonRegistry.shared.resolve(song)
                print("addon test:", info?.label ?? "none", info?.url.absoluteString.prefix(80) ?? "")
                NSApp.terminate(nil)
            }
            return
        }
        if let urlString = ProcessInfo.processInfo.environment["BITCHORD_PROBE_PLAY"],
           let url = URL(string: urlString) {
            Task {
                let item = AVPlayerItem(url: url)
                let probe = AVPlayer(playerItem: item)
                probe.isMuted = true
                probe.play()
                for tick in 1...6 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    let t = probe.currentTime().seconds
                    print("playdiag: \(tick)s status=\(item.status.rawValue) time=\(String(format: "%.2f", t)) rate=\(probe.rate) tracks=\(item.tracks.count) erro=\(item.error?.localizedDescription ?? "-")")
                }
                NSApp.terminate(nil)
            }
            return
        }

        if let probe = ProcessInfo.processInfo.environment["BITCHORD_BANNER_PROBE"] {
            Task {
                let parts = probe.split(separator: "|").map(String.init)
                let banner = await AppleArtistLogoService.shared.banner(
                    for: parts.first ?? "", titles: parts.count > 1 ? [parts[1]] : [])
                print("bannerprobe: logo=\(banner?.logo != nil) video=\(banner?.videoURL?.absoluteString.prefix(90) ?? "nil")")
                if let url = banner?.videoURL {
                    let best = await CanvasVideoView.CanvasWebView.highestVariant(of: url)
                    print("bannerprobe: variante=\(best?.lastPathComponent ?? "nil")")
                }
                NSApp.terminate(nil)
            }
            return
        }
        if let probe = ProcessInfo.processInfo.environment["BITCHORD_BANNER_PROBE"] {
            Task {
                let parts = probe.split(separator: "|").map(String.init)
                let started = Date()
                let banner = await AppleArtistLogoService.shared.banner(
                    for: parts.first ?? "", titles: parts.count > 1 ? [parts[1]] : [])
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                print("bannerprobe: \(elapsed)ms logo=\(banner?.logo != nil) video=\(banner?.videoURL?.lastPathComponent ?? "nil")")
                if let url = banner?.videoURL {
                    let best = await CanvasVideoView.CanvasWebView.highestVariant(of: url, maxHeight: 1080)
                    print("bannerprobe: variante=\(best?.lastPathComponent ?? "nil")")
                }
                NSApp.terminate(nil)
            }
            return
        }
        if let probe = ProcessInfo.processInfo.environment["BITCHORD_LYRICS_PROBE"] {
            Task {
                let parts = probe.split(separator: "|").map(String.init)
                let song = Song(videoId: "x", title: parts.first ?? "",
                                artist: parts.count > 1 ? parts[1] : "",
                                album: nil, duration: Double(parts.count > 2 ? parts[2] : "") ?? nil,
                                thumbnailURL: nil)
                let found = await LyricsService.shared.find(
                    song: song,
                    order: LyricsSource.defaultOrder,
                    keys: [:],
                    onAttempt: { _ in }
                )
                if let found {
                    print("lyricprobe: fonte=\(found.source) synced=\(found.synced) linhas=\(found.lines.count)")
                    print("lyricprobe: inicio=\(found.lines.prefix(2).map(\.text).joined(separator: " / "))")
                } else {
                    print("lyricprobe: nada")
                }
                NSApp.terminate(nil)
            }
            return
        }
        if let probe = ProcessInfo.processInfo.environment["BITCHORD_CLIP_CHANNEL"] {
            Task {
                let parts = probe.split(separator: "|").map(String.init)
                let title = parts.first ?? ""
                let artist = parts.count > 1 ? parts[1] : ""
                let id = await InnerTubeClient.shared.officialVideoId(title: title, artist: artist)
                print("clipchannel: \(title) / \(artist) -> \(id ?? "none")")
                NSApp.terminate(nil)
            }
            return
        }
        if ProcessInfo.processInfo.environment["BITCHORD_CANVAS_Q_TEST"] == "1" {
            Task {
                let song = Song(videoId: "x", title: "SAOKO", artist: "ROSALÍA",
                                album: nil, duration: nil, thumbnailURL: nil)
                if let clip = await CanvasService.shared.clip(for: song) {
                    print("canvasq: master=\(clip.url.lastPathComponent)")
                    let best = await CanvasVideoView.CanvasWebView.highestVariant(of: clip.url)
                    print("canvasq: variante=\(best?.lastPathComponent ?? "nil")")
                } else {
                    print("canvasq: sem canvas")
                }
                NSApp.terminate(nil)
            }
            return
        }
        if ProcessInfo.processInfo.environment["BITCHORD_STATS_TEST"] == "1" {
            Task {
                do {
                    let info = try await LastFM.shared.trackInfo(title: "SAOKO", artist: "ROSALÍA")
                    print("stats: ouvintes=\(info.listeners) plays=\(info.playcount) tags=\(info.tags.prefix(3).joined(separator: ",")) album=\(info.album ?? "-")")
                } catch {
                    print("stats: erro =", error.localizedDescription)
                }
                NSApp.terminate(nil)
            }
            return
        }
        if ProcessInfo.processInfo.environment["BITCHORD_JIOSAAVN_TEST"] == "1" {
            Task {
                let hit = await JioSaavn.shared.stream(title: "SAOKO", artist: "ROSALÍA",
                                                       expectedDuration: 137)
                print("jiosaavn:", hit.map { "\($0.label) \($0.url.absoluteString.prefix(70))" } ?? "none")
                NSApp.terminate(nil)
            }
            return
        }
        if ProcessInfo.processInfo.environment["BITCHORD_LASTFM_TEST"] == "1" {
            Task {
                do {
                    let artists = try await LastFM.shared.similarArtists(to: "ROSALÍA", limit: 4)
                    print("lastfm: artistas =", artists.map(\.name).joined(separator: ", "))
                    let tracks = (try? await LastFM.shared.similarTracks(title: "SAOKO", artist: "ROSALÍA", limit: 4)) ?? []
                    print("lastfm: faixas =", tracks.map(\.name).joined(separator: ", "))
                    self.loadLastFMRecommendations(seedArtist: "ROSALÍA", title: "SAOKO")
                    try? await Task.sleep(nanoseconds: 14_000_000_000)
                    if let shelf = self.lastFMShelf {
                        print("lastfm: prateleira =", shelf.title, "com", shelf.items.count, "itens:",
                              shelf.items.prefix(3).map(\.title).joined(separator: " | "))
                    } else {
                        print("lastfm: prateleira vazia")
                    }
                    self.loadLastFMUser()
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    for shelf in self.lastFMUserShelves {
                        print("lastfm user:", shelf.title, "->", shelf.items.count, "itens:",
                              shelf.items.prefix(2).map(\.title).joined(separator: " | "))
                    }
                    if self.lastFMUserShelves.isEmpty { print("lastfm user: vazio (usuário=\(self.lastFMUser))") }
                } catch {
                    print("lastfm: erro =", error.localizedDescription)
                }
                NSApp.terminate(nil)
            }
            return
        }
        if let probe = ProcessInfo.processInfo.environment["BITCHORD_PROBE_CANVAS"] {
            Task {
                let parts = probe.split(separator: "|").map(String.init)
                let song = Song(videoId: "x", title: parts.first ?? "SAOKO",
                                artist: parts.count > 1 ? parts[1] : "ROSALÍA",
                                album: nil, duration: nil, thumbnailURL: nil)
                for attempt in 1...3 {
                    let clip = await CanvasService.shared.clip(for: song)
                    print("canvasdiag: tentativa \(attempt) -> \(clip?.url.absoluteString ?? "nil")")
                    if clip != nil { break }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
                NSApp.terminate(nil)
            }
            return
        }


        guard ProcessInfo.processInfo.environment["BITCHORD_SPOTIFY_TEST"] == "1" else { return }
        Task {
            print("spotify: cookie stored = \(SpotifySecrets.hasCookie)")
            let song = Song(videoId: "Rgrt_8mXrK8", title: "Get Lucky",
                            artist: "Daft Punk", album: "Random Access Memories",
                            duration: 369, thumbnailURL: nil)
            let clip = await SpotifyCanvasService.shared.clip(for: song)
            print("spotify: RESULT \(clip?.url.absoluteString ?? "none")")
            NSApp.terminate(nil)
        }
    }

    /// One-shot import for automation: BITCHORD_IMPORT_BACKUP=<path> on launch.
    /// The same code path the "Importar JSON…" button uses.
    private func importBackupIfRequested() {
        // Automation hook: hand the app a cookie once, it lands in the Keychain.
        if let cookie = ProcessInfo.processInfo.environment["BITCHORD_SPOTIFY_COOKIE"], !cookie.isEmpty {
            SpotifySecrets.saveCookie(cookie)
        }
        if let appearance = ProcessInfo.processInfo.environment["BITCHORD_APPEARANCE"],
           let parsed = AppAppearance(rawValue: appearance) {
            settings.appearance = parsed
        }
        guard let path = ProcessInfo.processInfo.environment["BITCHORD_IMPORT_BACKUP"],
              let object = try? BackupImporter.read(from: URL(fileURLWithPath: path)) else { return }
        lastBackupReport = BackupImporter.apply(object, settings: settings, library: library)
        print("backup import: \(lastBackupReport?.summary ?? "")")
    }

    func refreshHome() {
        guard !homeLoading else { return }
        homeLoading = true
        homeError = nil
        Task {
            do {
                let shelves = try await InnerTubeClient.shared.home()
                await MainActor.run {
                    self.homeShelves = shelves
                    self.homeLoading = false
                }
            } catch {
                await MainActor.run {
                    self.homeError = error.localizedDescription
                    self.homeLoading = false
                }
            }
        }
    }

    @Published private(set) var highlightShelves: [Shelf] = []
    /// Artists with photos, for the Explore page's top row.
    @Published private(set) var exploreArtists: [ShelfItem] = []

    private var highlightsLoadedAt = Date.distantPast

    private static func isMixShelf(_ title: String) -> Bool {
        let lower = title.lowercased()
        return lower.contains("mixtape") || lower.contains("mix") || lower.contains("para você")
            || lower.contains("madrugada") || lower.contains("feito para")
    }

    /// Rows the phone shows above/below the personalized feed. With a signed-in
    /// cookie the page itself is read; without one, the public browse pages are.
    func loadHighlights(force: Bool = false) {
        let stale = Date().timeIntervalSince(highlightsLoadedAt) > 10 * 60
        guard force || highlightShelves.isEmpty || stale else { return }
        Task {
            // API only: the signed-in web reader needed the Google login, which
            // is gone, and its process cost more than the extra rows were worth.
            var shelves: [Shelf] = []
            if shelves.isEmpty {
                shelves = await InnerTubeClient.shared.highlights()
                print("highlights: api \(shelves.count) prateleiras")
            }
            // The mixes ("Mixtapes para você" / "Clássicos da madrugada") lead
            // the home: they are the personalised row the listener looks for.
            let value = shelves.sorted { a, b in
                Self.isMixShelf(a.title) && !Self.isMixShelf(b.title)
            }
            await MainActor.run {
                self.highlightShelves = value
                self.highlightsLoadedAt = Date()
            }
        }
    }

    /// Artist photos for the main categories: the charts page is the closest the
    /// network gives to "the artists of this genre", with real portraits.
    func loadExploreArtists() {
        guard exploreArtists.isEmpty else { return }
        Task {
            let shelves = (try? await InnerTubeClient.shared.browseShelves(
                browseId: "FEmusic_charts", params: nil)) ?? []
            var items: [ShelfItem] = []
            for shelf in shelves {
                for item in shelf.items where item.pageKind == .artist || item.browseId?.hasPrefix("UC") == true {
                    items.append(item)
                }
            }
            let value = Array(items.prefix(24))
            await MainActor.run { self.exploreArtists = value }
        }
    }

    func loadMoods() {
        guard moods.isEmpty, !moodsLoading else { return }
        moodsLoading = true
        Task {
            do {
                let tiles = try await InnerTubeClient.shared.moodCategories()
                await MainActor.run {
                    self.moods = tiles.map { category in
                        MoodTile(
                            title: category.title,
                            browseId: category.browseId,
                            params: category.params,
                            color: Color(hex: category.color),
                            thumbnailURL: nil
                        )
                    }
                    self.moodsLoading = false
                }
                // Covers arrive one by one, in parallel, so the grid paints at
                // once and fills in as each mood page answers.
                let snapshot = tiles
                // Every category gets a cover, in waves of six: the grid paints
                // at once and keeps filling in, instead of stopping at fourteen.
                for start in stride(from: 0, to: snapshot.count, by: 6) {
                    let slice = Array(snapshot.enumerated())[start..<min(start + 6, snapshot.count)]
                    await withTaskGroup(of: (Int, String?).self) { group in
                        for (index, category) in slice {
                            group.addTask {
                                let cover = await InnerTubeClient.shared.moodCover(
                                    browseId: category.browseId, params: category.params
                                )
                                return (index, cover)
                            }
                        }
                        for await (index, cover) in group {
                            guard let cover else { continue }
                            await MainActor.run {
                                guard self.moods.indices.contains(index) else { return }
                                self.moods[index].thumbnailURL = cover
                            }
                        }
                    }
                }
            } catch {
                await MainActor.run { self.moodsLoading = false }
            }
        }
    }

    func openMood(_ mood: MoodTile) {
        path.append(.mood(browseId: mood.browseId, params: mood.params, title: mood.title))
        loadMoodShelves(browseId: mood.browseId, params: mood.params)
    }

    func loadMoodShelves(browseId: String, params: String) {
        moodLoading = true
        moodShelves = []
        Task {
            do {
                let shelves = try await InnerTubeClient.shared.browseShelves(browseId: browseId, params: params)
                await MainActor.run {
                    self.moodShelves = shelves
                    self.moodLoading = false
                }
            } catch {
                await MainActor.run { self.moodLoading = false }
            }
        }
    }

    // MARK: Navigation actions

    func select(_ newTab: Tab) {
        if tab == newTab {
            // Tapping the current tab pops back to its root, as the phone does.
            path.removeAll()
            return
        }
        path.removeAll()
        tab = newTab
        if newTab == .explore { loadMoods() }
    }

    func push(_ route: Route) {
        isPlayerBarExpanded = true
        path.append(route)
    }

    func pop() {
        guard !path.isEmpty else { return }
        isPlayerBarExpanded = true
        path.removeLast()
    }

    func popToRoot() {
        path.removeAll()
    }

    func openPlayer(_ playerTab: PlayerTab = .nowPlaying) {
        self.playerTab = playerTab
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            isPlayerOpen = true
        }
    }

    func closePlayer() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) {
            isPlayerOpen = false
        }
    }

    // MARK: Playing

    /// Plays a shelf card: a track starts its radio, a page opens instead.
    func activate(_ item: ShelfItem) {
        if let song = item.song {
            player.play(song, startRadio: true)
            // Starting a song is not a request for the full player: play it and
            // reveal the side column, which is where the now-playing lives.
            isRailVisible = true
        } else if let browseId = item.browseId {
            openRelease(browseId: browseId, kind: item.pageKind ?? .playlist,
                        title: item.title, subtitle: item.subtitle, thumbnail: item.thumbnailURL)
        }
    }

    func activate(_ row: SearchRow) {
        if let song = row.song {
            player.play(song, startRadio: true)
            isRailVisible = true
        } else if let browseId = row.browseId {
            openRelease(browseId: browseId,
                        kind: row.kind == .album ? .album : (row.kind == .artist ? .artist : .playlist),
                        title: row.title, subtitle: row.subtitle, thumbnail: row.thumbnailURL)
        }
    }

    func openRelease(browseId: String, kind: Release.Kind, title: String, subtitle: String, thumbnail: String?) {
        if let localID = Self.localPlaylistID(browseId) {
            path.append(.localPlaylist(localID))
            return
        }
        path.append(.release(kind: kind, browseId: browseId, title: title, subtitle: subtitle, thumbnail: thumbnail))
        Task { _ = await release(browseId: browseId, kind: kind) }
    }

    static func localPlaylistID(_ browseId: String) -> UUID? {
        guard browseId.hasPrefix("local:") else { return nil }
        return UUID(uuidString: String(browseId.dropFirst("local:".count)))
    }

    /// Loads (and caches) an album/playlist/artist page.
    func release(browseId: String, kind: Release.Kind) async -> Release? {
        if let cached = releaseCache[browseId] { return cached }
        do {
            let release = try await InnerTubeClient.shared.release(browseId: browseId, kindHint: kind)
            await MainActor.run { self.releaseCache[browseId] = release }
            return release
        } catch {
            return nil
        }
    }

    func playRelease(_ release: Release, from song: Song? = nil) {
        guard !release.songs.isEmpty else { return }
        // Album pages list tracks without their own artwork. Hand each one the
        // release cover so the player and the column show a picture, not a note.
        let cover = release.artwork(600)?.absoluteString
        let filled = release.songs.map { item -> Song in
            guard item.thumbnailURL == nil, let cover else { return item }
            var copy = item
            copy.thumbnailURL = cover
            return copy
        }
        let target = song.flatMap { chosen in filled.first { $0.id == chosen.id } } ?? song
        player.playAll(filled, startingAt: target)
        // Playing is not a request for the full screen.
        isRailVisible = true
    }

    // MARK: Search

    func clearSearch() {
        searchTask?.cancel()
        query = ""
        results = []
        lastQuery = ""
        isSearching = false
        searchError = nil
    }

    /// Builds a recommendation row from the archive's most-played artists:
    /// their own top songs that the listener has not been replaying.
    /// Recommendations from the archive, refreshed so the row does not freeze
    /// on the same three artists forever:
    /// - a different slice of the top artists each day;
    /// - nothing already played recently, nor too many tracks from one artist;
    /// - reloaded when it goes stale (or when the history moves on).
    func loadTasteRecommendations(force: Bool = false) async {
        // Spotify taste alone is enough: the archive is a bonus, not a
        // prerequisite.
        guard let taste = library.archiveTaste else {
            await buildRecommendationsFromSpotify(force: force)
            return
        }
        let stale = Date().timeIntervalSince(tasteLoadedAt) > 15 * 60
        guard force || tasteRecommendations.isEmpty || stale else { return }

        let played = Set(taste.tracks.map { CanvasService.normalize($0.title) })
            .union(library.recentlyPlayed.map { CanvasService.normalize($0.title) })

        // Rotating window: which three of the top eight artists lead today.
        let pool = Array(taste.artists.prefix(8))
        guard !pool.isEmpty else { return }
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        let start = day % pool.count
        let chosen = (0..<min(3, pool.count)).map { pool[(start + $0) % pool.count] }

        // Spotify's top artists lead when connected: they are a sharper signal
        // than the archive, which only knows what this app played.
        var names = chosen.map(\.name)
        if let spotify = spotifyTaste {
            names = Array(spotify.artists.prefix(2)) + names
        }

        var items: [ShelfItem] = []
        for name in names.prefix(4) {
            guard let id = await InnerTubeClient.shared.artistBrowseId(named: name),
                  let page = await release(browseId: id, kind: .artist) else { continue }
            // Interleave: two from each artist per pass keeps the row varied.
            let fresh = page.songs.filter { !played.contains(CanvasService.normalize($0.title)) }
            for song in fresh.prefix(6) {
                items.append(ShelfItem(
                    title: song.title,
                    subtitle: song.artist,
                    thumbnailURL: song.thumbnailURL,
                    videoId: song.videoId,
                    browseId: nil,
                    playlistId: nil,
                    duration: song.duration,
                    pageKind: nil
                ))
            }
        }

        // Shuffle so the order is not the catalogue's every time, then keep the
        // first block of each artist at the front for variety.
        tasteRecommendations = Array(items.shuffled().prefix(18))
        tasteLoadedAt = Date()
    }

    /// The dock follows the page: up brings the full bar back, down tucks it
    /// into the compact dock. Called by every vertical page scroll view.
    func trackDockScroll(up: Bool) {
        guard isPlayerBarExpanded != up else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) {
            isPlayerBarExpanded = up
        }
    }

    /// Opens the artist page for a name, resolving the browse id on demand.
    func openArtist(named name: String, matching trackTitle: String? = nil) {
        let cleaned = name.components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespaces) ?? name
        guard !cleaned.isEmpty else { return }
        Task {
            if let id = await InnerTubeClient.shared.artistBrowseId(named: cleaned, matching: trackTitle) {
                await MainActor.run {
                    self.openRelease(browseId: id, kind: .artist, title: cleaned,
                                     subtitle: "Artista", thumbnail: nil)
                }
            } else {
                // No artist page found: at least put the name in Search, so the
                // tap leads somewhere useful instead of doing nothing.
                await MainActor.run {
                    self.select(.search)
                    self.searchNow(cleaned)
                }
            }
        }
    }

    func searchNow(_ text: String? = nil) {
        let query = (text ?? self.query).trimmingCharacters(in: .whitespacesAndNewlines)
        if let text { self.query = text }
        guard query.count > 1 else {
            results = []
            isSearching = false
            return
        }
        if query == lastQuery, !results.isEmpty { return }
        lastQuery = query
        searchTask?.cancel()
        isSearching = true
        searchError = nil
        searchTask = Task {
            do {
                // A small debounce keeps typing from firing a request per key.
                try await Task.sleep(nanoseconds: 260_000_000)
                guard !Task.isCancelled else { return }
                let rows = try await InnerTubeClient.shared.search(query)
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.results = rows
                    self.isSearching = false
                    self.library.rememberSearch(query)
                }
            } catch {
                await MainActor.run {
                    self.isSearching = false
                    self.searchError = error.localizedDescription
                }
            }
        }
    }

    var filteredResults: [SearchRow] {
        switch filter {
        case .all: return results
        case .songs: return results.filter { $0.kind == .song || $0.kind == .video }
        case .albums: return results.filter { $0.kind == .album }
        case .artists: return results.filter { $0.kind == .artist }
        case .playlists: return results.filter { $0.kind == .playlist }
        }
    }

    // MARK: Library helpers

    var localShelfItems: [ShelfItem] {
        library.localSongs.map { song in
            ShelfItem(
                title: song.title,
                subtitle: song.artist,
                thumbnailURL: song.thumbnailURL,
                videoId: nil,
                browseId: nil,
                duration: song.duration,
                pageKind: nil
            )
        }
    }

    func playLocal(_ song: Song) {
        player.playAll(library.localSongs, startingAt: song)
        isRailVisible = true
    }

    func playFavourites(startingAt song: Song? = nil) {
        guard !library.favourites.isEmpty else { return }
        player.playAll(library.favourites, startingAt: song)
        isRailVisible = true
    }

    /// Lyrics lookup with the user's provider order and keys.
    func loadLyrics(for song: Song, force: Bool = false) {
        lyrics.load(for: song, order: settings.lyricsProviders,
                    keys: settings.lyricsKeys, force: force)
    }

    // MARK: Player helpers used by the shell

    #if SNAPSHOT
    /// Snapshot-harness only: seed the model with the fixtures in
    /// SnapshotFixtures so the renderer can draw real screens without a network.
    func previewSeed() {
        homeShelves = SnapshotFixtures.shelves
        homeLoading = false
        homeError = nil
        moods = SnapshotFixtures.moods
        results = SnapshotFixtures.searchRows
        query = "daft punk"
        library.previewSeed()
        player.previewLoad(queue: SnapshotFixtures.songs, index: 0)
    }
    #endif
}
