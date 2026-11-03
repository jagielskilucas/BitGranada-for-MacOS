//
//  Models.swift
//  BitChord for macOS
//
//  The shapes the phone's shared module and InnertubeParser produce, reduced to
//  what a desktop client needs.
//

import Foundation

// MARK: - Songs and releases

struct Song: Identifiable, Hashable, Codable {
    /// YouTube video id — the identity of a track everywhere in BitChord.
    var videoId: String
    var title: String
    var artist: String
    var album: String?
    var duration: TimeInterval?
    var thumbnailURL: String?
    /// Set when the row was played out of a mix/radio, so the queue can continue
    /// through YouTube Music's own "up next" list.
    var playlistId: String?
    /// Local files carry the URL they came from and no video id of their own.
    var localURL: String?
    var isVideo: Bool = false

    var id: String { localURL ?? videoId }

    static func == (lhs: Song, rhs: Song) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var durationText: String {
        guard let duration else { return "" }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Artwork at a size that suits the surface asking for it.
    func artwork(_ pixels: Int) -> URL? {
        if let localURL, let url = URL(string: localURL) { return url }
        return ArtworkURL.resized(thumbnailURL, pixels)
    }
}

struct Album: Identifiable, Hashable {
    var browseId: String
    var title: String
    var artist: String
    var year: String?
    var thumbnailURL: String?
    var songCount: Int?

    var id: String { browseId }

    func artwork(_ pixels: Int) -> URL? {
        ArtworkURL.resized(thumbnailURL, pixels)
    }
}

struct Artist: Identifiable, Hashable {
    var browseId: String
    var name: String
    var thumbnailURL: String?
    var subscribers: String?

    var id: String { browseId }

    func artwork(_ pixels: Int) -> URL? {
        ArtworkURL.resized(thumbnailURL, pixels)
    }
}

/// A release: a playlist, an album, or a mix. The screen that shows it is
/// `DetailView`, chosen by `kind`.
struct Release: Identifiable, Hashable {
    enum Kind: String, Codable {
        case album, playlist, artist, mix
    }

    var browseId: String
    var kind: Kind
    var title: String
    var subtitle: String
    var description: String?
    var thumbnailURL: String?
    var year: String?
    var songCount: Int?
    /// The wide header image an artist page carries (`musicImmersiveHeaderRenderer`).
    var bannerURL: String?
    var songs: [Song] = []
    /// The artist page's carousels (albums, singles, featured playlists).
    var shelves: [Shelf] = []

    var id: String { browseId }

    func artwork(_ pixels: Int) -> URL? {
        ArtworkURL.resized(thumbnailURL, pixels)
    }
}

/// Rewrites the `=w…-h…` suffix YouTube puts on a thumbnail so the same cover
/// can be fetched at the size the surface actually draws it — the same thing
/// the phone's artwork loader does.
enum ArtworkURL {
    /// Covers top out at 1080 px: beyond that the extra bytes buy nothing on a
    /// Retina cover and just cost memory and bandwidth.
    static let maximumCoverPixels = 1080

    static func resized(_ thumbnailURL: String?, _ pixels: Int) -> URL? {
        guard var string = thumbnailURL else { return nil }
        let pixels = min(pixels, maximumCoverPixels)
        if let range = string.range(of: "=w", options: .backwards) {
            string = String(string[..<range.lowerBound])
        }
        string += "=w\(pixels)-h\(pixels)-l90-rj"
        return URL(string: string)
    }
}

// MARK: - Shelves

/// One horizontally-scrolling row on Home, Explore or a release page.
struct Shelf: Identifiable, Hashable {
    var id: String { title }
    var title: String
    var items: [ShelfItem]
    /// Browse id behind the header's "Show all", when the shelf has one.
    var moreBrowseId: String?
}

/// A card in a shelf: either a playable song or something that opens a page.
struct ShelfItem: Identifiable, Hashable {
    /// What to ask the Cover Art Archive for when there is no thumbnail: an
    /// album name when the card is an album, the track title otherwise.
    var albumTitle: String { pageKind == .album ? title : title }
    var albumArtist: String { subtitle.components(separatedBy: " • ").last ?? subtitle }

    var id: String { videoId ?? browseId ?? title + subtitle }
    var title: String
    var subtitle: String
    var thumbnailURL: String?
    var videoId: String?
    var browseId: String?
    var playlistId: String?
    var duration: TimeInterval?
    var pageKind: Release.Kind?
    /// A music video rather than a track: drawn 16:9, with its view count.
    var isVideo: Bool = false

    var song: Song? {
        guard let videoId else { return nil }
        let split = SubtitleSplit.artistAndAlbum(subtitle)
        return Song(
            videoId: videoId,
            title: title,
            artist: split.artist,
            album: split.album,
            duration: duration,
            thumbnailURL: thumbnailURL,
            playlistId: playlistId
        )
    }

    func artwork(_ pixels: Int) -> URL? {
        ArtworkURL.resized(thumbnailURL, pixels)
    }
}

/// A search result row that is a track, ready to be queued.
struct SearchRow: Identifiable, Hashable {
    enum Kind: String {
        case song, album, artist, playlist, video, library
    }

    var id: String { videoId ?? browseId ?? title }
    var kind: Kind
    var title: String
    var subtitle: String
    var thumbnailURL: String?
    var videoId: String?
    var browseId: String?
    var playlistId: String?
    var duration: TimeInterval?

    var song: Song? {
        guard let videoId else { return nil }
        let split = SubtitleSplit.artistAndAlbum(subtitle)
        return Song(
            videoId: videoId,
            title: title,
            artist: split.artist,
            album: split.album,
            duration: duration,
            thumbnailURL: thumbnailURL,
            playlistId: playlistId
        )
    }

    func artwork(_ pixels: Int) -> URL? {
        ArtworkURL.resized(thumbnailURL, pixels)
    }
}

// MARK: - Lyrics

struct LyricWord: Hashable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

struct LyricLine: Identifiable, Hashable {
    var id: Int { index }
    var index: Int
    var start: TimeInterval
    var text: String
    /// Word (or syllable) timings, when the provider sent them — this is what
    /// drives the karaoke sweep.
    var words: [LyricWord]?
    /// Seconds the line is held, when the provider says.
    var duration: TimeInterval?

    static func == (lhs: LyricLine, rhs: LyricLine) -> Bool {
        lhs.index == rhs.index && lhs.start == rhs.start && lhs.text == rhs.text
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(index)
        hasher.combine(start)
    }

    /// How much of the line has been sung at `time`, 0…1 — the clip fraction
    /// the karaoke layer uses when word timings exist.
    func revealedFraction(at time: TimeInterval) -> Double {
        guard let words, !words.isEmpty else { return 0 }
        let total = text.count
        guard total > 0 else { return 0 }
        var revealed = 0
        for word in words {
            if time >= word.end {
                revealed += word.text.count
            } else if time > word.start {
                let progress = (time - word.start) / max(0.001, word.end - word.start)
                revealed += Int(Double(word.text.count) * progress)
                break
            } else {
                break
            }
        }
        return min(1, max(0, Double(revealed) / Double(total)))
    }
}

struct Lyrics: Hashable {
    var lines: [LyricLine]
    var plain: String?
    var synced: Bool
    var source: String
    var instrumental: Bool = false
    var wordSynced: Bool = false

    static let empty = Lyrics(lines: [], plain: nil, synced: false, source: "")

    var isEmpty: Bool { lines.isEmpty && (plain?.isEmpty ?? true) }

    /// Lines with consecutive instrumental gaps collapsed to one, which is what
    /// the panels draw: a provider that marks every beat with an empty line
    /// would otherwise fill the column with "♪".
    var displayLines: [LyricLine] {
        var out: [LyricLine] = []
        var previousEmpty = false
        for line in lines {
            let isEmpty = line.text.trimmingCharacters(in: .whitespaces).isEmpty
            if isEmpty && previousEmpty { continue }
            out.append(line)
            previousEmpty = isEmpty
        }
        return out
    }

    /// Index of the line that should be lit at `time`.
    func activeIndex(at time: TimeInterval) -> Int? {
        guard synced, !lines.isEmpty else { return nil }
        var low = 0
        var high = lines.count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].start <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}

// MARK: - Home feed

struct HomeFeed {
    var shelves: [Shelf] = []
    var greeting: String = "Listen now"
}

// MARK: - Playback state

enum RepeatMode: String, Codable, CaseIterable {
    case off, all, one

    var symbol: String {
        switch self {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    var label: String {
        switch self {
        case .off: return "Repeat off"
        case .all: return "Repeat all"
        case .one: return "Repeat one"
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Helpers

enum SubtitleSplit {
    /// "Daft Punk, Pharrell Williams • Random Access Memories" → artist and
    /// album. InnerTube hands rows one subtitle string; the player and the
    /// lyrics lookup want the artist on its own.
    static func artistAndAlbum(_ subtitle: String) -> (artist: String, album: String?) {
        let parts = subtitle.components(separatedBy: " • ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = parts.first else { return ("", nil) }
        let album = parts.dropFirst().first { part in
            !(part.count == 4 && Int(part) != nil)
                && !part.lowercased().contains("plays")
                && !part.lowercased().contains("views")
        }
        return (first, album)
    }
}

enum TimeFormat {
    static func playback(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Parses the "3:44" / "1:02:13" durations InnerTube puts in a subtitle.
    static func parseDuration(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, parts.count <= 3 else { return nil }
        var total: Double = 0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }
}
