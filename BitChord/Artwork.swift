//
//  Artwork.swift
//  BitChord for macOS
//
//  Cover art loading, caching and the palette the now-playing backdrop is
//  built from.
//
//  Android counterpart: ui/components/RemoteArtwork.kt and the artwork-driven
//  mesh palette in MainActivity.kt.
//

import SwiftUI
import AppKit
import CoreGraphics

/// Loads and caches remote artwork. One shared cache, decoded once per URL, so
/// scrolling a shelf back and forth doesn't re-download covers.
@MainActor
final class ArtworkLoader {
    func clearMemory() {
        cache.removeAllObjects()
    }

    static let shared = ArtworkLoader()

    private let cache = NSCache<NSURL, NSImage>()
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
        // Covers are cheap to re-fetch and expensive to hold: 160 entries is
        // enough for the rows on screen plus the next scroll.
        cache.countLimit = 160
        // Bounded in bytes as well: a few hundred full-size covers is hundreds
        // of megabytes, which is what pushed the app's footprint up.
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func cached(_ url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func image(for url: URL, pixels: Int = 512) async -> NSImage? {
        if let cached = cached(url) { return cached }
        if let image = await fetch(url) {
            cache.setObject(image, forKey: url as NSURL)
            return image
        }
        // Some uploads reject a `=w…-h…` rewrite that asks for more pixels than
        // the original has. Fall back to the unsized URL before giving up, so a
        // cover never renders as the placeholder for that reason alone.
        if let base = Self.baseURL(url), base != url, let image = await fetch(base) {
            cache.setObject(image, forKey: url as NSURL)
            return image
        }
        return nil
    }

    private func fetch(_ url: URL) async -> NSImage? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return nil }
        return NSImage(data: data)
    }

    /// Everything before the `=w…` size suffix.
    private static func baseURL(_ url: URL) -> URL? {
        guard let range = url.absoluteString.range(of: "=w", options: .backwards) else { return nil }
        return URL(string: String(url.absoluteString[..<range.lowerBound]))
    }
}

// MARK: - Palette

/// The handful of colours a cover is reduced to.
struct ArtworkPalette {
    var colors: [Color]
    var accent: Color
    var isFallback: Bool

    /// The artwork's colour lifted toward white — the "player tint" the phone
    /// uses for the artist line, the times and the docked chrome.
    var tint: Color {
        guard let ns = NSColor(accent).usingColorSpace(.sRGB) else { return .white }
        let lifted = ns.blended(withFraction: 0.55, of: .white) ?? .white
        return Color(nsColor: lifted)
    }

    static let fallback = ArtworkPalette(
        colors: [
            Color(hex: 0xFA2D48),
            Color(hex: 0x7A1E33),
            Color(hex: 0x2A1B33),
            Color(hex: 0x120D16),
        ],
        accent: Color(hex: 0xFA2D48),
        isFallback: true
    )
}

/// Extracts a palette the way the phone does: downsample the cover, throw away
/// near-black/near-white pixels that carry no hue, bucket what's left by hue
/// and keep the heaviest buckets. The result drives the mesh backdrop and the
/// tint on the now-playing screen.
enum PaletteExtractor {
    static func clearCache() {
        lock.lock(); cache.removeAll(); lock.unlock()
    }

    private static var cache: [String: ArtworkPalette] = [:]
    private static let lock = NSLock()

    static func cachedPalette(for key: String) -> ArtworkPalette? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    static func extract(from image: NSImage, key: String) -> ArtworkPalette {
        if let cached = cachedPalette(for: key) { return cached }
        let palette = compute(from: image)
        lock.lock()
        if cache.count > 120 { cache.removeAll(keepingCapacity: true) }
        cache[key] = palette
        lock.unlock()
        return palette
    }

    private static func compute(from image: NSImage) -> ArtworkPalette {
        let dimension = 32
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: dimension, pixelsHigh: dimension,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: dimension * 4, bitsPerPixel: 32
        ) else { return .fallback }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: dimension, height: dimension),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.bitmapData else { return .fallback }
        struct Bucket { var weight: Double = 0; var r: Double = 0; var g: Double = 0; var b: Double = 0 }
        var buckets = [Int: Bucket]()

        for y in 0..<dimension {
            for x in 0..<dimension {
                let offset = y * rep.bytesPerRow + x * 4
                let r = Double(data[offset]) / 255
                let g = Double(data[offset + 1]) / 255
                let b = Double(data[offset + 2]) / 255
                let maxC = max(r, g, b), minC = min(r, g, b)
                let value = maxC
                let saturation = maxC == 0 ? 0 : (maxC - minC) / maxC
                // Near-black and near-white pixels say nothing about the hue
                // of the cover; skip them rather than letting them win.
                guard value > 0.12, value < 0.97 else { continue }
                var hue: Double
                if maxC == minC { hue = 0 }
                else if maxC == r { hue = (g - b) / (maxC - minC) + (g < b ? 6 : 0) }
                else if maxC == g { hue = (b - r) / (maxC - minC) + 2 }
                else { hue = (r - g) / (maxC - minC) + 4 }
                hue /= 6
                let bucketIndex = Int(hue * 12) % 12
                let weight = 0.25 + saturation * 1.6 + value * 0.4
                var bucket = buckets[bucketIndex] ?? Bucket()
                bucket.weight += weight
                bucket.r += r * weight
                bucket.g += g * weight
                bucket.b += b * weight
                buckets[bucketIndex] = bucket
            }
        }

        let ranked = buckets.sorted { $0.value.weight > $1.value.weight }.prefix(4)
        guard !ranked.isEmpty else { return .fallback }

        var colors: [Color] = ranked.map { _, bucket in
            let weight = max(bucket.weight, 0.0001)
            var r = bucket.r / weight
            var g = bucket.g / weight
            var b = bucket.b / weight
            // Push saturation up: a cover's average is always duller than the
            // cover looks, and the backdrop wants the cover's colour, not mud.
            let maxC = max(r, g, b), minC = min(r, g, b)
            let saturation = maxC == 0 ? 0 : (maxC - minC) / maxC
            let boost = min(1.0, saturation * 1.35 + 0.15)
            r = min(1, maxC + (r - maxC) * boost)
            g = min(1, maxC + (g - maxC) * boost)
            b = min(1, maxC + (b - maxC) * boost)
            return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
        }
        while colors.count < 4 {
            colors.append(Color(.sRGB, red: 0.05, green: 0.05, blue: 0.06, opacity: 1))
        }
        let accent = colors[0]
        return ArtworkPalette(colors: colors, accent: accent, isFallback: false)
    }
}
