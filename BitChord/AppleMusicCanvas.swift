//
//  AppleMusicCanvas.swift
//  BitChord for macOS
//
//  Apple Music's motion artwork — the animated sleeve the web player plays
//  behind a release. It is the fallback the Android build uses when a track
//  has no Spotify canvas: the token is the read-only one the web player mints
//  for anonymous visitors, scraped the same way.
//
//  Android counterpart: data/canvas/AppleMusicCanvas.kt.
//

import Foundation

actor AppleMusicCanvasService {
    static let shared = AppleMusicCanvasService()

    private let session: URLSession
    private var token: String?
    private var tokenExpiresAt = Date.distantPast
    private var tokenRetryAfter = Date.distantPast
    private var misses: Set<String> = []
    private var hits: [String: CanvasClip] = [:]

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    var storefront: String {
        let region = Locale.current.region?.identifier.lowercased() ?? "us"
        return region.count == 2 ? region : "us"
    }

    func clip(for song: Song) async -> CanvasClip? {
        let key = "\(song.title)|\(song.artist)"
        if let hit = hits[key] { return hit }
        if misses.contains(key) { return nil }

        guard let token = await accessToken() else {
            misses.insert(key)
            return nil
        }
        guard let url = await motionArtwork(for: song, token: token) else {
            misses.insert(key)
            return nil
        }
        let clip = CanvasClip(url: url, song: song.title, artist: song.artist, album: song.album)
        hits[key] = clip
        return clip
    }

    // MARK: Search

    private func motionArtwork(for song: Song, token: String) async -> URL? {
        let term = "\(song.title) \(CanvasService.normalize(song.artist))"
        var components = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "types", value: "albums"),
            URLQueryItem(name: "limit", value: "8"),
            URLQueryItem(name: "extend", value: "editorialVideo"),
        ]
        guard let data = await get(components.url!, token: token),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [String: Any],
              let albums = results["albums"] as? [String: Any],
              let items = albums["data"] as? [[String: Any]] else { return nil }

        let wantTitle = CanvasService.normalize(song.title)
        let wantArtist = CanvasService.normalize(song.artist)
        let wantAlbum = song.album.map(CanvasService.normalize)

        // Rank: the album that matches the track's own album first, then any
        // album by the artist that actually carries motion artwork.
        var best: (score: Int, url: URL)?
        for item in items {
            guard let attributes = item["attributes"] as? [String: Any],
                  let name = attributes["name"] as? String else { continue }
            let artistName = attributes["artistName"] as? String ?? ""
            let normalizedName = CanvasService.normalize(name)
            let normalizedArtist = CanvasService.normalize(artistName)

            var score = 0
            if let wantAlbum, normalizedName == wantAlbum { score += 6 }
            if normalizedName.contains(wantTitle) || wantTitle.contains(normalizedName) { score += 2 }
            if normalizedArtist.contains(wantArtist) || wantArtist.contains(normalizedArtist) { score += 3 }
            guard score > 0 else { continue }
            guard let video = attributes["editorialVideo"] as? [String: Any],
                  let url = Self.motionURL(video) else { continue }
            if best == nil || score > best!.score { best = (score, url) }
        }
        return best?.url
    }

    /// Motion artwork lives under a few keys depending on the release; square
    /// first, tall second.
    private static func motionURL(_ video: [String: Any]) -> URL? {
        let keys = ["motionDetailSquare", "motionSquareVideo1x1", "motionDetailTall", "motionDetailRaw"]
        for key in keys {
            guard let asset = video[key] as? [String: Any] else { continue }
            for field in ["video", "videoUrl", "hlsUrl", "url"] {
                if let value = asset[field] as? String, let url = URL(string: value) { return url }
            }
        }
        return nil
    }

    private func get(_ url: URL, token: String) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    // MARK: Token

    private func accessToken() async -> String? {
        if let token, Date() < tokenExpiresAt.addingTimeInterval(-120) { return token }
        if Date() < tokenRetryAfter { return nil }

        guard let browse = URL(string: "https://music.apple.com/\(storefront)/browse") else { return nil }
        var request = URLRequest(url: browse)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let html = String(data: data, encoding: .utf8),
              let finalURL = response.url else {
            tokenRetryAfter = Date().addingTimeInterval(60)
            return nil
        }
        _ = finalURL

        // The web player's own bundles carry the anonymous token.
        let scriptPattern = try? NSRegularExpression(pattern: #"/assets/index[~-][A-Za-z0-9_-]+\.js"#)
        let range = NSRange(html.startIndex..., in: html)
        let scripts = scriptPattern?.matches(in: html, range: range).compactMap { match -> String? in
            guard let r = Range(match.range, in: html) else { return nil }
            return String(html[r])
        } ?? []

        let jwtPattern = try? NSRegularExpression(pattern: #"ey[A-Za-z0-9_-]+\.ey[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#)
        for path in Set(scripts).prefix(6) {
            guard let url = URL(string: "https://music.apple.com\(path)") else { continue }
            var scriptRequest = URLRequest(url: url)
            scriptRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            guard let (scriptData, _) = try? await session.data(for: scriptRequest),
                  let script = String(data: scriptData, encoding: .utf8) else { continue }

            let scriptRange = NSRange(script.startIndex..., in: script)
            let candidates = jwtPattern?.matches(in: script, range: scriptRange).compactMap { match -> (String, Date)? in
                guard let r = Range(match.range, in: script) else { return nil }
                let jwt = String(script[r])
                guard let expiry = Self.expiry(of: jwt), expiry > Date() else { return nil }
                return (jwt, expiry)
            } ?? []
            guard !candidates.isEmpty else { continue }

            // The web player's token is the one issued to its own "kid".
            let chosen = candidates.first { Self.isWebPlayerToken($0.0) } ?? candidates[0]
            token = chosen.0
            tokenExpiresAt = chosen.1
            return chosen.0
        }

        tokenRetryAfter = Date().addingTimeInterval(120)
        return nil
    }

    private static func isWebPlayerToken(_ jwt: String) -> Bool {
        let parts = jwt.split(separator: ".")
        guard let header = parts.first else { return false }
        var base64 = String(header).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.lowercased().contains("webplaykid")
    }

    private static func expiry(of jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (object["exp"] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
