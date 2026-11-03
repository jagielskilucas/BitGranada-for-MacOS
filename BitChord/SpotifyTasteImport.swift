//
//  SpotifyTasteImport.swift
//  BitGranada
//
//  Taste from a file, with no session and no token: the CSV that Exportify
//  writes, Spotify's own "Download your data" JSON, or a plain list of
//  "artist - title" lines. This is the path that cannot be blocked.
//

import Foundation

enum SpotifyTasteImport {
    enum Failure: LocalizedError {
        case unreadable, unrecognised, empty

        var errorDescription: String? {
            switch self {
            case .unreadable: return "Não consegui ler o arquivo."
            case .unrecognised: return "Formato não reconhecido (use CSV do Exportify ou o JSON do Spotify)."
            case .empty: return "O arquivo não tinha artistas nem faixas."
            }
        }
    }

    /// One playlist per file, keeping its name — what a folder of Exportify
    /// exports actually is.
    struct Playlist: Codable, Hashable, Identifiable {
        var name: String
        var tracks: [SpotifyTaste.Track]
        var id: String { name }
    }

    static func loadPlaylists(from urls: [URL]) -> [Playlist] {
        var out: [Playlist] = []
        for url in urls {
            guard let taste = try? load(from: url), !taste.tracks.isEmpty else { continue }
            let name = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: " ")
            out.append(Playlist(name: name, tracks: taste.tracks))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Reads whatever Spotify shape the file is in.
    static func load(from url: URL) throws -> SpotifyTaste {
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable }
        let name = url.pathExtension.lowercased()

        var tracks: [SpotifyTaste.Track] = []
        if name == "json" || (try? JSONSerialization.jsonObject(with: data)) != nil {
            tracks = jsonTracks(data)
        }
        if tracks.isEmpty, let text = String(data: data, encoding: .utf8) {
            tracks = csvTracks(text, header: csvHeader(text))
        }
        guard !tracks.isEmpty else { throw Failure.empty }

        // Exportify separates multiple artists with "," or ";" — keep the first
        // of either, so "A;B" does not become an artist called "A;B".
        tracks = tracks.map { track in
            var copy = track
            copy.artist = track.artist
                .components(separatedBy: CharacterSet(charactersIn: ",;"))
                .first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return copy
        }

        // A track in several playlists counts several times, which is exactly
        // the weighting "most listened" wants.
        var weight: [SpotifyTaste.Track: Int] = [:]
        for track in tracks { weight[track, default: 0] += 1 }
        let ranked = weight.sorted { $0.value > $1.value }.map(\.key)

        var counts: [String: Int] = [:]
        for track in ranked where !track.artist.isEmpty {
            counts[track.artist, default: 0] += 1
        }
        let artists = counts.sorted { $0.value > $1.value }.map(\.key)
        return SpotifyTaste(artists: Array(artists.prefix(40)),
                            tracks: Array(ranked.prefix(200)),
                            updatedAt: Date())
    }

    // MARK: JSON (Spotify "Download your data")

    private static func jsonTracks(_ data: Data) -> [SpotifyTaste.Track] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var out: [SpotifyTaste.Track] = []

        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                let title = dict["trackName"] as? String ?? dict["name"] as? String
                let artist = (dict["artistName"] as? String)
                    ?? (dict["artists"] as? [[String: Any]])?.first?["name"] as? String
                if let title, let artist {
                    out.append(SpotifyTaste.Track(title: title, artist: artist))
                }
                for value in dict.values { walk(value) }
            } else if let array = node as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(root)
        return out
    }

    // MARK: CSV (Exportify)

    private static func csvHeader(_ text: String) -> [String] {
        guard let first = text.split(separator: "\n").first else { return [] }
        return parseRow(String(first)).map { $0.lowercased() }
    }

    private static func csvTracks(_ text: String, header: [String]) -> [SpotifyTaste.Track] {
        let titleIndex = header.firstIndex { $0.contains("track name") || $0 == "title" || $0 == "name" }
        let artistIndex = header.firstIndex { $0.contains("artist") }

        var out: [SpotifyTaste.Track] = []
        for line in text.split(separator: "\n").dropFirst() {
            let row = parseRow(String(line))
            guard !row.isEmpty else { continue }
            let title: String?
            let artist: String?
            if let titleIndex, let artistIndex,
               row.indices.contains(titleIndex), row.indices.contains(artistIndex) {
                title = row[titleIndex]
                // "Artist 1, Artist 2" — the first is the one that matters.
                artist = row[artistIndex].components(separatedBy: ",").first
            } else {
                // No header: assume "Title, Artist" or "Artist - Title".
                let pieces = row.first?.components(separatedBy: " - ")
                title = pieces?.count == 2 ? pieces?[1] : row.first
                artist = pieces?.count == 2 ? pieces?[0] : (row.count > 1 ? row[1] : nil)
            }
            if let title, !title.isEmpty {
                out.append(SpotifyTaste.Track(title: title, artist: artist?
                    .trimmingCharacters(in: .whitespaces) ?? ""))
            }
        }
        return out
    }

    /// Handles the quoted fields Exportify writes ("Track, with comma").
    private static func parseRow(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        for character in line {
            switch character {
            case "\"":
                quoted.toggle()
            case "," where !quoted:
                fields.append(current)
                current = ""
            case "\r":
                continue
            default:
                current.append(character)
            }
        }
        fields.append(current)
        return fields.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
