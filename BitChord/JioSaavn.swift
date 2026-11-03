//
//  JioSaavn.swift
//  BitGranada
//
//  JioSaavn as the second audio source: after the Qobuz addon, before YouTube.
//
//  Uses the site's own web API: `search.getResults` finds the song, and
//  `song.generateAuthToken` answers with a signed `auth_url` that AVPlayer can
//  play directly — no decryption step needed, unlike the older v4 flow.
//

import Foundation

actor JioSaavn {
    static let shared = JioSaavn()

    private let endpoint = "https://www.jiosaavn.com/api.php"
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    private var cache: [String: (url: URL, label: String, at: Date)] = [:]
    private var misses: [String: Date] = [:]
    private let ttl: TimeInterval = 60 * 60

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 12
        return URLSession(configuration: configuration)
    }()

    struct Hit {
        var url: URL
        var mimeType: String
        var label: String
        var duration: TimeInterval?
    }

    /// The best JioSaavn stream for a track, or nil so playback falls through.
    func stream(title: String, artist: String, expectedDuration: TimeInterval?) async -> Hit? {
        let key = "\(title)|\(artist)".lowercased()
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < ttl {
            return Hit(url: hit.url, mimeType: "audio/mp4", label: hit.label, duration: nil)
        }
        if let missedAt = misses[key], Date().timeIntervalSince(missedAt) < 300 { return nil }

        let found = await search(title: title, artist: artist, expected: expectedDuration)
        if found == nil { print("jiosaavn: sem match para \(title)") }
        guard let match = found else { misses[key] = Date(); return nil }
        let signed = await authURL(encrypted: match.encrypted)
        if signed == nil { print("jiosaavn: sem auth_url para \(title)") }
        guard let url = signed else { misses[key] = Date(); return nil }
        let label = "JioSaavn · \(match.bitrate) kbps"
        cache[key] = (url, label, Date())
        return Hit(url: url, mimeType: "audio/mp4", label: label, duration: match.duration)
    }

    // MARK: Search

    private struct Match {
        var encrypted: String
        var bitrate: Int
        var duration: TimeInterval?
    }

    private func search(title: String, artist: String, expected: TimeInterval?) async -> Match? {
        let query = artist.isEmpty ? title : "\(title) \(artist)"
        guard let json = await get([
            "__call": "search.getResults",
            "q": query,
            "n": "6",
            "_format": "json",
            "_marker": "0",
            "api_version": "4",
            "ctx": "web6dot0",
        ]) else { return nil }

        let results = (json["results"] as? [[String: Any]]) ?? []
        let wantTitle = Self.normalize(title)
        let wantArtist = Self.normalize(artist)

        // Prefer a result whose title matches; otherwise take the first that has
        // a media url at all — the search is already ranked by relevance.
        var fallback: Match?
        for item in results {
            guard let name = item["title"] as? String,
                  let more = item["more_info"] as? [String: Any],
                  let encrypted = more["encrypted_media_url"] as? String,
                  !encrypted.isEmpty else { continue }
            let bitrate = (more["320kbps"] as? String) == "true" ? 320 : 128
            let seconds = Double((item["duration"] as? String) ?? "")
            let candidate = Match(encrypted: encrypted, bitrate: bitrate, duration: seconds)
            if fallback == nil { fallback = candidate }
            let normalized = Self.normalize(name)
            if normalized.contains(wantTitle) || wantTitle.contains(normalized) {
                return candidate
            }
        }
        return fallback
    }

    // MARK: Signed URL

    private func authURL(encrypted: String) async -> URL? {
        // The value is percent-encoded by hand: it contains `+` and `/`, and an
        // unencoded `+` reaches the server as a space — which is why every
        // token request came back without an `auth_url`.
        guard let encoded = encrypted.addingPercentEncoding(
                withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
              ),
              let json = await get([
                "__call": "song.generateAuthToken",
                "url": encoded,
                "bitrate": "320",
                "api_version": "4",
                "ctx": "web6dot0",
                "_format": "json",
              ]),
              let raw = json["auth_url"] as? String,
              let url = URL(string: raw) else { return nil }
        return url
    }

    // MARK: Plumbing

    private func get(_ items: [String: String]) async -> [String: Any]? {
        var components = URLComponents(string: endpoint)!
        components.percentEncodedQuery = items
            .map { key, value in
                // `url` is already encoded; everything else is plain.
                let encoded = key == "url"
                    ? value
                    : (value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)
                return "\(key)=\(encoded)"
            }
            .joined(separator: "&")
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request) else {
            print("jiosaavn: sem resposta de \(items["__call"] ?? "?")")
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if json == nil { print("jiosaavn: \(items["__call"] ?? "?") http=\(status) corpo=\(String(data: data.prefix(80), encoding: .utf8) ?? "")") }
        return json
    }

    /// Loose comparison helper: lower case, no accents, no punctuation.
    static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let kept = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
        return String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
    }
}
