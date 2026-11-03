//
//  Canvas.swift
//  BitChord for macOS
//
//  The Spotify Canvas loop — the short vertical video that plays behind a track
//  on the phone. BitChord's Android build resolves canvases from several
//  catalogues; the one that needs no account at all is the community manifest,
//  which is what this build uses.
//
//  Android counterpart: data/canvas/CommunityCanvas.kt + CanvasRepository.kt.
//

import Foundation
import SwiftUI
import AVFoundation
import AppKit
import WebKit

struct CanvasClip: Hashable {
    var url: URL
    var song: String
    var artist: String
    var album: String?
}

actor CanvasService {
    static let shared = CanvasService()

    private struct Entry {
        let song: String
        let artist: String
        let album: String
        let url: String
    }

    private var entries: [Entry] = []
    private var fetchedAt: Date?
    private let ttl: TimeInterval = 30 * 60
    private let manifestURL = "https://vivimusicanvas.mkmdevilmi.workers.dev/canvas.json"
    private var misses: [String: Date] = [:]
    private var hits: [String: CanvasClip] = [:]

    func clip(for song: Song) async -> CanvasClip? {
        let key = "\(song.title)|\(song.artist)"
        if let hit = hits[key] { return hit }
        // A miss expires: a provider that was slow or offline once must not
        // stop this track from animating for the rest of the session.
        if let missedAt = misses[key], Date().timeIntervalSince(missedAt) < 600 { return nil }

        // Try the YouTube Music track first (a video's title and artwork are
        // not what the catalogues index), then the song as it arrived — so the
        // canonical lookup can only add hits, never take one away.
        for subject in await Self.subjects(for: song) {
            if let clip = await lookup(subject) {
                hits[key] = clip
                misses[key] = nil
                return clip
            }
        }
        misses[key] = Date()
        print("canvas: nada para \(song.title) / \(song.artist)")
        return nil
    }

    private func lookup(_ song: Song) async -> CanvasClip? {
        if SpotifySecrets.hasCookie,
           let spotify = await SpotifyCanvasService.shared.clip(for: song) {
            print("canvas: spotify para \(song.title)")
            return spotify
        }

        // No Spotify canvas (or no session): Apple Music's motion artwork,
        // which the phone also falls back to. It is HLS, so it streams from
        // the catalogue rather than being downloaded like a community clip.
        if let apple = await AppleMusicCanvasService.shared.clip(for: song) {
            print("canvas: apple para \(song.title)")
            return apple
        }

        let index = await manifest()
        guard !index.isEmpty else {
            print("canvas: nenhum índice comunitário para \(song.title)")
            return nil
        }

        let wantTitle = Self.normalize(song.title)
        let wantArtist = Self.normalize(song.artist)
        let wantAlbum = song.album.map(Self.normalize)

        let hit = index.first { entry in
            let title = Self.normalize(entry.song)
            let artist = Self.normalize(entry.artist)
            let album = Self.normalize(entry.album)
            guard !title.isEmpty, !artist.isEmpty else { return false }
            let titleOK = wantTitle.contains(title) || title.contains(wantTitle)
            let artistOK = wantArtist.contains(artist) || artist.contains(wantArtist)
            let albumOK = album.isEmpty || wantAlbum == nil || album == wantAlbum
            return titleOK && artistOK && albumOK
        }

        guard let hit, let remote = URL(string: hit.url) else { return nil }
        guard let local = await cachedFile(for: remote) else { return nil }
        return CanvasClip(url: local, song: hit.song, artist: hit.artist,
                          album: hit.album.isEmpty ? nil : hit.album)
    }


    // MARK: Cache

    private static let cacheDirectory: URL = {
        let candidates = [
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("BitGranada/Canvas", isDirectory: true),
            URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("BitGranada/Canvas", isDirectory: true),
        ].compactMap { $0 }

        for candidate in candidates {
            try? FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
            let probe = candidate.appendingPathComponent(".writable")
            if (try? Data().write(to: probe)) != nil {
                try? FileManager.default.removeItem(at: probe)
                return candidate
            }
        }
        // Never crash for a cache directory: the temporary folder always exists.
        return candidates.last ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BitGranada/Canvas", isDirectory: true)
    }()

    private static func fileName(for url: URL) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16) + ".mp4"
    }

    private func cachedFile(for remote: URL) async -> URL? {
        let destination = Self.cacheDirectory.appendingPathComponent(Self.fileName(for: remote))
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        guard let (temporary, response) = try? await URLSession.shared.download(from: remote) else { return nil }
        let size = response.expectedContentLength
        guard size <= 0 || size < 60 * 1024 * 1024 else { return nil }
        try? FileManager.default.removeItem(at: destination)
        guard (try? FileManager.default.moveItem(at: temporary, to: destination)) != nil else { return nil }
        pruneCache()
        return destination
    }

    /// Keeps the canvas cache under ~300 MB, oldest first.
    private func pruneCache() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: Self.cacheDirectory, includingPropertiesForKeys: keys
        ) else { return }
        let sorted = files.compactMap { url -> (URL, Date, Int)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.1 < $1.1 }
        var total = sorted.reduce(0) { $0 + $1.2 }
        for item in sorted where total > 300 * 1024 * 1024 {
            try? FileManager.default.removeItem(at: item.0)
            total -= item.2
        }
    }

    private func manifest() async -> [Entry] {
        if !entries.isEmpty, let fetchedAt, Date().timeIntervalSince(fetchedAt) < ttl {
            return entries
        }
        var request = URLRequest(url: URL(string: manifestURL)!)
        request.setValue("BitGranada-macOS/2.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["items"] as? [[String: Any]] else {
            fetchedAt = Date()
            return entries
        }
        let parsed: [Entry] = items.compactMap { item in
            guard let song = item["song"] as? String,
                  let artist = item["artist"] as? String,
                  let url = item["url"] as? String else { return nil }
            return Entry(song: song, artist: artist, album: item["album"] as? String ?? "", url: url)
        }
        if !parsed.isEmpty { entries = parsed }
        fetchedAt = Date()
        return entries
    }

    /// The metadata candidates a lookup should try, best first.
    static func subjects(for song: Song) async -> [Song] {
        let canonical = await trackVersion(of: song)
        if canonical.title == song.title && canonical.artist == song.artist {
            return [song]
        }
        return [canonical, song]
    }

    /// The YouTube Music track behind a row that came in as a music video.
    /// Returns the song unchanged when it already is one (or when the search
    /// finds nothing better).
    static func trackVersion(of song: Song) async -> Song {
        let markers = ["official video", "videoclipe", "clipe oficial", "music video",
                       "official music video", "lyric video", "visualizer", "ao vivo", "live"]
        let looksLikeVideo = song.isVideo || {
            let lowered = song.title.lowercased()
            return markers.contains { lowered.contains($0) }
        }()
        guard looksLikeVideo else { return song }

        var cleaned = song.title
        for pattern in [#"\s*[\(\[].*?[\)\]]"#, #"\s*-\s*(official|clipe|video|videoclipe).*$"#] {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                cleaned = regex.stringByReplacingMatches(
                    in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: ""
                )
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)

        let candidates = await InnerTubeClient.shared.songCandidates("\(cleaned) \(song.artist)")
        let want = normalize(cleaned)
        let match = candidates.first { candidate in
            !candidate.isVideo && normalize(candidate.title).contains(want)
        } ?? candidates.first { normalize($0.title).contains(want) }

        guard let match else { return song }
        return Song(
            videoId: song.videoId,
            title: match.title,
            artist: match.artist,
            album: match.album ?? song.album,
            duration: match.duration ?? song.duration,
            thumbnailURL: match.thumbnailURL ?? song.thumbnailURL,
            playlistId: song.playlistId,
            localURL: song.localURL,
            isVideo: false
        )
    }

    /// Lower case, accents and punctuation gone, bracketed qualifiers dropped —
    /// the same loose matching the phone does, which is what lets
    /// "Get Lucky (Radio Edit)" find the entry filed as "Get Lucky".
    static func normalize(_ text: String) -> String {
        var value = text.lowercased()
        if let regex = try? NSRegularExpression(pattern: #"[\(\[\{].*?[\)\]\}]"#) {
            value = regex.stringByReplacingMatches(
                in: value, range: NSRange(value.startIndex..., in: value), withTemplate: " "
            )
        }
        value = value.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
        if let regex = try? NSRegularExpression(pattern: #"[^a-z0-9 ]+"#) {
            value = regex.stringByReplacingMatches(
                in: value, range: NSRange(value.startIndex..., in: value), withTemplate: " "
            )
        }
        return value.split(separator: " ").joined(separator: " ")
    }
}

// MARK: - Video layer

/// An `AVPlayerLayer` that loops a canvas clip, muted, and never takes input.
/// The canvas backdrop.
///
/// Played in a `WKWebView` with a `<video>` element, because `AVPlayer` cannot
/// play the sources we get: the Apple Music motion artwork is an HLS playlist it
/// reports as ready and never advances, and the community m3u8/mp4 host ignores
/// HTTP range requests, which makes AVFoundation cancel the load. WebKit plays
/// both, and its video pipeline is composited on the GPU like any other layer.
struct CanvasVideoView: NSViewRepresentable {
    var url: URL?
    var looping: Bool = true

    func makeNSView(context: Context) -> CanvasWebView {
        let view = CanvasWebView()
        view.load(url: url, looping: looping)
        return view
    }

    func updateNSView(_ nsView: CanvasWebView, context: Context) {
        nsView.load(url: url, looping: looping)
    }

    static func dismantleNSView(_ nsView: CanvasWebView, coordinator: ()) {
        nsView.stop()
    }

    final class CanvasWebView: NSView {
        private let webView = WKWebView(frame: .zero, configuration: {
            let configuration = WKWebViewConfiguration()
            configuration.mediaTypesRequiringUserActionForPlayback = []
            configuration.preferences.isElementFullscreenEnabled = false
            configuration.suppressesIncrementalRendering = false
            return configuration
        }())
        private var current: URL?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            webView.setValue(false, forKey: "drawsBackground")
            webView.isHidden = false
            webView.navigationDelegate = nil
            addSubview(webView)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            webView.frame = bounds
        }

        /// Stops decoding while the canvas is off screen: a hidden video that
        /// keeps playing costs a whole web process and its decoder for nothing.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window == nil else {
                // Back on screen: the layout may have paused it on the way out.
                resumePlayback()
                return
            }
            webView.pauseAllMediaPlayback()
        }

        private func resumePlayback() {
            webView.evaluateJavaScript(
                "(function(){var v=document.querySelector('video'); if(v&&v.paused){v.play();}})();",
                completionHandler: nil
            )
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            // A zero-sized layout pass happens while views are being built; it
            // must not leave the canvas paused for the rest of the track, which
            // is why the resume is explicit once there is room again.
            if newSize.width < 2 || newSize.height < 2 {
                webView.pauseAllMediaPlayback()
            } else {
                resumePlayback()
            }
        }

        func load(url: URL?, looping: Bool) {
            guard let url else { stop(); return }
            guard current != url else { return }
            current = url
            // An HLS master carries several renditions and WebKit picks one by
            // bandwidth, which looks soft on a large sleeve. Resolve the biggest
            // variant and load that playlist directly.
            if url.pathExtension.lowercased() == "m3u8" {
                Task { [weak self] in
                    guard let best = await Self.highestVariant(of: url, maxHeight: 1080) else { return }
                    await MainActor.run { self?.play(best) }
                }
                return
            }
            play(url)
        }

        private func play(_ url: URL) {
            let type = url.pathExtension.lowercased() == "mp4" ? "video/mp4" : "application/x-mpegURL"
            let html = """
            <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
              html,body{margin:0;padding:0;background:transparent;overflow:hidden;height:100%}
              video{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;
                    background:transparent;}
            </style></head>
            <body><video autoplay muted loop playsinline preload="auto" disablepictureinpicture>
            <source src="\(url.absoluteString)" type="\(type)">
            </video></body></html>
            """
            webView.loadHTMLString(html, baseURL: url)
        }

        /// The heftiest rendition of a master playlist, by pixel area.
        static func highestVariant(of master: URL, maxHeight: Int = 1440) async -> URL? {
            guard let (data, _) = try? await URLSession.shared.data(from: master),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            let lines = text.split(separator: "\n").map(String.init)
            var best: (area: Int, uri: String)?
            for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") {
                guard index + 1 < lines.count else { continue }
                let uri = lines[index + 1].trimmingCharacters(in: .whitespaces)
                guard !uri.isEmpty, !uri.hasPrefix("#") else { continue }
                var area = 0
                if let range = line.range(of: "RESOLUTION=") {
                    let size = line[range.upperBound...].prefix { $0 != "," && $0 != "\r" }
                    let parts = size.split(separator: "x").compactMap { Int($0) }
                    if parts.count == 2 { area = parts[0] * parts[1] }
                }
                // A ceiling keeps the start quick: picking a 2160 rendition for a
                // 300 pt panel cost seconds before the first frame.
                let height = area > 0 ? Int(Double(area).squareRoot()) : 0
                guard height <= maxHeight else { continue }
                if area > (best?.area ?? 0) { best = (area, uri) }
            }
            guard let best else { return nil }
            return URL(string: best.uri, relativeTo: master)?.absoluteURL
        }

        func stop() {
            webView.stopLoading()
            webView.loadHTMLString("<html><body style='background:transparent'></body></html>",
                                   baseURL: nil as URL?)
            current = nil
        }
    }
}
