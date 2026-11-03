//
//  LibraryStore.swift
//  BitChord for macOS
//
//  Everything the user owns: favourites, playlists, play history, recent
//  searches and local files. One JSON document in Application Support.
//
//  Android counterpart: data/OfflinePlaylists.kt, data/LocalMediaRepository.kt
//  and data/settings/SearchHistory.kt, collapsed into one store because a
//  desktop has one library rather than a per-account one.
//

import Foundation
import AppKit
import AVFoundation

struct LibraryPlaylist: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var songs: [Song]
    var createdAt: Date
    /// Set when the playlist mirrors a YouTube Music playlist, so it can be
    /// refreshed from the source rather than drifting.
    var sourceBrowseId: String?

    init(id: UUID = UUID(), name: String, songs: [Song] = [], createdAt: Date = Date(), sourceBrowseId: String? = nil) {
        self.id = id
        self.name = name
        self.songs = songs
        self.createdAt = createdAt
        self.sourceBrowseId = sourceBrowseId
    }
}

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id: String { "\(song.id)|\(playedAt.timeIntervalSince1970)" }
    var song: Song
    var playedAt: Date
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var favourites: [Song] = []
    @Published private(set) var playlists: [LibraryPlaylist] = []
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var recentSearches: [String] = []
    @Published private(set) var localSongs: [Song] = []
    /// Months imported from the Android backup, newest first — what Replay draws.
    @Published private(set) var listeningMonths: [ListeningMonth] = []
    @Published private(set) var localFolders: [String] = []
    @Published private(set) var isScanning = false

    private struct Document: Codable {
        var favourites: [Song] = []
        var playlists: [LibraryPlaylist] = []
        var history: [HistoryEntry] = []
        var recentSearches: [String] = []
        var localFolders: [String] = []
        var listening: [ListeningMonth]? = nil
    }

    private var saveTask: Task<Void, Never>?

    init() {
        load()
        if !localFolders.isEmpty {
            Task { await scanLocalFolders() }
        }
    }

    // MARK: Persistence

    /// Where the library lives. `BITCHORD_DATA_DIR` exists for testing and for
    /// a portable run (a folder beside the app); otherwise Application Support.
    static var storageDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["BITCHORD_DATA_DIR"], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let url = base.appendingPathComponent("BitGranada", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var documentURL: URL? {
        Self.storageDirectory.appendingPathComponent("library.json")
    }

    private func load() {
        guard let url = documentURL,
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data) else { return }
        favourites = document.favourites
        playlists = document.playlists
        history = document.history
        recentSearches = document.recentSearches
        localFolders = document.localFolders
        listeningMonths = document.listening ?? []
    }

    /// Immediate write, used by the backup importer: a debounced save can be
    /// cancelled by the next edit, and an import must survive a quit.
    func saveNow() {
        saveTask?.cancel()
        let snapshot = Document(
            favourites: favourites,
            playlists: playlists,
            history: history,
            recentSearches: recentSearches,
            localFolders: localFolders,
            listening: listeningMonths
        )
        guard let url = documentURL else {
            print("library save: no document URL")
            return
        }
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
            print("library saved: \(url.path) (\(data.count) bytes)")
        } catch {
            print("library save failed: \(error)")
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = Document(
            favourites: favourites,
            playlists: playlists,
            history: history,
            recentSearches: recentSearches,
            localFolders: localFolders,
            listening: listeningMonths
        )
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let url = self.documentURL else { return }
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                print("library save failed: \(error)")
            }
        }
    }

    // MARK: Favourites

    func isFavourite(_ song: Song) -> Bool {
        favourites.contains { $0.id == song.id }
    }

    func toggleFavourite(_ song: Song) {
        if let index = favourites.firstIndex(where: { $0.id == song.id }) {
            favourites.remove(at: index)
        } else {
            favourites.insert(song, at: 0)
        }
        scheduleSave()
    }

    // MARK: Playlists

    @discardableResult
    func createPlaylist(named name: String, songs: [Song] = []) -> LibraryPlaylist {
        let playlist = LibraryPlaylist(name: name.isEmpty ? "New playlist" : name, songs: songs)
        playlists.insert(playlist, at: 0)
        scheduleSave()
        return playlist
    }

    func deletePlaylist(_ playlist: LibraryPlaylist) {
        playlists.removeAll { $0.id == playlist.id }
        scheduleSave()
    }

    func add(_ song: Song, to playlist: LibraryPlaylist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        guard !playlists[index].songs.contains(where: { $0.id == song.id }) else { return }
        playlists[index].songs.append(song)
        scheduleSave()
    }

    func remove(_ song: Song, from playlist: LibraryPlaylist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].songs.removeAll { $0.id == song.id }
        scheduleSave()
    }

    func rename(_ playlist: LibraryPlaylist, to name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].name = name
        scheduleSave()
    }

    // MARK: History

    func recordPlay(_ song: Song) {
        history.removeAll { $0.song.id == song.id }
        history.insert(HistoryEntry(song: song, playedAt: Date()), at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        scheduleSave()
    }

    var recentlyPlayed: [Song] {
        var seen = Set<String>()
        return history.compactMap { entry in
            guard seen.insert(entry.song.id).inserted else { return nil }
            return entry.song
        }
    }

    func clearHistory() {
        history.removeAll()
        scheduleSave()
    }

    // MARK: Search history

    func rememberSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1 else { return }
        recentSearches.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        recentSearches.insert(trimmed, at: 0)
        if recentSearches.count > 12 { recentSearches.removeLast(recentSearches.count - 12) }
        scheduleSave()
    }

    func clearSearches() {
        recentSearches.removeAll()
        scheduleSave()
    }

    // MARK: Local files

    func addLocalFolder(_ url: URL) {
        guard url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }
        if !localFolders.contains(url.path) {
            localFolders.append(url.path)
            scheduleSave()
        }
        Task { await scanLocalFolders() }
    }

    func removeLocalFolder(_ path: String) {
        localFolders.removeAll { $0 == path }
        scheduleSave()
        Task { await scanLocalFolders() }
    }

    /// Walks every watched folder and reads the tags of the audio files in it.
    func scanLocalFolders() async {
        let folders = localFolders
        guard !folders.isEmpty else {
            localSongs = []
            return
        }
        isScanning = true
        var found: [Song] = []
        let extensions: Set<String> = ["m4a", "mp3", "flac", "wav", "aiff", "aif", "aac", "mp4", "m4b"]
        for folder in folders {
            let base = URL(fileURLWithPath: folder)
            guard let enumerator = FileManager.default.enumerator(
                at: base,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let fileURL as URL in enumerator {
                guard extensions.contains(fileURL.pathExtension.lowercased()) else { continue }
                if let song = await Self.song(from: fileURL) {
                    found.append(song)
                }
            }
        }
        found.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        localSongs = found
        isScanning = false
    }

    private static func song(from url: URL) async -> Song? {
        let asset = AVURLAsset(url: url)
        var title = url.deletingPathExtension().lastPathComponent
        var artist = ""
        var album = ""
        do {
            let metadata = try await asset.load(.commonMetadata)
            for item in metadata {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:
                    if let value = try? await item.load(.stringValue), !value.isEmpty { title = value }
                case .commonKeyArtist:
                    if let value = try? await item.load(.stringValue), !value.isEmpty { artist = value }
                case .commonKeyAlbumName:
                    if let value = try? await item.load(.stringValue), !value.isEmpty { album = value }
                default:
                    break
                }
            }
        } catch {
            // Untagged files still play; the filename is the title.
        }
        var duration: TimeInterval?
        if let cmDuration = try? await asset.load(.duration) {
            let seconds = cmDuration.seconds
            if seconds.isFinite, seconds > 0 { duration = seconds }
        }
        return Song(
            videoId: url.absoluteString,
            title: title,
            artist: artist.isEmpty ? "Local file" : artist,
            album: album.isEmpty ? nil : album,
            duration: duration,
            thumbnailURL: nil,
            localURL: url.absoluteString
        )
    }

    func addLocalFiles(_ urls: [URL]) {
        Task {
            for url in urls where url.pathExtension.lowercased() != "" {
                if let song = await Self.song(from: url) {
                    if !localSongs.contains(where: { $0.localURL == song.localURL }) {
                        localSongs.append(song)
                    }
                }
            }
            localSongs.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    #if SNAPSHOT
    /// Snapshot-harness only.
    func previewSeed() {
        favourites = SnapshotFixtures.songs
        playlists = [
            LibraryPlaylist(name: "Late night drives", songs: Array(SnapshotFixtures.songs.prefix(6))),
            LibraryPlaylist(name: "Sunday morning", songs: Array(SnapshotFixtures.songs.prefix(3))),
        ]
        history = SnapshotFixtures.songs.map { HistoryEntry(song: $0, playedAt: Date()) }
        recentSearches = ["daft punk", "discovery", "random access memories"]
        localSongs = []
    }
    #endif

    // MARK: Backup import

    func importSearchHistory(_ titles: [String]) {
        for title in titles.reversed() {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > 1 else { continue }
            recentSearches.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
            recentSearches.insert(trimmed, at: 0)
        }
        if recentSearches.count > 16 { recentSearches.removeLast(recentSearches.count - 16) }
        saveNow()
    }

    /// Takes the months the backup carried and rebuilds the play history from
    /// them, so "Tocadas recentemente" shows the same listening the phone had.
    func importListening(_ months: [ListeningMonth]) {
        listeningMonths = months.sorted { $0.month > $1.month }

        var entries: [HistoryEntry] = []
        for month in months {
            for track in month.tracks {
                let song = Song(
                    videoId: track.id,
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    duration: track.ms > 0 ? track.ms / 1000 : nil,
                    thumbnailURL: track.art
                )
                let date = track.last > 0
                    ? Date(timeIntervalSince1970: track.last / 1000)
                    : Self.monthStart(month.month)
                entries.append(HistoryEntry(song: song, playedAt: date))
            }
        }
        entries.sort { $0.playedAt > $1.playedAt }

        // Keep any history the user already had behind the imported one,
        // without duplicating the same track.
        let importedIDs = Set(entries.map(\.song.id))
        let existing = history.filter { !importedIDs.contains($0.song.id) }
        history = Array((entries + existing).prefix(300))
        saveNow()
    }

    private static func monthStart(_ month: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.timeZone = .current
        return formatter.date(from: month) ?? Date()
    }

    // MARK: Archive recommendations

    /// Everything the imported archive says about the listener, flattened
    /// across its months — the source of the Home shelves that don't need the
    /// network.
    struct ArchiveTaste {
        var tracks: [ListeningTrack]
        var artists: [ListeningArtist]
        var albums: [ListeningArtist]
    }

    var archiveTaste: ArchiveTaste? {
        guard !listeningMonths.isEmpty else { return nil }

        var tracksByID: [String: ListeningTrack] = [:]
        var artistsByID: [String: ListeningArtist] = [:]
        var albumsByID: [String: ListeningArtist] = [:]

        for month in listeningMonths {
            for track in month.tracks {
                if var existing = tracksByID[track.id] {
                    existing.ms += track.ms
                    existing.plays += track.plays
                    existing.last = max(existing.last, track.last)
                    tracksByID[track.id] = existing
                } else {
                    tracksByID[track.id] = track
                }
            }
            for artist in month.artists {
                let key = artist.id ?? artist.name.lowercased()
                if var existing = artistsByID[key] {
                    existing.ms += artist.ms
                    artistsByID[key] = existing
                } else {
                    artistsByID[key] = artist
                }
            }
            for album in month.albums {
                let key = album.id ?? album.name.lowercased()
                if var existing = albumsByID[key] {
                    existing.ms += album.ms
                    albumsByID[key] = existing
                } else {
                    albumsByID[key] = album
                }
            }
        }

        // The same recording can appear under several video ids (album cut,
        // single, remaster). Keep the best-played copy of each title+artist so
        // a shelf doesn't show "Blue Moon" three times.
        var bestByTitle: [String: ListeningTrack] = [:]
        for track in tracksByID.values {
            let key = CanvasService.normalize(track.title) + "|" + CanvasService.normalize(track.artist)
            if let existing = bestByTitle[key] {
                if track.plays > existing.plays || (track.plays == existing.plays && track.ms > existing.ms) {
                    bestByTitle[key] = track
                }
            } else {
                bestByTitle[key] = track
            }
        }
        let tracks = bestByTitle.values.sorted { lhs, rhs in
            lhs.plays == rhs.plays ? lhs.ms > rhs.ms : lhs.plays > rhs.plays
        }
        let artists = artistsByID.values.sorted { $0.ms > $1.ms }
        let albums = albumsByID.values.sorted { $0.ms > $1.ms }
        guard !tracks.isEmpty else { return nil }
        return ArchiveTaste(tracks: tracks, artists: artists, albums: albums)
    }

    // MARK: Shelf helpers

    /// The five most recent playlists, as shelf cards.
    var playlistShelf: [ShelfItem] {
        playlists.map { playlist in
            ShelfItem(
                title: playlist.name,
                subtitle: playlist.songs.isEmpty ? "Empty" : "\(playlist.songs.count) songs",
                thumbnailURL: playlist.songs.first?.thumbnailURL,
                videoId: nil,
                browseId: "local:" + playlist.id.uuidString,
                playlistId: nil,
                duration: nil,
                pageKind: .playlist
            )
        }
    }
}
