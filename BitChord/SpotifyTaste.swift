//
//  SpotifyTaste.swift
//  BitGranada
//
//  The listener's taste as Spotify knows it: the artists and tracks it ranks
//  highest. Read with the same session the canvas uses — no separate login.
//

import Foundation

struct SpotifyTaste: Codable {
    var artists: [String]
    var tracks: [Track]
    var updatedAt: Date

    struct Track: Codable, Hashable {
        var title: String
        var artist: String
    }

    var isEmpty: Bool { artists.isEmpty && tracks.isEmpty }
}

@MainActor
final class SpotifyTasteService {
    static let shared = SpotifyTasteService()

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    enum Failure: LocalizedError {
        case noSession, refused(Int), empty

        var errorDescription: String? {
            switch self {
            case .noSession: return "Cole o cookie sp_dc do Spotify nos Ajustes."
            case .refused(let status): return "O Spotify recusou a leitura (\(status))."
            case .empty: return "O Spotify não devolveu artistas nem faixas."
            }
        }
    }

    /// Fetches both lists. Throws with a readable reason so the settings row can
    /// say what happened instead of silently doing nothing.
    func load() async throws -> SpotifyTaste {
        // Three routes, best first: a PKCE session (user-top-read), then the web
        // player API with its own token, then reading the rendered home page.
        // A token pasted by hand wins, so a fresh one can be tested without
        // touching the cookie flow.
        var token = UserDefaults.standard.string(forKey: "spotify.manualToken")
        if token?.isEmpty == true { token = nil }
        if token == nil { token = await SpotifyOAuth.shared.accessToken() }
        if token == nil { token = await SpotifyTokenProvider.shared.accessToken() }

        if token == nil, let cookie = SpotifySecrets.cookie,
           let scraped = await SpotifyWebTaste.shared.load(cookie: cookie) {
            Self.persist(scraped)
            return scraped
        }
        guard var token else { throw Failure.noSession }

        var artists: [String] = []
        var tracks: [SpotifyTaste.Track] = []

        for range in ["long_term", "medium_term"] {
            // Errors are surfaced, not swallowed: a 403 here means the token
            // lacks the scope, and the settings row has to say so.
            let artistsPage: [String: Any]?
            do {
                artistsPage = try await get("/v1/me/top/artists",
                                            query: ["time_range": range, "limit": "50"],
                                            token: token)
            } catch Failure.refused(401) {
                // The web player's bearer only lasts an hour: mint a new one and
                // try this range again before giving up.
                guard let fresh = await SpotifyTokenProvider.shared.accessToken(forceRefresh: true)
                else { throw Failure.refused(401) }
                token = fresh
                artistsPage = try? await get("/v1/me/top/artists",
                                             query: ["time_range": range, "limit": "50"],
                                             token: fresh)
            } catch let failure as Failure {
                throw failure
            } catch {
                artistsPage = nil
            }
            if let page = artistsPage,
               let items = page["items"] as? [[String: Any]] {
                for item in items {
                    if let name = item["name"] as? String, !artists.contains(name) {
                        artists.append(name)
                    }
                }
            }
            if let page = try? await get("/v1/me/top/tracks",
                                        query: ["time_range": range, "limit": "50"],
                                        token: token),
               let items = page["items"] as? [[String: Any]] {
                for item in items {
                    guard let name = item["name"] as? String,
                          let performers = item["artists"] as? [[String: Any]],
                          let first = performers.first?["name"] as? String else { continue }
                    let entry = SpotifyTaste.Track(title: name, artist: first)
                    if !tracks.contains(entry) { tracks.append(entry) }
                }
            }
            if !artists.isEmpty || !tracks.isEmpty { break }
        }

        if artists.isEmpty, tracks.isEmpty, let cookie = SpotifySecrets.cookie,
           let scraped = await SpotifyWebTaste.shared.load(cookie: cookie) {
            // The API refused or returned nothing: fall back to what the web
            // player is showing for this session.
            Self.persist(scraped)
            return scraped
        }
        guard !artists.isEmpty || !tracks.isEmpty else { throw Failure.empty }
        let taste = SpotifyTaste(artists: Array(artists.prefix(40)),
                                 tracks: Array(tracks.prefix(60)),
                                 updatedAt: Date())
        Self.persist(taste)
        return taste
    }

    /// What is actually happening, for the settings row: which token exists and
    /// what each endpoint answered.
    func diagnose() async -> String {
        var lines: [String] = []
        let manual = UserDefaults.standard.string(forKey: "spotify.manualToken") ?? ""
        lines.append(manual.isEmpty ? "token manual: vazio" : "token manual: \(manual.prefix(8))…")

        let minted = await SpotifyTokenProvider.shared.accessToken()
        lines.append("token do cookie: " + (minted.map { "\($0.prefix(8))…" } ?? "nenhum (sp_dc ausente?)"))

        let token = manual.isEmpty ? minted : manual
        guard let token else { return lines.joined(separator: "\n") }

        lines.append("GET /v1/me → \(await status("/v1/me", token: token))")
        lines.append("GET /v1/me/top/artists → \(await status("/v1/me/top/artists?limit=1", token: token))")
        if let cookie = SpotifySecrets.cookie, let scraped = await SpotifyWebTaste.shared.load(cookie: cookie) {
            lines.append("home do web player: \(scraped.artists.count) artistas, \(scraped.tracks.count) faixas")
        } else {
            lines.append("home do web player: nada lido")
        }
        return lines.joined(separator: "\n")
    }

    private func status(_ path: String, token: String) async -> Int {
        var request = URLRequest(url: URL(string: "https://api.spotify.com" + path)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return -1 }
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    /// Cached copy, so the app can use it before a network round trip.
    static func cached() -> SpotifyTaste? {
        guard let data = UserDefaults.standard.data(forKey: "spotify.taste"),
              let taste = try? JSONDecoder().decode(SpotifyTaste.self, from: data) else { return nil }
        return taste
    }

    private static func persist(_ taste: SpotifyTaste) {
        guard let data = try? JSONEncoder().encode(taste) else { return }
        UserDefaults.standard.set(data, forKey: "spotify.taste")
    }

    private func get(_ path: String, query: [String: String], token: String) async throws -> [String: Any]? {
        var components = URLComponents(string: "https://api.spotify.com" + path)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.refused(status) }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
