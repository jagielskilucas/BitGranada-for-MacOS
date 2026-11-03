//
//  ArtistSignature.swift
//  BitChord for macOS
//
//  Handwritten artist signatures from the optional signature API the 1.9 build
//  integrates (github.com/itsmeadarsh2008/artist-signature).
//
//  Android counterpart: data/canvas/ArtistSignatures.kt (lookup, caching, best
//  pick) and SignatureInk.kt (turning a scanned autograph into white ink).
//

import SwiftUI
import AppKit

struct ArtistSignature: Hashable {
    var url: URL
    var aspect: Double
    var format: String
}

@MainActor
final class ArtistSignatureService: ObservableObject {
    static let shared = ArtistSignatureService()

    @Published private(set) var cache: [String: ArtistSignature?] = [:]
    private var inFlight: Set<String> = []

    private var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        return URLSession(configuration: config)
    }()

    func cached(_ artist: String, base: String) -> ArtistSignature? {
        cache[key(artist, base)] ?? nil
    }

    func isLoaded(_ artist: String, base: String) -> Bool {
        cache.keys.contains(key(artist, base))
    }

    /// Looks the artist up once, never throws, and remembers "nothing" as
    /// firmly as it remembers a hit.
    func signature(for artist: String, baseURL: String) async -> ArtistSignature? {
        let base = Self.normalize(baseURL)
        guard !base.isEmpty, let url = URL(string: base + "/v1/signatures"), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "artist", value: artist)]
        let key = key(artist, baseURL)
        if cache.keys.contains(key) { return cache[key] ?? nil }
        if inFlight.contains(key) { return nil }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        var signature: ArtistSignature?
        if let requestURL = components.url {
            var request = URLRequest(url: requestURL)
            request.setValue("BitGranada-macOS/2.0", forHTTPHeaderField: "User-Agent")
            if let (data, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                signature = Self.parse(object)
            }
        }
        cache[key] = signature
        return signature
    }

    /// Health check for the settings row.
    func check(baseURL: String) async -> Bool {
        let base = Self.normalize(baseURL)
        guard !base.isEmpty, let url = URL(string: base + "/v1/health") else { return false }
        guard let (_, response) = try? await session.data(from: url) else { return false }
        return (response as? HTTPURLResponse)?.statusCode ?? 0 < 300
    }

    static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        guard value.hasPrefix("http://") || value.hasPrefix("https://") else { return "" }
        return value
    }

    private func key(_ artist: String, _ base: String) -> String {
        artist.lowercased() + "\n" + Self.normalize(base)
    }

    /// `signatures[]`, tolerating `asset` as an object or a string and the
    /// legacy top-level `url`/`original_url`. A `matches[]` answer means the
    /// name is ambiguous, which is a miss rather than a guess.
    private static func parse(_ object: [String: Any]) -> ArtistSignature? {
        guard object["matches"] == nil else { return nil }
        let entries = object["signatures"] as? [[String: Any]] ?? []
        var best: (score: Int, signature: ArtistSignature)?

        for entry in entries {
            var urlString: String?
            if let asset = entry["asset"] as? [String: Any] {
                urlString = asset["url"] as? String
            } else if let asset = entry["asset"] as? String {
                urlString = asset
            }
            urlString = urlString ?? entry["url"] as? String ?? entry["original_url"] as? String
            guard let urlString, let url = URL(string: urlString) else { continue }

            // The API nests the format and dimensions inside `asset`; older
            // shapes put them at the top level.
            let asset = entry["asset"] as? [String: Any]
            let format = (asset?["format"] as? String
                ?? entry["format"] as? String
                ?? url.pathExtension).lowercased()
            var aspect = (entry["aspect"] as? NSNumber)?.doubleValue ?? 0
            if aspect == 0,
               let width = (asset?["width"] as? NSNumber)?.doubleValue,
               let height = (asset?["height"] as? NSNumber)?.doubleValue, height > 0 {
                aspect = width / height
            }
            if aspect == 0 { aspect = 4 }

            let verification = entry["verification"] as? [String: Any]
            let verified = (verification?["verified"] as? Bool)
                ?? ((verification?["status"] as? String)?.lowercased() == "verified")

            var score = 0
            if format == "svg" { score += 3 }
            if verified { score += 2 }
            if aspect >= 2 { score += 1 }

            let signature = ArtistSignature(url: url, aspect: aspect, format: format)
            if best == nil || score > best!.score { best = (score, signature) }
        }
        return best?.signature
    }
}

/// The signature drawn on the artist header. Raster scans are inverted and
/// screen-blended so the paper disappears and the ink reads white; transparent
/// SVG/PNG are simply tinted.
struct SignatureView: View {
    var signature: ArtistSignature
    var height: CGFloat = 64

    @State private var image: NSImage?

    private var isScan: Bool {
        !["svg", "png", "webp"].contains(signature.format.lowercased())
            || signature.aspect < 3
    }

    var body: some View {
        Group {
            if let image {
                if isScan {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .colorInvert()
                        .blendMode(.screen)
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .renderingMode(.template)
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(.white)
                }
            } else {
                Color.clear
            }
        }
        .frame(height: height)
        .frame(maxWidth: 460, alignment: .leading)
        .task(id: signature.url) {
            if let data = try? await URLSession.shared.data(from: signature.url).0 {
                image = NSImage(data: data)
            }
        }
    }
}
