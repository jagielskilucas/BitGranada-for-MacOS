//
//  InnerTube.swift
//  BitChord for macOS
//
//  The YouTube Music client. One HTTP surface — music.youtube.com/youtubei —
//  for search, browse and the up-next queue, plus the player endpoint on
//  www.youtube.com for the audio stream itself.
//
//  Android counterpart: data/remote/Innertube*.kt + data/innertube/.
//
//  Responses are parsed with a generic walker rather than Codable models: the
//  renderer tree is deep, optional at every level, and changes shape between
//  endpoints. The same `collect(renderer:)` call finds a list of shelves on
//  Home, on an album page and in a search result, which is exactly why the
//  phone's parser is written the same way.
//

import Foundation

// MARK: - JSON helpers

/// A thin wrapper so the parser can walk `Any` JSON without a dozen casts.
///
/// Subscripts are non-optional and yield `NSNull` when a key is missing, so a
/// path can be read in one expression (`item["overlay"]["…"]["videoId"].string`)
/// and every step degrades to "absent" rather than to a crash or a `?` ladder.
struct JSON {
    let value: Any

    init(_ value: Any) { self.value = value }

    subscript(_ key: String) -> JSON {
        guard let dict = value as? [String: Any], let child = dict[key] else { return JSON(NSNull()) }
        return JSON(child)
    }

    subscript(_ index: Int) -> JSON {
        guard let array = value as? [Any], array.indices.contains(index) else { return JSON(NSNull()) }
        return JSON(array[index])
    }

    var dict: [String: Any]? { value as? [String: Any] }
    var array: [Any]? { value as? [Any] }

    var string: String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    var int: Int? {
        if let i = value as? Int { return i }
        if let s = value as? String { return Int(s) }
        return nil
    }

    var double: Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    var exists: Bool { !(value is NSNull) }

    var nonEmptyString: String? {
        guard let s = string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// Every descendant value whose key is `renderer`, in document order.
    func collect(_ renderer: String) -> [JSON] {
        var out: [JSON] = []
        func walk(_ any: Any) {
            if let dict = any as? [String: Any] {
                // Standalone renderer nodes keep their order relative to the
                // rest only if the key is visited where it sits; a dictionary
                // has no order, so shelves are re-sorted by their own titles
                // where order matters (Home preserves order by walking arrays).
                for (key, child) in dict {
                    if key == renderer { out.append(JSON(child)) }
                    walk(child)
                }
            } else if let array = any as? [Any] {
                for child in array { walk(child) }
            }
        }
        walk(value)
        return out
    }

    /// Like `collect`, but preserves document order for the renderer keys that
    /// appear inside arrays (shelves, list items). Dictionary iteration order is
    /// not stable, so this walks arrays in order and objects by known keys.
    func collectOrdered(_ renderer: String) -> [JSON] {
        var out: [JSON] = []
        func walk(_ any: Any) {
            if let array = any as? [Any] {
                for child in array { walk(child) }
            } else if let dict = any as? [String: Any] {
                if let child = dict[renderer] { out.append(JSON(child)) }
                for (key, child) in dict.sorted(by: { $0.key < $1.key }) {
                    if key == renderer { continue }
                    walk(child)
                }
            }
        }
        walk(value)
        return out
    }

    /// The text of a `{ runs: [...] }` / `{ simpleText }` node.
    var text: String? {
        guard let dict = dict else { return nil }
        if let simple = dict["simpleText"] as? String { return simple }
        if let runs = dict["runs"] as? [Any] {
            let joined = runs.compactMap { run -> String? in
                (run as? [String: Any])?["text"] as? String
            }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    /// The clickable runs of a text node, in order.
    var runs: [(text: String, browseId: String?, pageType: String?, videoId: String?)] {
        guard let dict = dict, let runs = dict["runs"] as? [Any] else { return [] }
        return runs.compactMap { raw in
            guard let run = raw as? [String: Any], let text = run["text"] as? String else { return nil }
            let endpoint = run["navigationEndpoint"] as? [String: Any]
            let browse = endpoint?["browseEndpoint"] as? [String: Any]
            let watch = endpoint?["watchEndpoint"] as? [String: Any]
            let pageType = ((browse?["browseEndpointContextSupportedConfigs"] as? [String: Any])?["browseEndpointContextMusicConfig"] as? [String: Any])?["pageType"] as? String
            return (text, browse?["browseId"] as? String, pageType, watch?["videoId"] as? String)
        }
    }
}

// MARK: - Client

struct MoodCategory {
    var title: String
    var browseId: String
    var params: String
    var color: UInt32
}

struct StreamInfo {
    var url: URL
    var mimeType: String
    var bitrate: Int
    var itag: Int
    var duration: TimeInterval?
    /// Set when the stream came from an addon, for the quality line in the UI.
    var label: String? = nil
    /// Who is serving this stream — the addon's own name, or the service the
    /// fallback came from. Shown as "Tocando de" in the player.
    var sourceName: String? = nil
}

enum InnerTubeError: LocalizedError {
    case network(String)
    case decoding(String)
    case playback(String)
    case unsupportedCodec(String)

    var errorDescription: String? {
        switch self {
        case .network(let message): return message
        case .decoding(let message): return "Couldn't read YouTube's answer: \(message)"
        case .playback(let message): return message
        case .unsupportedCodec(let message): return message
        }
    }
}

/// The music client the phone speaks as. WEB_REMIX is the YouTube Music web
/// client, and it answers search/browse without an account.
enum MusicClient {
    static let name = "WEB_REMIX"
    static let version = "1.20241001.01.00"
}

/// The player client. VISIONOS is the one YouTube still hands un-ciphered
/// stream URLs to without a PoToken; the phone uses its own Android hooks
/// here, which a desktop has no equivalent of.
enum StreamClient {
    static let name = "VISIONOS"
    static let version = "1.02.03"
    static let userAgent = "com.apple.CoreMedia"
    static let headerClientName = "28"

    struct VideoClient {
        var body: [String: Any]
        var fields: [String: Any]
        var headerName: String
        var userAgent: String
    }

    /// Fallbacks for the picture, in order of reliability for music videos.
    static var videoClients: [VideoClient] {
        let hl = Locale.current.language.languageCode?.identifier ?? "en"
        let gl = Locale.current.region?.identifier ?? "US"
        return [
            VideoClient(body: [:], fields: [
                "clientName": "VISIONOS", "clientVersion": "1.02.03",
                "deviceMake": "Apple", "deviceModel": "RealityDevice14,1",
                "osName": "visionOS", "osVersion": "1.3.0.21O209", "hl": hl, "gl": gl,
            ], headerName: "28", userAgent: "com.apple.CoreMedia"),
            VideoClient(body: [:], fields: [
                "clientName": "ANDROID", "clientVersion": "19.44.38",
                "androidSdkVersion": 34, "osName": "Android", "osVersion": "14",
                "hl": hl, "gl": gl,
            ], headerName: "3", userAgent: "com.google.android.youtube/19.44.38 (Linux; U; Android 14) gzip"),
            // Music videos (OMV) are only served to the music clients; the
            // generic ones answer 400 for them.
            VideoClient(body: ["isAudioOnly": false], fields: [
                "clientName": "WEB_REMIX", "clientVersion": "1.20241010.01.00",
                "hl": hl, "gl": gl,
            ], headerName: "67", userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"),
            VideoClient(body: ["isAudioOnly": false, "params": "8AEB"], fields: [
                "clientName": "WEB", "clientVersion": "2.20241010.00.00",
                "hl": hl, "gl": gl,
            ], headerName: "1", userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"),
        ]
    }
}

actor InnerTubeClient {
    static let shared = InnerTubeClient()

    private var officialIDCache: [String: (id: String?, at: Date)] = [:]
    private var videoStreamCache: [String: (url: URL, height: Int, at: Date)] = [:]
    private let streamTTL: TimeInterval = 60 * 60 * 2

    private let session: URLSession
    private var visitorData: String?
    private var lastStreamClientError: String?

    private static let musicBase = "https://music.youtube.com/youtubei/v1/"
    private static let playerURL = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 60
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        session = URLSession(configuration: config)
        visitorData = UserDefaults.standard.string(forKey: "bitchord.visitorData")
    }

    // MARK: Session bootstrap

    private func rememberVisitor(_ json: JSON) {
        if let visitor = json["responseContext"]["visitorData"].nonEmptyString {
            if visitor != visitorData {
                visitorData = visitor
                UserDefaults.standard.set(visitor, forKey: "bitchord.visitorData")
            }
        }
    }

    private func body(_ extra: [String: Any]) -> [String: Any] {
        var client: [String: Any] = [
            "clientName": MusicClient.name,
            "clientVersion": MusicClient.version,
            "hl": Locale.current.language.languageCode?.identifier ?? "en",
            "gl": Locale.current.region?.identifier ?? "US",
            "osName": "macOS",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "platform": "DESKTOP",
        ]
        if let visitorData { client["visitorData"] = visitorData }
        var payload: [String: Any] = [
            "context": ["client": client],
            "user": ["lockedSafetyMode": false],
        ]
        for (key, value) in extra { payload[key] = value }
        return payload
    }

    private func post(endpoint: String, body: [String: Any], toPlayer: Bool = false,
                      toWeb: Bool = false,
                      client: StreamClient.VideoClient? = nil) async throws -> JSON {
        let url: URL
        if toPlayer {
            url = Self.playerURL
        } else if toWeb {
            url = URL(string: "https://www.youtube.com/youtubei/v1/" + endpoint + "?prettyPrint=false")!
        } else {
            url = URL(string: Self.musicBase + endpoint + "?prettyPrint=false")!
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let origin = toWeb ? "https://www.youtube.com" : "https://music.youtube.com"
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(origin + "/", forHTTPHeaderField: "Referer")
        request.setValue(
            client?.userAgent ?? (toPlayer
                ? StreamClient.userAgent
                : "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"),
            forHTTPHeaderField: "User-Agent"
        )
        if let visitorData {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        // No Authorization header here: an invalid SAPISIDHASH made every call
        // answer 401 — including the clip search, which is what broke the video
        // for signed-out-of-Google sessions. Personalisation comes from the
        // cookie-driven web view instead (YouTubeWebHighlights).
        if toPlayer {
            request.setValue(client?.headerName ?? StreamClient.headerClientName,
                             forHTTPHeaderField: "X-Youtube-Client-Name")
            request.setValue(StreamClient.version, forHTTPHeaderField: "X-Youtube-Client-Version")
        } else if toWeb {
            // www.youtube.com speaks as the web client; sending the music client
            // id there made the search answer with the wrong shape (no video
            // rows), which is why clip lookup found nothing.
            request.setValue("1", forHTTPHeaderField: "X-Youtube-Client-Name")
            request.setValue("2.20241010.00.00", forHTTPHeaderField: "X-Youtube-Client-Version")
        } else {
            request.setValue("67", forHTTPHeaderField: "X-Youtube-Client-Name")
            request.setValue(MusicClient.version, forHTTPHeaderField: "X-Youtube-Client-Version")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw InnerTubeError.network("No response from YouTube Music.")
        }
        guard http.statusCode == 200 else {
            if ProcessInfo.processInfo.environment["BITCHORD_PROBE_VIDEO"] != nil {
                let body = String(data: data.prefix(180), encoding: .utf8) ?? ""
                print("probe: HTTP \(http.statusCode) em \(endpoint) [\(client?.fields["clientName"] ?? "-")] \(body)")
            }
            throw InnerTubeError.network("YouTube Music answered \(http.statusCode).")
        }
        guard let any = try? JSONSerialization.jsonObject(with: data) else {
            throw InnerTubeError.decoding("response was not JSON")
        }
        let json = JSON(any)
        rememberVisitor(json)
        return json
    }

    // MARK: Home

    /// The Home feed: YouTube Music's own shelf list, exactly what the phone
    /// shows under "Listen now".
    func home() async throws -> [Shelf] {
        let json = try await post(endpoint: "browse", body: body(["browseId": "FEmusic_home"]))
        return Self.parseShelves(json)
    }

    /// The Explore tab's category tiles. The phone shows 28 moods and
    /// activities; YouTube returns them as navigation buttons with a coloured
    /// stripe, which is where the tile colour comes from.
    func moodCategories() async throws -> [MoodCategory] {
        let json = try await post(
            endpoint: "browse",
            body: body(["browseId": "FEmusic_moods_and_genres"])
        )
        var out: [MoodCategory] = []
        for button in json.collectOrdered("musicNavigationButtonRenderer") {
            guard let title = button["buttonText"].text, !title.isEmpty else { continue }
            let endpoint = button["clickCommand"]["browseEndpoint"]
            guard let browseId = endpoint["browseId"].nonEmptyString,
                  let params = endpoint["params"].nonEmptyString else { continue }
            var color: UInt32 = 0x3A3A3C
            if let raw = button["solid"]["leftStripeColor"].int {
                // The stripe is an ARGB int; keep the RGB part.
                let value = UInt32(truncatingIfNeeded: raw)
                color = value & 0xFFFFFF
            }
            out.append(MoodCategory(title: title, browseId: browseId, params: params, color: color))
        }
        return out
    }

    /// The artwork a mood page leads with: the first playlist card's cover.
    /// The navigation buttons that describe moods carry only a colour stripe, so
    /// the real cover has to come from the category page itself.
    func moodCover(browseId: String, params: String) async -> String? {
        guard let json = try? await post(
            endpoint: "browse",
            body: body(["browseId": browseId, "params": params])
        ) else { return nil }
        // The category page mixes renderers (cards, carousels, grids), so take
        // the first real thumbnail anywhere in the payload rather than guessing
        // which renderer this mood uses.
        for item in json.collectOrdered("musicThumbnailRenderer") {
            if let url = Self.bestThumbnail(item["thumbnail"]) { return url }
            if let url = Self.bestThumbnail(item) { return url }
        }
        return nil
    }

    /// The "new releases" and "mixed for you" pages, which the phone's home
    /// surfaces as their own rows.
    func highlights() async -> [Shelf] {
        var shelves: [Shelf] = []
        for (browseId, title) in [("FEmusic_new_releases_albums", "Lançamentos"),
                                  ("FEmusic_mixed_for_you", "Mixtapes para você")] {
            guard let page = try? await post(endpoint: "browse", body: body(["browseId": browseId]))
            else { continue }
            var items: [ShelfItem] = []
            for grid in page.collectOrdered("gridRenderer") {
                for raw in grid["items"].array ?? [] {
                    let node = JSON(raw)
                    let card = node["musicTwoRowItemRenderer"].exists
                        ? node["musicTwoRowItemRenderer"] : node
                    if let item = Self.parseTwoRow(card) { items.append(item) }
                }
            }
            if items.isEmpty { items = Self.parseShelves(page).flatMap(\.items) }
            if !items.isEmpty {
                shelves.append(Shelf(title: title, items: Array(items.prefix(20))))
            }
        }
        return shelves
    }

    /// A category page (a mood, a genre) as shelves.
    func browseShelves(browseId: String, params: String?) async throws -> [Shelf] {
        var extra: [String: Any] = ["browseId": browseId]
        if let params { extra["params"] = params }
        let json = try await post(endpoint: "browse", body: body(extra))
        return Self.parseShelves(json)
    }

    func moodsAndGenres() async throws -> [ShelfItem] {
        let json = try await post(
            endpoint: "browse",
            body: body(["browseId": "FEmusic_moods_and_genres"])
        )
        var items: [ShelfItem] = []
        for grid in json.collectOrdered("gridRenderer") {
            for raw in grid["items"].array ?? [] {
                let item = JSON(raw)
                if item["musicTwoRowItemRenderer"].exists,
                   let parsed = Self.parseTwoRow(item["musicTwoRowItemRenderer"]) {
                    items.append(parsed)
                }
            }
        }
        if items.isEmpty {
            for shelf in Self.parseShelves(json) { items.append(contentsOf: shelf.items) }
        }
        var seen = Set<String>()
        return items.filter { item in
            guard let key = item.browseId ?? item.videoId else { return true }
            return seen.insert(key).inserted
        }
    }

    // MARK: Search

    func search(_ query: String) async throws -> [SearchRow] {
        // params: songs + videos + albums + playlists + artists, the same
        // filter set the phone's search box uses.
        // No `params`: YouTube's filtered search drops artist and album rows
        // entirely, and this screen filters client-side. The unfiltered answer
        // carries songs, albums, artists and playlists together.
        let json = try await post(endpoint: "search", body: body(["query": query]))
        var rows: [SearchRow] = []
        // The top result is a card, not a list row — and it is usually the very
        // artist being searched for, which the list below only references.
        for raw in json.collectOrdered("musicCardShelfRenderer") {
            if let card = Self.parseTopResultCard(raw) { rows.append(card) }
        }
        for card in json.collectOrdered("musicCardShelfRenderer") {
            if let row = Self.parseCard(card) { rows.append(row) }
        }
        for item in json.collectOrdered("musicResponsiveListItemRenderer") {
            if let row = Self.parseResponsiveItem(item) { rows.append(row) }
        }
        var seen = Set<String>()
        return rows.filter { row in
            guard let key = row.videoId ?? row.browseId else { return true }
            return seen.insert(key).inserted
        }
    }

    /// The songs a search returns, with their video type — used to swap a
    /// music-video result for the YouTube Music track it came from.
    /// Album rows for a query, as shelf cards (browse id + cover).
    func searchAlbums(query: String, limit: Int = 3) async -> [ShelfItem] {
        guard let rows = try? await search(query) else { return [] }
        return rows.filter { $0.kind == .album }
            .prefix(limit)
            .map { row in
                ShelfItem(title: row.title, subtitle: row.subtitle,
                          thumbnailURL: row.thumbnailURL, videoId: nil,
                          browseId: row.browseId, playlistId: nil,
                          duration: nil, pageKind: .album)
            }
    }

    /// The official clip for a track, found through a plain YouTube search and
    /// scored on title, artist and length. Nil means the track has no clip.
    func officialVideoId(title: String, artist: String,
                         expectedDuration: TimeInterval? = nil) async -> String? {
        let idKey = "\(title.lowercased())|\(artist.lowercased())"
        if let hit = officialIDCache[idKey], Date().timeIntervalSince(hit.at) < streamTTL {
            return hit.id
        }
        let query = "\(artist) \(title) official video"
        let webClient: [String: Any] = [
            "clientName": "WEB", "clientVersion": "2.20241010.00.00",
            "hl": Locale.current.language.languageCode?.identifier ?? "en",
            "gl": Locale.current.region?.identifier ?? "US",
        ]
        let payload: [String: Any] = [
            "context": ["client": webClient],
            "query": query,
        ]
        guard let json = try? await post(endpoint: "search", body: payload,
                                         toWeb: true) else { return nil }
        let wantTitle = CanvasService.normalize(title)
        let wantArtist = CanvasService.normalize(artist)
        var best: (id: String, score: Int)?
        for video in json.collectOrdered("videoRenderer") {
            guard let id = video["videoId"].string else { continue }
            let candidates = [
                video["title"]["runs"].array?.first.map { JSON($0)["text"].string } ?? nil,
                video["title"]["simpleText"].string,
            ]
            let name = CanvasService.normalize(candidates.compactMap { $0 }.joined(separator: " "))
            guard !name.isEmpty else { continue }
            // Official channels only: a lyric video on a fan channel is not the
            // artist's clip, and the phone never shows it either.
            let channel = CanvasService.normalize(
                video["ownerText"]["runs"].array?.first.map { JSON($0)["text"].string ?? "" } ?? "")
            let badges = video.collectOrdered("ownerBadges")
                .flatMap { $0.collectOrdered("metadataBadgeRenderer") }
                .compactMap { JSON($0)["style"].string }
            let verifiedArtist = badges.contains { $0.contains("VERIFIED_ARTIST") || $0.contains("VERIFIED") }
            let channelIsArtist = !channel.isEmpty && (channel.contains(wantArtist) || wantArtist.contains(channel))
            guard channelIsArtist || verifiedArtist else { continue }

            var score = 0
            if name.contains(wantTitle) { score += 4 }
            if name.contains(wantArtist) { score += 3 }
            if channelIsArtist { score += 2 }
            if let length = video["lengthText"]["simpleText"].string,
               let seconds = Self.seconds(fromLength: length),
               let expected = expectedDuration, abs(seconds - expected) < 10 {
                score += 2
            }
            if score >= 6, score > (best?.score ?? 0) { best = (id, score) }
        }
        officialIDCache[idKey] = (best?.id, Date())
        return best?.id
    }

    /// A picture-only stream for the clip — muted by the caller.
    func videoStream(videoId: String, heightCap: Int = 720) async throws -> (url: URL, height: Int) {
        let key = "\(videoId)|\(heightCap)"
        if let hit = videoStreamCache[key], Date().timeIntervalSince(hit.at) < streamTTL,
           hit.height <= heightCap {
            return (hit.url, hit.height)
        }
        var lastReason = "Sem vídeo disponível para esta faixa."
        for client in StreamClient.videoClients {
            var payload = client.body
            payload["videoId"] = videoId
            payload["contentCheckOk"] = true
            payload["racyCheckOk"] = true
            payload["context"] = ["client": {
                var fields: [String: Any] = client.fields
                fields["visitorData"] = visitorData ?? ""
                return fields
            }()]
            guard let json = try? await post(endpoint: "player", body: payload, toPlayer: true,
                                             client: client) else { continue }
            if let status = json["playabilityStatus"]["status"].string, status != "OK" {
                lastReason = json["playabilityStatus"]["reason"].string ?? status
                continue
            }
            // HLS first: the adaptive renditions are DASH fragments that
            // AVFoundation opens as `.unknown` (measured), while the HLS variant
            // plays natively — it is the one source that works for the picture.
            if let hls = json["streamingData"]["hlsManifestUrl"].nonEmptyString,
               let url = URL(string: hls) {
                videoStreamCache[key] = (url, 720, Date())
                return (url, 720)
            }

            // The progressive (muxed) renditions first: they are single files
            // AVFoundation opens reliably, while the adaptive ones are DASH
            // fragments that can leave the item at `.unknown`.
            for raw in json["streamingData"]["formats"].array ?? [] {
                let format = JSON(raw)
                guard let url = format["url"].nonEmptyString else { continue }
                let mime = format["mimeType"].string ?? ""
                guard mime.hasPrefix("video/mp4"), mime.contains("avc1") else { continue }
                if let parsed = URL(string: url) {
                    videoStreamCache[key] = (parsed, format["height"].int ?? 360, Date())
                    return (parsed, format["height"].int ?? 360)
                }
            }

            // H.264 only: the adaptive list also offers AV1 and VP9, which
            // AVFoundation refuses on most Macs — the item would sit at
            // `.unknown` forever while the URL itself answers fine.
            var best: (height: Int, url: String)?
            var fallback: (height: Int, url: String)?
            for raw in json["streamingData"]["adaptiveFormats"].array ?? [] {
                let format = JSON(raw)
                guard let url = format["url"].nonEmptyString else { continue }
                let mime = format["mimeType"].string ?? ""
                guard mime.hasPrefix("video/mp4") else { continue }
                let height = format["height"].int ?? 0
                guard height <= heightCap else { continue }
                if mime.contains("avc1") {
                    if height > (best?.height ?? 0) { best = (height, url) }
                } else if height > (fallback?.height ?? 0) {
                    fallback = (height, url)
                }
            }
            if let pick = best ?? fallback, let url = URL(string: pick.url) {
                videoStreamCache[key] = (url, pick.height, Date())
                return (url, pick.height)
            }
        }
        throw InnerTubeError.playback(lastReason)
    }

    private static func seconds(fromLength text: String) -> TimeInterval? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return parts.count == 3
            ? TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
            : TimeInterval(parts[0] * 60 + parts[1])
    }

    func songCandidates(_ query: String, limit: Int = 8) async -> [Song] {
        guard let json = try? await post(endpoint: "search", body: body(["query": query])) else { return [] }
        var songs: [Song] = []
        for item in json.collectOrdered("musicResponsiveListItemRenderer") {
            if let song = Self.parseSongItem(item) { songs.append(song) }
            if songs.count >= limit { break }
        }
        return songs
    }


    /// Lowercased, accent-free, alphanumeric — "SAOKO (Official Video)" and
    /// "saoko" have to read as the same words.
    static func matchKey(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// "3:42" → 222 seconds.
    static func seconds(fromLength text: String?) -> TimeInterval? {
        guard let text, !text.isEmpty else { return nil }
        let parts = text.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return TimeInterval(parts[0] * 60 + parts[1])
        case 3: return TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
        default: return nil
        }
    }

    /// The Lyrics tab's text for a video: `next` finds the tab, `browse` opens
    /// it and the description shelf carries the lines.
    func musicLyrics(videoId: String) async -> [String]? {
        guard videoId.count >= 8,
              let next = try? await post(endpoint: "next",
                                         body: body(["videoId": videoId, "isAudioOnly": true]))
        else { return nil }

        var target: (browseId: String, params: String?)?
        for tab in next.collectOrdered("tabRenderer") {
            let title = tab["title"].text ?? ""
            let endpoint = tab["endpoint"]["browseEndpoint"]
            guard let browseId = endpoint["browseId"].nonEmptyString else { continue }
            let params = endpoint["params"].nonEmptyString
            let lowered = title.lowercased()
            if lowered.contains("lyric") || lowered.contains("letra") || lowered.contains("歌词") {
                target = (browseId, params)
                break
            }
            if target == nil { target = (browseId, params) }
        }
        guard let target else { return nil }

        var payload: [String: Any] = ["browseId": target.browseId]
        if let params = target.params { payload["params"] = params }
        guard let page = try? await post(endpoint: "browse", body: body(payload)) else { return nil }

        for shelf in page.collectOrdered("musicDescriptionShelfRenderer") {
            let text = shelf["description"].text ?? ""
            let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !lines.isEmpty { return lines }
        }
        return nil
    }

    /// The artist page's browse id for a name — what the player's artist line
    /// opens when tapped.
    func artistBrowseId(named name: String, matching trackTitle: String? = nil) async -> String? {
        let rows = (try? await search(name)) ?? []
        let artists = rows.filter { $0.kind == .artist && $0.browseId != nil }
        let wanted = Self.signatureKey(name)

        // Namesakes are common ("Dead Bad Bunny" next to "Bad Bunny"), and the
        // listener count cannot tell them apart. The page that actually holds
        // the track that is playing is the right artist.
        let ordered = artists.sorted { lhs, rhs in
            let leftExact = Self.signatureKey(lhs.title) == wanted ? 0 : 1
            let rightExact = Self.signatureKey(rhs.title) == wanted ? 0 : 1
            return leftExact < rightExact
        }.prefix(4)

        var fallback: (id: String, songs: Int)?
        for candidate in ordered {
            guard let id = candidate.browseId,
                  let page = try? await release(browseId: id, kindHint: .artist) else { continue }
            if let trackTitle, !trackTitle.isEmpty {
                let target = Self.signatureKey(trackTitle)
                if page.songs.contains(where: { Self.signatureKey($0.title) == target }) {
                    return id
                }
            }
            if page.songs.count > (fallback?.songs ?? -1) {
                fallback = (id, page.songs.count)
            }
        }
        return fallback?.id
    }

    /// Reads "8,83 mi ouvintes mensais" / "1.2M monthly listeners" as a number,
    /// so the most listened-to namesake wins.
    static func listeners(_ subtitle: String) -> Double {
        let lowered = subtitle.lowercased()
        var digits = ""
        var unit = ""
        var readingUnit = false
        for character in lowered {
            if character.isNumber {
                if readingUnit { break }
                digits.append(character)
            } else if character == "," || character == "." {
                if !digits.isEmpty && !readingUnit { digits.append(".") }
            } else if character.isLetter {
                readingUnit = true
                unit.append(character)
            } else if readingUnit {
                break
            }
        }
        guard let value = Double(digits) else { return 0 }
        if unit.hasPrefix("mi") || unit == "m" { return value * 1_000_000 }
        if unit.hasPrefix("mil") || unit == "k" { return value * 1_000 }
        return value
    }

    /// Lowercase, accent-free, punctuation-free: "ROSALÍA" == "Rosalia".
    static func signatureKey(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return folded.filter { $0.isLetter || $0.isNumber }
    }

    func suggestions(_ query: String) async throws -> [String] {
        let json = try await post(
            endpoint: "music/get_search_suggestions",
            body: body(["input": query])
        )
        var out: [String] = []
        for item in json.collectOrdered("searchSuggestionRenderer") {
            if let text = item["suggestion"].text { out.append(text) }
        }
        return out
    }

    // MARK: Releases

    /// An album, playlist or artist page.
    func release(browseId: String, kindHint: Release.Kind = .playlist) async throws -> Release {
        let json = try await post(endpoint: "browse", body: body(["browseId": browseId]))
        var release = Release(browseId: browseId, kind: kindHint, title: "", subtitle: "")

        if let immersive = json.collectOrdered("musicImmersiveHeaderRenderer").first {
            release.title = immersive["title"].text ?? ""
            // The caller decides the kind: a page that is an artist is opened
            // as one, and an album with a hero header keeps its own layout.
            release.subtitle = immersive["subscriptionButton"]["subscribeButtonRenderer"]["subscriberCountText"].text
                ?? immersive["subtitle"].text
                ?? ""
            release.bannerURL = Self.bestThumbnail(immersive["backgroundImage"])
                ?? Self.bestThumbnail(immersive["foregroundImage"])
            release.thumbnailURL = release.thumbnailURL ?? Self.bestThumbnail(immersive["thumbnail"])
        }

        let header = json.collectOrdered("musicDetailHeaderRenderer").first
            ?? json.collectOrdered("musicResponsiveHeaderRenderer").first
        if let header {
            release.title = header["title"].text ?? ""
            release.subtitle = header["subtitle"].text ?? ""
            release.description = header["description"].text
            release.thumbnailURL = Self.bestThumbnail(header["thumbnail"])
            if let second = header["secondSubtitle"].text {
                release.year = second
                release.songCount = Self.songCount(in: second)
            }
            let pageTypes = header.collectOrdered("browseEndpointContextMusicConfig")
                .compactMap { $0["pageType"].string }
            if pageTypes.contains("MUSIC_PAGE_TYPE_ARTIST") { release.kind = .artist }
        }

        var songs: [Song] = []
        for item in json.collectOrdered("musicResponsiveListItemRenderer") {
            if let song = Self.parseSongItem(item) { songs.append(song) }
        }
        if songs.isEmpty {
            for item in json.collectOrdered("musicShelfRenderer") {
                for raw in item["contents"].array ?? [] {
                    if let song = Self.parseSongItem(JSON(raw)["musicResponsiveListItemRenderer"]) {
                        songs.append(song)
                    }
                }
            }
        }
        release.songs = songs
        release.shelves = Self.parseCarousels(json)
        if release.title.isEmpty {
            release.title = json.collectOrdered("musicDetailHeaderRenderer").first?["title"].text
                ?? json.collectOrdered("musicResponsiveHeaderRenderer").first?["title"].text
                ?? "Untitled"
        }
        return release
    }

    /// The up-next queue for a track. `playlistId` is the mix the phone got from
    /// the row's play button (RDAMVM… for a radio, OLAK5uy… for an album).
    func upNext(videoId: String, playlistId: String?) async throws -> [Song] {
        var extra: [String: Any] = ["videoId": videoId, "isAudioOnly": true]
        extra["playlistId"] = Self.radioPlaylistId(videoId: videoId, playlistId: playlistId)
        let json = try await post(endpoint: "next", body: body(extra))
        var songs: [Song] = []
        for panel in json.collectOrdered("playlistPanelVideoRenderer") {
            guard let id = panel["videoId"].nonEmptyString else { continue }
            let title = panel["title"].text ?? ""
            let artist = panel["longBylineText"].text ?? panel["shortBylineText"].text ?? ""
            let duration = panel["lengthText"].text.flatMap(TimeFormat.parseDuration)
            songs.append(Song(
                videoId: id,
                title: title,
                artist: artist,
                duration: duration,
                thumbnailURL: Self.bestThumbnail(panel["thumbnail"]),
                playlistId: playlistId
            ))
        }
        return songs
    }

    /// The playlist id that makes `next` answer with a radio.
    ///
    /// YouTube's own client asks for `RDAMVM<videoId>` when a track is played
    /// on its own — that is the "mix" the phone shows in Up next. An album or
    /// playlist id (OLAK5uy…, VLPL…) is passed through untouched so playing
    /// from a release continues that release instead of a radio.
    static func radioPlaylistId(videoId: String, playlistId: String?) -> String {
        guard let playlistId, !playlistId.isEmpty else { return "RDAMVM" + videoId }
        if playlistId.hasPrefix("OLAK5uy") || playlistId.hasPrefix("VLPL") { return playlistId }
        return playlistId
    }

    // MARK: Stream

    /// Resolves a playable URL for `videoId`.
    ///
    /// AVFoundation can only demux MP4, so the audio/mp4 renditions (AAC) are
    /// the ones this build can use; the Opus-in-WebM renditions YouTube also
    /// offers are filtered out rather than handed to AVPlayer to fail on.
    func streamURL(videoId: String, highQuality: Bool = true) async throws -> StreamInfo {
        let payload: [String: Any] = [
            "context": ["client": [
                "clientName": StreamClient.name,
                "clientVersion": StreamClient.version,
                "deviceMake": "Apple",
                "deviceModel": "RealityDevice14,1",
                "osName": "visionOS",
                "osVersion": "1.3.0.21O209",
                "hl": Locale.current.language.languageCode?.identifier ?? "en",
                "gl": Locale.current.region?.identifier ?? "US",
                "visitorData": visitorData ?? "",
            ]],
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        let json = try await post(endpoint: "player", body: payload, toPlayer: true)

        if let status = json["playabilityStatus"]["status"].string, status != "OK" {
            let reason = json["playabilityStatus"]["reason"].string ?? status
            lastStreamClientError = reason
            throw InnerTubeError.playback(reason)
        }

        var formats: [(itag: Int, mime: String, bitrate: Int, url: String)] = []
        for raw in json["streamingData"]["adaptiveFormats"].array ?? [] {
            let f = JSON(raw)
            let mime = f["mimeType"].string ?? ""
            guard mime.hasPrefix("audio/"), let url = f["url"].nonEmptyString else { continue }
            formats.append((f["itag"].int ?? 0, mime, f["bitrate"].int ?? 0, url))
        }
        if formats.isEmpty {
            for raw in json["streamingData"]["formats"].array ?? [] {
                let f = JSON(raw)
                guard let url = f["url"].nonEmptyString else { continue }
                formats.append((f["itag"].int ?? 0, f["mimeType"].string ?? "", f["bitrate"].int ?? 0, url))
            }
        }

        let mp4 = formats.filter { $0.mime.contains("mp4") }
        guard !mp4.isEmpty else {
            if let webm = formats.first {
                throw InnerTubeError.unsupportedCodec(
                    "This track is only offered as \(webm.mime), which macOS playback can't open."
                )
            }
            throw InnerTubeError.playback(lastStreamClientError ?? "No audio stream was returned for this track.")
        }
        // Higher bitrate wins; itag 140 (128 kbps AAC) is what this normally lands on.
        let ranked = mp4.sorted { $0.bitrate > $1.bitrate }
        let best = (highQuality ? ranked.first : ranked.last)!
        guard let url = URL(string: best.url) else {
            throw InnerTubeError.playback("Malformed stream URL.")
        }
        return StreamInfo(url: url, mimeType: best.mime, bitrate: best.bitrate, itag: best.itag, duration: nil)
    }




    // MARK: - Parsing

    private static func bestThumbnail(_ node: JSON) -> String? {
        let lists = node.collectOrdered("thumbnails")
        if let thumbs = lists.first?.array ?? node["thumbnails"].array {
            let best = thumbs
                .map { JSON($0) }
                .compactMap { item -> (Int, String)? in
                    guard let url = item["url"].string else { return nil }
                    return (item["width"].int ?? 0, url)
                }
                .max { $0.0 < $1.0 }
            if let best { return best.1 }
        }
        return node["url"].string
    }

    private static func songCount(in text: String) -> Int? {
        text.split(separator: " ").first { $0.allSatisfy(\.isNumber) }.flatMap { Int($0) }
    }

    private static let typeWords: Set<String> = [
        "song", "album", "single", "ep", "playlist", "artist", "video", "mix", "library",
    ]

    /// Joins a row's subtitle runs exactly as YouTube lays them out — the
    /// artist links, the album link and the separators between them — while
    /// pulling out the duration that always sits at the end.
    ///
    /// Only the second column is read: the third is the play count
    /// ("1.9B plays"), which the phone doesn't show either.
    private static func subtitle(
        from item: JSON
    ) -> (text: String, browseId: String?, pageType: String?, videoId: String?, duration: TimeInterval?, artistBrowseId: String?) {
        var parts: [String] = []
        var browseId: String?
        var pageType: String?
        var videoId: String?
        var duration: TimeInterval?
        var artistBrowseId: String?

        let column = item["flexColumns"][1]["musicResponsiveListItemFlexColumnRenderer"]["text"]
        for run in column.runs {
            let text = run.text
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed != "•", let parsed = TimeFormat.parseDuration(trimmed), trimmed.contains(":") {
                duration = parsed
                continue
            }
            if let id = run.browseId {
                // The artist is the first linked run; the album is the next
                // link after a separator. Keep whichever page the row is
                // actually about — the album/playlist — for row navigation,
                // and keep the artist's id aside for rows that *are* artists.
                if run.pageType == "MUSIC_PAGE_TYPE_ARTIST" {
                    artistBrowseId = artistBrowseId ?? id
                } else if let kind = pageKind(run.pageType), kind != .artist {
                    browseId = browseId ?? id
                    pageType = pageType ?? run.pageType
                }
            }
            parts.append(text)
        }

        // A leading type word ("Album • …", "Playlist • …") is metadata for the
        // row's kind, not part of its subtitle.
        var joined = parts.joined()
        if let first = parts.first {
            let word = first.trimmingCharacters(in: .whitespaces)
            if typeWords.contains(word.lowercased()) {
                joined = parts.dropFirst().joined()
            }
        }
        joined = joined.trimmingCharacters(in: CharacterSet(charactersIn: " •,"))

        if duration == nil {
            for raw in item["fixedColumns"].array ?? [] {
                let text = JSON(raw)["musicResponsiveListItemFixedColumnRenderer"]["text"].text ?? ""
                if let parsed = TimeFormat.parseDuration(text) { duration = parsed }
            }
        }
        // Album/artist rows lead with the type word, which is also the kind.
        let kindWord = parts.first?.trimmingCharacters(in: .whitespaces).lowercased()
        if pageType == nil, let kindWord {
            switch kindWord {
            case "album", "single", "ep": pageType = "MUSIC_PAGE_TYPE_ALBUM"
            case "playlist": pageType = "MUSIC_PAGE_TYPE_PLAYLIST"
            case "artist": pageType = "MUSIC_PAGE_TYPE_ARTIST"
            default: break
            }
        }
        return (joined, browseId, pageType, videoId, duration, artistBrowseId)
    }

    private static func pageKind(_ pageType: String?) -> Release.Kind? {
        switch pageType {
        case "MUSIC_PAGE_TYPE_ALBUM", "MUSIC_PAGE_TYPE_AUDIOBOOK": return .album
        case "MUSIC_PAGE_TYPE_PLAYLIST", "MUSIC_PAGE_TYPE_LIBRARY_PLAYLIST": return .playlist
        case "MUSIC_PAGE_TYPE_ARTIST": return .artist
        default: return nil
        }
    }

    private static func overlayPlay(_ item: JSON) -> (videoId: String?, playlistId: String?) {
        let play = item["overlay"]["musicItemThumbnailOverlayRenderer"]["content"]["musicPlayButtonRenderer"]["playNavigationEndpoint"]
        let watch = play["watchEndpoint"].exists ? play["watchEndpoint"] : play["watchPlaylistEndpoint"]
        return (watch["videoId"].nonEmptyString, watch["playlistId"].nonEmptyString)
    }

    static func parseSongItem(_ item: JSON) -> Song? {
        guard item.exists else { return nil }
        guard let title = item["flexColumns"][0]["musicResponsiveListItemFlexColumnRenderer"]["text"].text,
              !title.isEmpty else { return nil }
        let sub = subtitle(from: item)
        let play = overlayPlay(item)
        let directWatch = item.collectOrdered("watchEndpoint").first?["videoId"].nonEmptyString
        guard let videoId = play.videoId ?? sub.videoId ?? directWatch else { return nil }
        let musicVideoType = item.collectOrdered("watchEndpointMusicConfig").first?["musicVideoType"].string ?? ""
        let split = SubtitleSplit.artistAndAlbum(sub.text)
        return Song(
            videoId: videoId,
            title: title,
            artist: split.artist,
            album: split.album,
            duration: sub.duration,
            thumbnailURL: bestThumbnail(item["thumbnail"]),
            playlistId: play.playlistId,
            isVideo: musicVideoType == "MUSIC_VIDEO_TYPE_OMV" || musicVideoType == "MUSIC_VIDEO_TYPE_UGC"
        )
    }

    static func parseResponsiveItem(_ item: JSON) -> SearchRow? {
        guard let title = item["flexColumns"][0]["musicResponsiveListItemFlexColumnRenderer"]["text"].text,
              !title.isEmpty else { return nil }
        let sub = subtitle(from: item)
        let play = overlayPlay(item)
        let directWatch = item.collectOrdered("watchEndpoint").first?["videoId"].nonEmptyString
        let videoId = play.videoId ?? sub.videoId ?? directWatch

        let kind: SearchRow.Kind
        // A row with no video is a page: the kind and the id come from the link
        // it carries. An artist row has no link inside its columns at all — the
        // whole row is the link — so that endpoint is read from the item.
        let rowEndpoint = item["navigationEndpoint"]["browseEndpoint"]
        let rowBrowseId = rowEndpoint["browseId"].nonEmptyString

        // The subtitle's leading word is the row's own type ("Álbum • …",
        // "Artista • …"), which is more trustworthy than any link: an album row
        // links to its artist too, and trusting that link filed albums under
        // Artists.
        let typeWord = sub.text
            .split(separator: "•").first?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let isAlbumWord = ["álbum", "album", "single", "ep"].contains(typeWord)
        let isArtistWord = typeWord.hasPrefix("artista") || typeWord.hasPrefix("artist")
            || sub.text.lowercased().contains("ouvintes mensais")
            || sub.text.lowercased().contains("monthly listeners")

        let resolvedBrowseId: String?
        if videoId != nil {
            kind = .song
            resolvedBrowseId = nil
        } else if isAlbumWord {
            kind = .album
            resolvedBrowseId = rowBrowseId ?? sub.browseId
        } else if isArtistWord {
            kind = .artist
            resolvedBrowseId = rowBrowseId ?? sub.artistBrowseId
        } else if pageKind(sub.pageType) == .album {
            kind = .album
            resolvedBrowseId = sub.browseId ?? rowBrowseId
        } else if let page = pageKind(sub.pageType), page == .playlist || page == .mix {
            kind = .playlist
            resolvedBrowseId = sub.browseId ?? rowBrowseId
        } else {
            kind = .playlist
            resolvedBrowseId = sub.browseId ?? rowBrowseId
        }
        return SearchRow(
            kind: kind,
            title: title,
            subtitle: sub.text,
            thumbnailURL: bestThumbnail(item["thumbnail"]),
            videoId: videoId,
            browseId: resolvedBrowseId,
            playlistId: play.playlistId,
            duration: sub.duration
        )
    }

    /// A row is an artist only when its own subtitle says so. Songs carry a
    /// row-level link to *their* artist, and treating those as artists put the
    /// player's artist tap on whatever featured act came first.
    static func isArtistRow(_ subtitle: String) -> Bool {
        let lowered = subtitle.trimmingCharacters(in: .whitespaces).lowercased()
        return lowered.hasPrefix("artista") || lowered.hasPrefix("artist")
    }

    /// The "top result" card of a search page.
    static func parseTopResultCard(_ item: JSON) -> SearchRow? {
        guard let title = item["title"].text, !title.isEmpty else { return nil }
        let subtitle = item["subtitle"].text ?? ""
        var pageType: String?
        var browseId: String?
        if let firstRun = item["title"]["runs"].array?.first {
            let run = JSON(firstRun)
            let endpoint = run["navigationEndpoint"]["browseEndpoint"]
            let config = endpoint["browseEndpointContextSupportedConfigs"]["browseEndpointContextMusicConfig"]
            pageType = config["pageType"].string
            browseId = endpoint["browseId"].nonEmptyString
        }

        let kind: SearchRow.Kind
        switch pageKind(pageType) {
        case .artist: kind = .artist
        case .album: kind = .album
        case .playlist, .mix: kind = .playlist
        case nil: kind = subtitle.lowercased().hasPrefix("artista") ? .artist : .playlist
        }
        return SearchRow(
            kind: kind,
            title: title,
            subtitle: subtitle,
            thumbnailURL: bestThumbnail(item["thumbnail"]),
            videoId: nil,
            browseId: browseId,
            playlistId: nil,
            duration: nil
        )
    }

    static func parseTwoRow(_ item: JSON) -> ShelfItem? {
        guard let title = item["title"].text, !title.isEmpty else { return nil }
        let endpoint = item["navigationEndpoint"]
        let browseId = endpoint["browseEndpoint"]["browseId"].nonEmptyString
        let videoId = endpoint["watchEndpoint"]["videoId"].nonEmptyString
        let pageType = endpoint["browseEndpoint"]["browseEndpointContextSupportedConfigs"]["browseEndpointContextMusicConfig"]["pageType"].string
        let videoType = item.collectOrdered("watchEndpointMusicConfig").first?["musicVideoType"].string ?? ""
        return ShelfItem(
            title: title,
            subtitle: item["subtitle"].text ?? "",
            thumbnailURL: bestThumbnail(item["thumbnailRenderer"]),
            videoId: videoId,
            browseId: browseId,
            playlistId: endpoint["watchEndpoint"]["playlistId"].nonEmptyString,
            duration: nil,
            pageKind: pageKind(pageType),
            isVideo: videoType.contains("OMV") || videoType.contains("UGC")
        )
    }

    static func parseCard(_ item: JSON) -> SearchRow? {
        guard let title = item["title"].text, !title.isEmpty else { return nil }
        let subtitle = item["subtitle"].text ?? item["straplineTextOne"].text ?? ""
        var videoId: String?
        var browseId: String?
        for button in item.collectOrdered("buttonRenderer") {
            if let id = button["navigationEndpoint"]["watchEndpoint"]["videoId"].nonEmptyString { videoId = id }
            if let id = button["navigationEndpoint"]["browseEndpoint"]["browseId"].nonEmptyString, browseId == nil { browseId = id }
        }
        if videoId == nil { videoId = item.collectOrdered("watchEndpoint").first?["videoId"].nonEmptyString }
        if browseId == nil { browseId = item.collectOrdered("browseEndpoint").first?["browseId"].nonEmptyString }
        let kind: SearchRow.Kind = (browseId != nil && videoId == nil) ? .album : .song
        return SearchRow(
            kind: kind,
            title: title,
            subtitle: subtitle,
            thumbnailURL: bestThumbnail(item["thumbnail"]),
            videoId: videoId,
            browseId: browseId,
            duration: nil
        )
    }

    /// A shelf whose title says it is about videos: its cards are drawn 16:9
    /// with the view count, as the phone does.
    private static func markVideoShelf(title: String, items: [ShelfItem]) -> [ShelfItem] {
        let lowered = title.lowercased()
        let isVideoShelf = lowered.contains("vídeo") || lowered.contains("video")
        guard isVideoShelf else { return items }
        return items.map { item in
            var copy = item
            copy.isVideo = true
            return copy
        }
    }

    /// The album/playlist carousels of an artist page ("Álbuns", "Singles",
    /// "Aparece em"), kept as shelves of two-row cards.
    private static func parseCarousels(_ json: JSON) -> [Shelf] {
        var shelves: [Shelf] = []
        for raw in json.collectOrdered("musicCarouselShelfRenderer") {
            let title = raw["header"]["musicCarouselShelfBasicHeaderRenderer"]["title"].text
                ?? raw["header"]["musicCarouselShelfBasicHeaderRenderer"]["strapline"].text
                ?? ""
            var items: [ShelfItem] = []
            for row in raw["contents"].array ?? [] {
                let node = JSON(row)
                // Carousel entries wrap the card in `musicTwoRowItemRenderer`.
                let card = node["musicTwoRowItemRenderer"].exists
                    ? node["musicTwoRowItemRenderer"] : node
                guard let item = parseTwoRow(card) else { continue }
                items.append(item)
            }
            if !items.isEmpty, !title.isEmpty {
                shelves.append(Shelf(title: title, items: items))
            }
        }
        return shelves
    }

    static func parseShelves(_ json: JSON) -> [Shelf] {
        var shelves: [Shelf] = []

        for carousel in json.collectOrdered("musicCarouselShelfRenderer") {
            let title = carousel["header"]["musicCarouselShelfBasicHeaderRenderer"]["title"].text
                ?? carousel["header"]["musicShelfBasicHeaderRenderer"]["title"].text
                ?? ""
            guard !title.isEmpty else { continue }
            var items: [ShelfItem] = []
            for raw in carousel["contents"].array ?? [] {
                let item = JSON(raw)
                if item["musicTwoRowItemRenderer"].exists,
                   let parsed = parseTwoRow(item["musicTwoRowItemRenderer"]) {
                    items.append(parsed)
                } else if item["musicResponsiveListItemRenderer"].exists,
                          let song = parseSongItem(item["musicResponsiveListItemRenderer"]) {
                    items.append(ShelfItem(
                        title: song.title,
                        subtitle: song.artist,
                        thumbnailURL: song.thumbnailURL,
                        videoId: song.videoId,
                        playlistId: song.playlistId,
                        duration: song.duration,
                        pageKind: .mix
                    ))
                }
            }
            if !items.isEmpty {
                shelves.append(Shelf(title: title, items: markVideoShelf(title: title, items: items)))
            }
        }

        for shelf in json.collectOrdered("musicShelfRenderer") {
            let title = shelf["title"].text ?? ""
            guard !title.isEmpty else { continue }
            var items: [ShelfItem] = []
            for raw in shelf["contents"].array ?? [] {
                let item = JSON(raw)
                if item["musicResponsiveListItemRenderer"].exists,
                   let song = parseSongItem(item["musicResponsiveListItemRenderer"]) {
                    items.append(ShelfItem(
                        title: song.title,
                        subtitle: song.artist,
                        thumbnailURL: song.thumbnailURL,
                        videoId: song.videoId,
                        playlistId: song.playlistId,
                        duration: song.duration,
                        pageKind: .mix
                    ))
                } else if item["musicTwoRowItemRenderer"].exists,
                          let parsed = parseTwoRow(item["musicTwoRowItemRenderer"]) {
                    items.append(parsed)
                }
            }
            if !items.isEmpty {
                shelves.append(Shelf(title: title, items: markVideoShelf(title: title, items: items)))
            }
        }

        return shelves
    }
}
