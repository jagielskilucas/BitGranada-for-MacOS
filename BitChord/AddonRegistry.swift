//
//  AddonRegistry.swift
//  BitChord for macOS
//
//  The enabled addon sources, and the one call playback makes: "give me the
//  best stream you have for this track".
//

import Foundation

@MainActor
final class AddonRegistry: ObservableObject {
    static let shared = AddonRegistry()

    @Published private(set) var sources: [AddonSource] = []
    @Published private(set) var lastLabel: String?
    @Published private(set) var lastError: String?

    private var loadedKey: String = ""

    /// Rebuilds the source list from the stored URLs, loading each manifest.
    func load(urls: [String]) async {
        let key = urls.joined(separator: "|")
        guard key != loadedKey else { return }
        loadedKey = key
        sources = urls.compactMap { URL(string: $0) }.map(AddonSource.init(url:))
        for source in sources {
            await source.loadManifest()
        }
        print("addons: \(sources.map { "\($0.name) — \($0.status)" }.joined(separator: ", "))")
    }

    /// The best stream any enabled source offers for `song`, or nil so playback
    /// falls back to YouTube.
    func resolve(_ song: Song) async -> StreamInfo? {
        lastError = nil
        let query = Self.searchQuery(for: song)
        // Quality order: Qobuz's FLAC first, JioSaavn next, anything else after.
        // The list is stable, so the rest keeps the user's ordering.
        let ranked = sources.enumerated().sorted { lhs, rhs in
            Self.rank(lhs.element.name) < Self.rank(rhs.element.name)
        }.map(\.element)
        for source in ranked {
            let tracks = await source.search(query)
            print("addon: \(source.name) search → \(tracks.count) results for \(song.title)")
            guard !tracks.isEmpty else { continue }
            guard let match = AddonSource.bestMatch(for: song, in: tracks) else {
                print("addon: no match (first: \(tracks.first?.title ?? "-") / \(tracks.first?.artist ?? "-"))")
                continue
            }
            guard let stream = await source.stream(for: match),
                  let urlString = stream.url, let url = URL(string: urlString) else { continue }

            let mime = stream.mimeType ?? Self.mime(for: stream)
            // AVPlayer handles FLAC and MP3 over HTTP; anything it can't is
            // left for the next source rather than failing the track.
            guard mime.contains("flac") || mime.contains("mpeg") || mime.contains("mp4") || mime.contains("aac") else {
                continue
            }
            lastLabel = "\(stream.label.isEmpty ? "Alta" : stream.label) · \(source.name)"
            print("addon: \(source.name) → \(mime) \(stream.label)")
            return StreamInfo(
                url: url,
                mimeType: mime,
                bitrate: Int((stream.bitrate ?? 0) / 1000),
                itag: 9000,
                duration: match.duration,
                label: "\(stream.label.isEmpty ? "Alta" : stream.label) · \(source.name)",
                sourceName: source.name
            )
        }
        return nil
    }

    /// Lower runs first. 0 = Qobuz, 1 = JioSaavn, 2 = everything else.
    private static func rank(_ name: String) -> Int {
        let lower = name.lowercased()
        if lower.contains("qobuz") { return 0 }
        if lower.contains("saavn") || lower.contains("jio") { return 1 }
        return 2
    }

    /// Addon search is a plain text match, so the video-era title with its
    /// brackets ("(Official Video)", "[Instrumental Version]") only hides the
    /// track. Strip the qualifiers and the featured artists before asking.
    static func searchQuery(for song: Song) -> String {
        var title = song.title
        for pattern in [#"\s*[\(\[].*?[\)\]]"#, #"\s+-\s+(official|clipe|video|videoclipe).*$"#] {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                title = regex.stringByReplacingMatches(
                    in: title, range: NSRange(title.startIndex..., in: title), withTemplate: ""
                )
            }
        }
        var artist = song.artist
        for separator in [",", " feat.", " ft.", " &", " featuring"] {
            if let range = artist.range(of: separator, options: .caseInsensitive) {
                artist = String(artist[..<range.lowerBound])
            }
        }
        return "\(title.trimmingCharacters(in: .whitespaces)) \(artist.trimmingCharacters(in: .whitespaces))"
    }

    private static func mime(for stream: AddonStream) -> String {
        switch (stream.container ?? stream.format ?? "").lowercased() {
        case "flac": return "audio/flac"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac", "mp4": return "audio/mp4"
        default: return "audio/flac"
        }
    }
}
