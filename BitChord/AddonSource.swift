//
//  AddonSource.swift
//  BitChord for macOS
//
//  Addon sources — plain HTTP services that answer `/manifest.json`,
//  `/search?q=` and `/stream/{id}` with JSON. The Android build speaks the same
//  protocol; a Soundfean/Qobuz addon answers with FLAC, which is why this is
//  worth having beside YouTube's AAC.
//
//  Android counterpart: data/sources/addon/AddonClient.kt + AddonModels.kt.
//

import Foundation

// MARK: - Wire shapes

struct AddonManifest {
    var id: String = ""
    var name: String = ""
    var version: String = ""
    var resources: [String] = []
    var allowDownloads: Bool = true
    var settings: [AddonSetting] = []

    struct AddonSetting {
        var key: String
        var defaultValue: String?
        var options: [String]
    }

    /// Parsed by hand: the manifests in the wild are loose JSON, and
    /// `allowDownloads` arrives as `1` from the reference addon, which a
    /// `Decodable Bool` refuses.
    static func parse(_ data: Data) -> AddonManifest? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var manifest = AddonManifest()
        manifest.id = object["id"] as? String ?? ""
        manifest.name = object["name"] as? String ?? ""
        manifest.version = object["version"] as? String ?? ""
        manifest.resources = object["resources"] as? [String] ?? []
        if let flag = object["allowDownloads"] as? NSNumber { manifest.allowDownloads = flag.boolValue }
        else if let flag = object["allowDownloads"] as? Bool { manifest.allowDownloads = flag }

        manifest.settings = (object["settings"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let key = raw["key"] as? String else { return nil }
            let options = (raw["options"] as? [[String: Any]] ?? []).compactMap { $0["value"] as? String }
            return AddonSetting(key: key, defaultValue: raw["default"] as? String, options: options)
        }
        return manifest
    }

    func declares(_ resource: String) -> Bool {
        resources.contains { $0.caseInsensitiveCompare(resource) == .orderedSame }
    }

    /// The declared default of a setting, which is what the phone's client
    /// sends when it has no form to render.
    func defaultSetting(_ key: String) -> String? {
        settings.first { $0.key == key }?.defaultValue
            ?? settings.first { $0.key == key }?.options.first
    }
}

struct AddonTrack: Decodable, Identifiable, Hashable {
    var id: String
    var title: String
    var artist: String
    var album: String?
    var duration: Double?
    var artworkURL: String?
    var audioQuality: String?
    var format: String?

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, duration
        case artworkURL = "artworkURL"
        case audioQuality, format
    }
}

struct AddonStream: Decodable {
    var url: String?
    var format: String?
    var codec: String?
    var container: String?
    var quality: String?
    var mimeType: String?
    var sampleRate: Double?
    var bitDepth: Double?
    var bitrate: Double?
    var error: String?

    var label: String {
        var parts: [String] = []
        if let quality, !quality.isEmpty {
            parts.append(quality)
        } else if let bitDepth, let sampleRate, bitDepth > 0 {
            parts.append("\(Int(bitDepth))-bit · \(Int(sampleRate / 1000)) kHz")
        } else if let format, !format.isEmpty {
            parts.append(format.uppercased())
        }
        return parts.joined(separator: " · ")
    }

    /// Higher is better; used when an addon answers with a list rather than one
    /// stream.
    var rank: Int {
        var score = 0
        if let bitDepth { score += Int(bitDepth) * 100 }
        else if let format {
            switch format.lowercased() {
            case "flac": score += 2400
            case "alac": score += 2400
            case "mp3": score += 1600
            default: break
            }
        }
        if let sampleRate { score += Int(sampleRate / 1000) }
        if let bitrate { score += Int(bitrate / 1000) }
        return score
    }
}

// MARK: - Client

@MainActor
final class AddonSource: Identifiable, ObservableObject {
    let id: String
    var baseURL: URL
    @Published private(set) var manifest: AddonManifest?
    @Published private(set) var status: String = "não verificado"
    @Published private(set) var isReachable = false

    private let session: URLSession
    private var lastQualityLabel: String?

    init(url: URL) {
        self.baseURL = url
        self.id = url.absoluteString
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        session = URLSession(configuration: config)
    }

    var name: String { manifest?.name ?? baseURL.host ?? "Fonte" }

    // MARK: Manifest

    func loadManifest() async {
        guard let url = URL(string: baseURL.absoluteString + "/manifest.json") else { return }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                status = "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                return
            }
            guard let parsed = AddonManifest.parse(data) else { status = "manifesto inválido"; return }
            manifest = parsed
            isReachable = true
            status = "\(manifest?.name ?? "ok") \(manifest?.version ?? "")"
        } catch {
            isReachable = false
            status = error.localizedDescription
        }
    }

    // MARK: Search

    func search(_ query: String) async -> [AddonTrack] {
        guard var components = URLComponents(string: baseURL.absoluteString + "/search") else { return [] }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let data = await get(components.url!) else { return [] }
        struct Envelope: Decodable { var tracks: [AddonTrack]? }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
           let tracks = envelope.tracks {
            return tracks
        }
        return (try? JSONDecoder().decode([AddonTrack].self, from: data)) ?? []
    }

    // MARK: Stream

    /// Asks for the best quality the addon offers, in the order the phone uses.
    func stream(for track: AddonTrack) async -> AddonStream? {
        let preferred = ["HI_RES", "LOSSLESS", "HIGH", "LOW"]
        for quality in preferred {
            if let stream = await requestStream(id: track.id, quality: quality), stream.url != nil {
                lastQualityLabel = stream.label
                return stream
            }
        }
        return nil
    }

    private func requestStream(id: String, quality: String) async -> AddonStream? {
        guard var components = URLComponents(string: baseURL.absoluteString + "/stream/\(id)") else { return nil }
        var items: [URLQueryItem] = [URLQueryItem(name: "quality", value: quality)]
        // Any other declared setting goes with its default, as the phone does.
        for setting in manifest?.settings ?? [] where setting.key != "quality" {
            if let value = setting.defaultValue ?? setting.options.first {
                items.append(URLQueryItem(name: setting.key, value: value))
            }
        }
        components.queryItems = items
        guard let data = await get(components.url!) else { return nil }
        return try? JSONDecoder().decode(AddonStream.self, from: data)
    }

    private func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue("BitGranada-macOS/2.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 {
            // A 404 on `/stream` is a miss for this track, not an outage.
            return nil
        }
        guard http.statusCode == 200 else {
            if http.statusCode >= 500 { isReachable = false }
            return nil
        }
        isReachable = true
        return data
    }

    // MARK: Match

    /// The addon row that is this track, or nil. Title must match after
    /// normalising; artist containment settles the rest; duration within a few
    /// seconds breaks ties, because the same title is often a karaoke cut.
    nonisolated static func bestMatch(for song: Song, in tracks: [AddonTrack]) -> AddonTrack? {
        let wantTitle = CanvasService.normalize(song.title)
        let wantArtist = CanvasService.normalize(song.artist)
        var best: (score: Int, track: AddonTrack)?

        for track in tracks {
            let title = CanvasService.normalize(track.title)
            guard !title.isEmpty else { continue }
            var score = 0

            if title == wantTitle { score += 6 }
            else if title.contains(wantTitle) || wantTitle.contains(title) { score += 3 }
            else { continue }

            let artist = CanvasService.normalize(track.artist)
            if !wantArtist.isEmpty, artist.contains(wantArtist) || wantArtist.contains(artist) {
                score += 4
            } else {
                let firstArtist = wantArtist.split(separator: " ").prefix(2).joined(separator: " ")
                if !firstArtist.isEmpty, artist.contains(firstArtist) { score += 2 }
            }

            if let duration = track.duration, let wanted = song.duration, wanted > 0 {
                let delta = abs(duration - wanted)
                if delta <= 3 { score += 4 }
                else if delta <= 8 { score += 1 }
                else if delta > 25 { score -= 3 }
            }

            if best == nil || score > best!.score { best = (score, track) }
        }
        guard let best, best.score >= 5 else { return nil }
        return best.track
    }
}
