//
//  LastFM.swift
//  BitGranada
//
//  Last.fm's similarity graph, used to seed recommendations — the same idea the
//  phone uses in the "based on what you listen to" rows.
//
//  Only two endpoints matter here: artist.getSimilar and track.getSimilar. Both
//  answer with a ranked list of names, which we then resolve on YouTube Music.
//

import Foundation

actor LastFM {
    static let shared = LastFM()

    enum Failure: LocalizedError {
        case noKey, refused(String), empty

        var errorDescription: String? {
            switch self {
            case .noKey: return "Informe a API key do Last.fm nos Ajustes."
            case .refused(let reason): return "Last.fm recusou: \(reason)"
            case .empty: return "O Last.fm não sugeriu nada para essa faixa."
            }
        }
    }

    struct Suggestion: Hashable {
        var name: String
        var match: Double
    }

    private var cache: [String: (items: [Suggestion], at: Date)] = [:]
    private let ttl: TimeInterval = 30 * 60

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 12
        return URLSession(configuration: configuration)
    }()

    /// Similar artists, strongest first.
    func similarArtists(to artist: String, limit: Int = 12) async throws -> [Suggestion] {
        try await request(method: "artist.getsimilar",
                          params: ["artist": artist, "limit": String(limit)],
                          key: "artist|\(artist)", arrayKey: "similarartists")
    }

    /// Similar tracks, which is what the phone's recommendation rows lean on.
    func similarTracks(title: String, artist: String, limit: Int = 20) async throws -> [Suggestion] {
        try await request(method: "track.getsimilar",
                          params: ["track": title, "artist": artist, "limit": String(limit)],
                          key: "track|\(title)|\(artist)", arrayKey: nil)
    }

    /// Global stats for one track: how many people listen, how often it is
    /// played, and the tags other listeners filed it under.
    struct TrackInfo {
        var listeners: Int
        var playcount: Int
        var tags: [String]
        var album: String?
        var summary: String?
        var url: URL?
    }

    func trackInfo(title: String, artist: String) async throws -> TrackInfo {
        guard let apiKey = LastFMKey.value else { throw Failure.noKey }
        var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        components.queryItems = [
            URLQueryItem(name: "method", value: "track.getinfo"),
            URLQueryItem(name: "track", value: title),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "autocorrect", value: "1"),
        ]
        guard let url = components.url,
              let (data, _) = try? await session.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.refused("sem resposta")
        }
        if let message = root["message"] as? String { throw Failure.refused(message) }
        guard let track = root["track"] as? [String: Any] else { throw Failure.empty }

        let tags = ((track["toptags"] as? [String: Any])?["tag"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }
        return TrackInfo(
            listeners: Int(track["listeners"] as? String ?? "") ?? 0,
            playcount: Int(track["playcount"] as? String ?? "") ?? 0,
            tags: tags,
            album: (track["album"] as? [String: Any])?["title"] as? String,
            summary: ((track["wiki"] as? [String: Any])?["summary"] as? String),
            url: (track["url"] as? String).flatMap(URL.init(string:))
        )
    }

    /// The listener's own listening history, read from the public profile.
    struct Scrobble: Hashable { var title: String; var artist: String; var album: String? }

    func recentTracks(user: String, limit: Int = 20) async throws -> [Scrobble] {
        try await userList(method: "user.getrecenttracks", user: user, limit: limit, key: "recent")
    }

    func topTracks(user: String, limit: Int = 20) async throws -> [Scrobble] {
        try await userList(method: "user.gettoptracks", user: user, limit: limit, key: "tracks")
    }

    func topArtists(user: String, limit: Int = 12) async throws -> [Suggestion] {
        guard let apiKey = LastFMKey.value else { throw Failure.noKey }
        let items = try await userRaw(method: "user.gettopartists", user: user, limit: limit,
                                      apiKey: apiKey, wrapper: "topartists", item: "artist")
        return items.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            return Suggestion(name: name, match: Double(item["playcount"] as? String ?? "") ?? 0)
        }
    }

    func topAlbums(user: String, limit: Int = 12) async throws -> [(album: String, artist: String)] {
        guard let apiKey = LastFMKey.value else { throw Failure.noKey }
        let items = try await userRaw(method: "user.gettopalbums", user: user, limit: limit,
                                      apiKey: apiKey, wrapper: "topalbums", item: "album")
        return items.compactMap { item in
            guard let name = item["name"] as? String,
                  let artist = (item["artist"] as? [String: Any])?["name"] as? String else { return nil }
            return (name, artist)
        }
    }

    private func userList(method: String, user: String, limit: Int, key: String) async throws -> [Scrobble] {
        guard let apiKey = LastFMKey.value else { throw Failure.noKey }
        let wrapper = key == "recent" ? "recenttracks" : "toptracks"
        let items = try await userRaw(method: method, user: user, limit: limit,
                                      apiKey: apiKey, wrapper: wrapper, item: "track")
        return items.compactMap { item in
            // Recent scrobbles carry the artist as an object with `#text`; the
            // top lists use `name`. Accept both, or the recent row is empty.
            let artistObject = item["artist"] as? [String: Any]
            let artist = (artistObject?["name"] as? String)
                ?? (artistObject?["#text"] as? String)
                ?? (item["artist"] as? String)
            guard let title = item["name"] as? String, let artist, !artist.isEmpty else { return nil }
            let album = (item["album"] as? [String: Any])?["#text"] as? String
            return Scrobble(title: title, artist: artist,
                            album: (album?.isEmpty == false) ? album : nil)
        }
    }

    private func userRaw(method: String, user: String, limit: Int,
                         apiKey: String, wrapper: String, item: String) async throws -> [[String: Any]] {
        var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        components.queryItems = [
            URLQueryItem(name: "method", value: method),
            URLQueryItem(name: "user", value: user),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components.url,
              let (data, _) = try? await session.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.refused("sem resposta")
        }
        if let message = root["message"] as? String { throw Failure.refused(message) }
        guard let wrapperObject = root[wrapper] as? [String: Any] else { throw Failure.empty }
        return wrapperObject[item] as? [[String: Any]] ?? []
    }

    private func request(method: String, params: [String: String],
                         key: String, arrayKey: String?) async throws -> [Suggestion] {
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < ttl { return hit.items }
        guard let apiKey = LastFMKey.value else { throw Failure.noKey }

        var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "method", value: method),
               URLQueryItem(name: "api_key", value: apiKey),
               URLQueryItem(name: "format", value: "json"),
               URLQueryItem(name: "autocorrect", value: "1")]

        guard let url = components.url else { throw Failure.refused("URL inválida") }
        guard let (data, _) = try? await session.data(from: url) else {
            throw Failure.refused("sem resposta")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.refused("resposta inesperada")
        }
        if let message = root["message"] as? String {
            throw Failure.refused(message)
        }

        let items: [[String: Any]]
        if let arrayKey, let wrapper = root[arrayKey] as? [String: Any] {
            items = wrapper["artist"] as? [[String: Any]] ?? []
        } else if let wrapper = root["similartracks"] as? [String: Any] {
            items = wrapper["track"] as? [[String: Any]] ?? []
        } else {
            items = []
        }

        let parsed: [Suggestion] = items.compactMap { item in
            let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ((item["artist"] as? [String: Any])?["name"] as? String)
            guard let name, !name.isEmpty else { return nil }
            let match = Double(item["match"] as? String ?? "") ?? 0
            return Suggestion(name: name, match: match)
        }
        // An empty result is a valid answer (the catalogue has no neighbours for
        // that seed), not an error: callers fall back to artists.
        guard !parsed.isEmpty else { return [] }
        cache[key] = (parsed, Date())
        return parsed
    }
}

/// The key the app reads the similarity graph with. A key is shipped so the row
/// works out of the box; Settings can override it with the listener's own.
/// Only read endpoints are used, so no shared secret is needed here.
enum LastFMKey {
    static let bundled = "22b78dbae00952eb2c8a4532fc2e80a7"

    static var value: String? {
        let key = UserDefaults.standard.string(forKey: "lastfm.apiKey")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !key.isEmpty { return key }
        return bundled.isEmpty ? nil : bundled
    }

    static var isConfigured: Bool { value != nil }
}
