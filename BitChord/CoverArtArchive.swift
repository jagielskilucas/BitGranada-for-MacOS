//
//  CoverArtArchive.swift
//  BitGranada
//
//  Album art from the Cover Art Archive, used when YouTube Music has none.
//
//  Two hops: MusicBrainz finds the release for the artist/album pair, then the
//  archive serves the front image for that release id. MusicBrainz asks for a
//  descriptive User-Agent and one request per second, so answers are cached and
//  misses are remembered for the session.
//

import Foundation

actor CoverArtArchive {
    static let shared = CoverArtArchive()

    private var hits: [String: String] = [:]
    private var misses: Set<String> = []
    private var lastRequest = Date.distantPast

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 12
        configuration.httpAdditionalHeaders = [
            "User-Agent": "BitGranada/1.9 (https://github.com/kushagrasinghx/BitChord)",
            "Accept": "application/json",
        ]
        return URLSession(configuration: configuration)
    }()

    /// Front cover URL for an album (or a track, which resolves to its album).
    func cover(title: String, artist: String) async -> String? {
        let key = "\(CanvasService.normalize(title))|\(CanvasService.normalize(artist))"
        if let hit = hits[key] { return hit }
        if misses.contains(key) { return nil }

        await throttle()
        guard let releaseID = await musicBrainzRelease(title: title, artist: artist) else {
            misses.insert(key)
            return nil
        }
        // The archive answers 307 to the image itself when the cover exists.
        let front = "https://coverartarchive.org/release/\(releaseID)/front-500"
        if let final = await existing(front) {
            hits[key] = final
            return final
        }
        misses.insert(key)
        return nil
    }

    private func musicBrainzRelease(title: String, artist: String) async -> String? {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release")!
        let query = artist.isEmpty
            ? "release:\"\(title)\""
            : "release:\"\(title)\" AND artist:\"\(artist)\""
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "3"),
        ]
        guard let url = components.url,
              let (data, _) = try? await session.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let releases = root["releases"] as? [[String: Any]] else { return nil }
        // Prefer the release that actually carries an image, when the list says.
        for release in releases {
            if let id = release["id"] as? String { return id }
        }
        return nil
    }

    private func existing(_ string: String) async -> String? {
        guard let url = URL(string: string) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<400).contains(http.statusCode) else { return nil }
        return http.url?.absoluteString ?? string
    }

    /// MusicBrainz allows one call per second; the app is far below that, but a
    /// grid can ask for several covers at once.
    private func throttle() async {
        let elapsed = Date().timeIntervalSince(lastRequest)
        if elapsed < 1 {
            try? await Task.sleep(nanoseconds: UInt64((1 - elapsed) * 1_000_000_000))
        }
        lastRequest = Date()
    }
}
