//
//  AppleArtistLogo.swift
//  BitChord for macOS
//
//  Apple Music's artist wordmark — the handwritten-looking name Apple draws over
//  the hero photograph. Mirrors the 1.9 integration
//  (data/canvas/AppleArtistArt.kt): find the artist in the iTunes catalogue,
//  open their music.apple.com page, and read the `artistLogo` artwork out of the
//  page's `serialized-server-data`.
//

import AppKit
import Foundation

struct ArtistWordmark: Hashable {
    var url: URL
    var aspect: Double
    /// The looping HLS clip Apple uses instead of the photograph on some artist
    /// pages (`videoArtwork.motionArtistSquare1x1`).
    var videoURL: URL?
}

@MainActor
final class AppleArtistLogoService: ObservableObject {
    static let shared = AppleArtistLogoService()

    /// The logo and the motion clip travel together; either may be absent.
    struct Banner {
        var logo: ArtistWordmark?
        var videoURL: URL?
    }

    /// Cached with the time it was fetched, so a transient failure (Apple
    /// throttling, a slow page) is retried instead of remembered forever.
    private var cache: [String: (banner: Banner?, at: Date)] = [:]
    /// Failures are not remembered: entering the artist again retries at once,
    /// which is what the page needs when Apple throttles a burst of lookups.
    private let missLifetime: TimeInterval = 0
    private var running: Set<String> = []

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
        ]
        return URLSession(configuration: configuration)
    }()

    func cached(_ name: String) -> Banner? { cache[key(name)]?.banner }

    /// `titles` are the artist's own song/album names, used to reject a
    /// same-named artist Apple happens to rank higher.
    /// Runs the lookup detached from the view's lifecycle: SwiftUI cancels the
    /// `.task` as soon as the page scrolls or reloads, and a cancelled URLSession
    /// request was leaving every artist with no logo *and* no retry.
    func banner(for name: String, titles: [String]) async -> Banner? {
        let work = Task.detached(priority: .utility) { [weak self] in
            await self?.lookupBanner(for: name, titles: titles)
        }
        return await work.value
    }

    private func lookupBanner(for name: String, titles: [String]) async -> Banner? {
        let nameKey = key(name)
        if let entry = cache[nameKey] {
            if entry.banner != nil { return entry.banner }
            let age = Date().timeIntervalSince(entry.at)
            if age < missLifetime { return nil }
        }
        guard !running.contains(nameKey) else { return nil }
        running.insert(nameKey)
        defer { running.remove(nameKey) }

        var result: Banner?
        for artistId in await itunesArtistIds(named: name, titles: titles).prefix(3) {
            guard let page = URL(string: "https://music.apple.com/us/artist/\(artistId)") else { continue }
            if let banner = await banner(fromArtistPage: page), banner.logo != nil || banner.videoURL != nil {
                result = banner
                break
            }
        }
        if result != nil {
            cache[nameKey] = (result, Date())
        }
        print("artistArt: \(name) -> logo \(result?.logo != nil) video \(result?.videoURL != nil)")
        return result
    }

    private func key(_ name: String) -> String { name.lowercased().trimmingCharacters(in: .whitespaces) }

    /// Candidate artist ids, best first. Apple keeps a name change as two
    /// entries ("MARINA" and "Marina and The Diamonds"), and the page's tracks
    /// may all belong to the other one, so the title check ranks candidates
    /// instead of filtering them out.
    private func itunesArtistIds(named name: String, titles: [String]) async -> [Int] {
        guard var components = URLComponents(string: "https://itunes.apple.com/search") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "term", value: name),
            URLQueryItem(name: "entity", value: "musicArtist"),
            URLQueryItem(name: "limit", value: "6"),
        ]
        guard let url = components.url,
              let (data, _) = try? await session.data(from: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { return [] }

        let wanted = name.lowercased()
        var ranked: [(score: Int, id: Int)] = []
        for result in results {
            guard let name = (result["artistName"] as? String)?.lowercased(),
                  let id = result["artistId"] as? Int, id > 0 else { continue }
            var score = 0
            if name == wanted { score += 4 }
            else if name.contains(wanted) || wanted.contains(name) { score += 1 }
            else { continue }
            if !titles.isEmpty, await sharesTitles(artistId: id, titles: titles) { score += 3 }
            ranked.append((score, id))
        }
        return ranked.sorted { $0.score > $1.score }.map(\.id)
    }

    private func sharesTitles(artistId: Int, titles: [String]) async -> Bool {
        guard var components = URLComponents(string: "https://itunes.apple.com/lookup") else { return false }
        // Song titles, not album names: the caller passes the tracks on the
        // artist's page, and comparing those with `collectionName` never
        // matched — which silently sent every artist to the signature fallback.
        components.queryItems = [
            URLQueryItem(name: "id", value: String(artistId)),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "25"),
        ]
        guard let url = components.url,
              let (data, _) = try? await session.data(from: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { return false }
        let known = Set(titles.map { $0.lowercased() })
        return results.contains { result in
            if let track = (result["trackName"] as? String)?.lowercased(), known.contains(track) { return true }
            if let album = (result["collectionName"] as? String)?.lowercased(), known.contains(album) { return true }
            return false
        }
    }

    /// The artist's motion clip, when Apple offers one.
    private static func findMotionVideo(in json: Any) -> String? {
        if let dict = json as? [String: Any] {
            if let artwork = dict["videoArtwork"] as? [String: Any],
               let inner = artwork["dictionary"] as? [String: Any],
               let square = inner["motionArtistSquare1x1"] as? [String: Any],
               let video = square["video"] as? String, video.hasPrefix("http") {
                return video
            }
            for value in dict.values {
                if let found = findMotionVideo(in: value) { return found }
            }
        } else if let array = json as? [Any] {
            for value in array {
                if let found = findMotionVideo(in: value) { return found }
            }
        }
        return nil
    }

    private func banner(fromArtistPage page: URL) async -> Banner? {
        guard let (data, _) = try? await session.data(from: page),
              let html = String(data: data, encoding: .utf8),
              let json = Self.serializedData(from: html) else { return nil }
        let motion = Self.findMotionVideo(in: json).flatMap(URL.init(string:))
        guard let logo = Self.findLogo(in: json) else {
            // No wordmark, but the page may still carry a looping clip.
            return motion.map { Banner(logo: nil, videoURL: $0) }
        }

        let width = 1000.0
        let logoWidth = (logo["width"] as? NSNumber)?.doubleValue ?? 0
        let logoHeight = (logo["height"] as? NSNumber)?.doubleValue ?? 0
        guard let template = logo["url"] as? String, logoWidth > 0, logoHeight > 0 else { return nil }
        let height = (width * logoHeight / logoWidth).rounded()
        // Apple's template also carries {c} — the crop flag — which has to be
        // filled or the CDN answers 404 and the wordmark never loads.
        let filled = template
            .replacingOccurrences(of: "{w}", with: String(Int(width)))
            .replacingOccurrences(of: "{h}", with: String(Int(height)))
            .replacingOccurrences(of: "{c}", with: "bb")
            .replacingOccurrences(of: "{f}", with: "png")
        guard let url = URL(string: filled) else {
            return Banner(logo: nil, videoURL: motion)
        }
        return Banner(logo: ArtistWordmark(url: url, aspect: logoWidth / logoHeight),
                      videoURL: motion)
    }

    /// The page embeds its state in `<script id="serialized-server-data">`.
    private static func serializedData(from html: String) -> Any? {
        guard let marker = html.range(of: "id=\"serialized-server-data\"") else { return nil }
        guard let open = html[marker.upperBound...].firstIndex(of: ">"),
              let close = html[open...].range(of: "</script>") else { return nil }
        let body = html[html.index(after: open)..<close.lowerBound]
        return try? JSONSerialization.jsonObject(with: Data(body.utf8))
    }

    /// Depth-first search for the `artistLogo` dictionary, whose nested `url` is
    /// the wordmark template.
    private static func findLogo(in node: Any) -> [String: Any]? {
        if let dict = node as? [String: Any] {
            if let logo = dict["artistLogo"] as? [String: Any],
               let inner = logo["dictionary"] as? [String: Any],
               inner["url"] is String {
                return inner
            }
            for value in dict.values {
                if let found = findLogo(in: value) { return found }
            }
        } else if let array = node as? [Any] {
            for value in array {
                if let found = findLogo(in: value) { return found }
            }
        }
        return nil
    }
}
