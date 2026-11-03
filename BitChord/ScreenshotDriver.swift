//
//  ScreenshotDriver.swift
//  BitChord for macOS
//
//  A developer-only capture mode. Launched with
//
//    BITCHORD_SCREENSHOT_DIR=/path ./BitChord.app/Contents/MacOS/BitChord
//
//  the app walks itself through its screens and writes a PNG of the real window
//  after each step, then quits. It exists because `screencapture` needs screen
//  recording permission the harness doesn't have, and because ImageRenderer
//  cannot rasterise ScrollView content — capturing the window is the only way
//  to see what the app actually looks like.
//
//  Inert (one environment lookup) in normal use.
//

import SwiftUI
import AppKit

@MainActor
enum ScreenshotDriver {
    static func startIfRequested(model: AppModel) {
        guard let directory = ProcessInfo.processInfo.environment["BITCHORD_SCREENSHOT_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        Task { await run(model: model, directory: directory) }
    }

    private static func run(model: AppModel, directory: String) async {
        // The capture flow drives a lot of state quickly; a crossfade that
        // fires mid-walk would swap tracks under the screenshots.
        if ProcessInfo.processInfo.environment["BITCHORD_TEST_NO_CROSSFADE"] == "1" {
            model.settings.crossfadeSeconds = 0
        }
        // Give the first network round trip time to fill Home.
        try? await Task.sleep(nanoseconds: 4_000_000_000)

        capture("01-home", directory: directory)

        model.select(.search)
        model.query = "daft punk get lucky"
        model.searchNow()
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        capture("02-search", directory: directory)

        model.select(.library)
        try? await Task.sleep(nanoseconds: 800_000_000)
        capture("03-library", directory: directory)

        model.select(.explore)
        model.loadMoods()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        capture("04-explore", directory: directory)

        // A real track, so the player has artwork, a duration and lyrics.
        // Prefer a track from the imported archive: it is a real release the
        // addon usually carries, which is what exercises the lossless path.
        if let archived = model.library.recentlyPlayed.first {
            model.player.play(archived, startRadio: false)
            model.openPlayer()
        } else if let seed = model.results.first(where: { $0.videoId != nil }) {
            model.activate(seed)
        } else if let item = model.homeShelves.flatMap({ $0.items }).first(where: { $0.videoId != nil }) {
            model.activate(item)
        }
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        capture("05-now-playing", directory: directory)

        model.playerTab = .lyrics
        if let song = model.player.current { model.loadLyrics(for: song) }
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        capture("06-lyrics", directory: directory)

        model.playerTab = .queue
        try? await Task.sleep(nanoseconds: 700_000_000)
        capture("07-queue", directory: directory)

        model.closePlayer()
        model.select(.home)
        try? await Task.sleep(nanoseconds: 900_000_000)
        capture("08-home-playing", directory: directory)

        // A live `screencapture` is the only way to see compositor effects such
        // as Liquid Glass, which `cacheDisplay` cannot rasterise.
        if let hold = ProcessInfo.processInfo.environment["BITCHORD_HOLD_AFTER_HOME"],
           let seconds = Double(hold) {
            print("holding for \(seconds)s at home-playing")
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }

        if let shelf = model.homeShelves.first, let item = shelf.items.first,
           let browseId = item.browseId {
            model.openRelease(browseId: browseId, kind: item.pageKind ?? .album,
                              title: item.title, subtitle: item.subtitle,
                              thumbnail: item.thumbnailURL)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            capture("09-release", directory: directory)
        }

        if let song = model.player.current {
            let spotify = await SpotifyCanvasService.shared.clip(for: song)
            print("spotify canvas:", spotify?.url.absoluteString ?? "none")
        }

        if ProcessInfo.processInfo.environment["BITCHORD_LYRICS_TEST"] != nil {
            print("lyricsTest providers:", model.settings.lyricsProviders)
            let probe = Song(videoId: "kJQP7kiw5Fk", title: "SAOKO", artist: "ROSALÍA",
                             album: "MOTOMAMI", duration: 137, thumbnailURL: nil)
            model.loadLyrics(for: probe, force: true)
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            print("lyricsTest result lines:", model.lyrics.lyrics.lines.count,
                  "| failed:", model.lyrics.failed,
                  "| provider:", model.lyrics.currentProvider ?? "-",
                  "| attempts:", model.lyrics.attempts)
        }

        if let query = ProcessInfo.processInfo.environment["BITCHORD_SEARCH_TEST"] {
            model.select(.search)
            model.searchNow(query)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
        }

        if let artist = model.library.archiveTaste?.artists.first, let id = artist.id {
            model.push(.release(kind: .artist, browseId: id, title: artist.name,
                                subtitle: "Artista", thumbnail: artist.art))
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            capture("13-artist", directory: directory)
        }

        model.push(.replay)
        try? await Task.sleep(nanoseconds: 900_000_000)
        capture("10-replay", directory: directory)

        model.push(.settings)
        try? await Task.sleep(nanoseconds: 700_000_000)
        capture("11-settings", directory: directory)

        model.popToRoot()
        model.select(.home)
        NSApp.windows.first?.setContentSize(NSSize(width: 900, height: 800))
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        capture("12-narrow", directory: directory)

        if ProcessInfo.processInfo.environment["BITCHORD_SCREENSHOT_QUIT"] != "0" {
            NSApp.terminate(nil)
        }
    }

    private static func capture(_ name: String, directory: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView else {
            print("screenshot: no window for \(name)")
            return
        }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let path = directory + "/" + name + ".png"
        try? png.write(to: URL(fileURLWithPath: path))
        print("screenshot: \(path)")
    }
}
