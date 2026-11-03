//
//  Backup.swift
//  BitChord for macOS
//
//  Importing the Android app's backup. The file carries two things: the
//  DataStore settings map and the listening archive Replay is built from.
//
//  Android counterpart: the JSON its own "export backup" writes — `app`,
//  `version`, `settings` (each `{type, value}`), `listening` (per-month
//  aggregates). Nothing secret is in it: no tokens, no cookies, no account.
//

import Foundation
import SwiftUI
import AppKit

// MARK: - Listening archive

struct ListeningTrack: Codable, Hashable {
    var id: String
    var title: String
    var artist: String
    var album: String?
    var art: String?
    var ms: Double
    var plays: Int
    var last: Double
}

struct ListeningArtist: Codable, Hashable {
    var name: String
    var art: String?
    var ms: Double
    var plays: Int
    /// The YouTube Music browse id the backup carries (artist or album page).
    var id: String?
    /// Albums carry their artist here.
    var sub: String?
}

struct ListeningMonth: Codable, Identifiable, Hashable {
    var id: String { month }
    var month: String
    var totalMs: Double
    var tracks: [ListeningTrack]
    var artists: [ListeningArtist]
    var albums: [ListeningArtist]
    var hours: [Double]

    var trackCount: Int { tracks.count }
    var hoursListened: Double { totalMs / 3_600_000 }
}

// MARK: - Report

struct BackupReport {
    var versionName: String = ""
    var exportedAt: String = ""
    var applied: [String] = []
    var skipped: [String] = []
    var conflicts: [String] = []
    var historyImported = 0
    var searchesImported = 0
    var monthsImported = 0

    var summary: String {
        var lines: [String] = []
        lines.append("Backup do BitGranada \(versionName) (\(exportedAt.prefix(10))).")
        if historyImported > 0 {
            lines.append("\(historyImported) reproduções e \(monthsImported) meses de histórico.")
        }
        if searchesImported > 0 { lines.append("\(searchesImported) buscas recentes.") }
        lines.append("\(applied.count) ajustes aplicados.")
        if !skipped.isEmpty {
            lines.append("\(skipped.count) ajustes só existem no Android: " + skipped.prefix(6).joined(separator: ", ")
                         + (skipped.count > 6 ? "…" : ""))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Importer

@MainActor
enum BackupImporter {
    enum ImportError: LocalizedError {
        case notABackup
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .notABackup: return "This file isn't a BitGranada backup."
            case .unreadable(let detail): return detail
            }
        }
    }

    static func read(from url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else {
            throw ImportError.unreadable("The file couldn't be read.")
        }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["app"] as? String) == "bitchord" else {
            throw ImportError.notABackup
        }
        return object
    }

    /// Applies everything the macOS build understands and reports the rest.
    @discardableResult
    static func apply(
        _ object: [String: Any],
        settings: AppSettings,
        library: LibraryStore
    ) -> BackupReport {
        var report = BackupReport()
        report.versionName = object["versionName"] as? String ?? "?"
        report.exportedAt = object["exportedAt"] as? String ?? ""

        let rawSettings = object["settings"] as? [String: Any] ?? [:]
        let values: [String: String] = rawSettings.reduce(into: [:]) { result, pair in
            guard let entry = pair.value as? [String: Any] else { return }
            if let text = entry["value"] as? String {
                result[pair.key] = text
            } else if let number = entry["value"] as? NSNumber {
                result[pair.key] = number.stringValue
            }
        }

        // Appearance
        if let theme = values["theme_mode"] {
            switch theme.uppercased() {
            case "SYSTEM":
                settings.appearance = .system
                report.applied.append("theme_mode")
            case "DARK":
                settings.appearance = .dark
                report.applied.append("theme_mode")
            case "LIGHT":
                settings.appearance = .light
                report.applied.append("theme_mode")
            default:
                report.skipped.append("theme_mode")
            }
        }

        // Crossfade
        if let crossfade = values["crossfade_seconds"].flatMap(Double.init) {
            settings.crossfadeSeconds = min(12, max(0, crossfade.rounded()))
            report.applied.append("crossfade_seconds")
        }

        // Lyrics providers: order and the enabled subset.
        let orderNames = (values["lyrics_source_order"] ?? "").split(separator: ",").map(String.init)
        let enabledNames = (values["lyrics_sources"] ?? "").split(separator: ",").map(String.init)
        let mappedOrder = uniqueMapped(orderNames)
        if !mappedOrder.isEmpty {
            let enabledMapped = Set(uniqueMapped(enabledNames))
            let enabled = enabledMapped.isEmpty ? mappedOrder : mappedOrder.filter { enabledMapped.contains($0) }
            settings.lyricsProviders = enabled
            report.applied.append("lyrics_source_order (\(enabled.count) ativos)")
        }
        let unsupportedLyrics = orderNames.filter { mapProvider($0) == nil }
        if !unsupportedLyrics.isEmpty {
            report.skipped.append("letras sem equivalente: " + unsupportedLyrics.prefix(4).joined(separator: ","))
        }

        // Language: the backup's translation language is a good hint for a
        // Brazilian listener, but only when it isn't already Portuguese.
        if values["translation_language"]?.lowercased().hasPrefix("pt") == true {
            settings.language = .ptBR
            report.applied.append("idioma (pt-BR)")
        }

        // Recent searches
        if let raw = values["search_history"], let data = raw.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let titles = array.compactMap { $0["title"] as? String }.filter { !$0.isEmpty }
            library.importSearchHistory(titles)
            report.searchesImported = titles.count
            report.applied.append("search_history")
        }

        // Listening archive → history + Replay months.
        if let months = object["listening"] as? [[String: Any]] {
            let parsed = months.compactMap(parseMonth)
            library.importListening(parsed)
            report.monthsImported = parsed.count
            report.historyImported = parsed.reduce(0) { $0 + $1.tracks.count }
        }

        // Everything else is phone-only; name it rather than pretending.
        let handled: Set<String> = [
            "theme_mode", "crossfade_seconds", "lyrics_source_order", "lyrics_sources",
            "search_history", "translation_language",
        ]
        for key in values.keys where !handled.contains(key) {
            report.skipped.append(key)
        }
        report.skipped.sort()
        return report
    }

    private static func uniqueMapped(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in names {
            guard let id = mapProvider(name), !seen.contains(id) else { continue }
            seen.insert(id)
            out.append(id)
        }
        return out
    }

    /// Android provider enum → this build's `LyricsSource` id.
    private static func mapProvider(_ name: String) -> String? {
        switch name.uppercased() {
        case "LRC_RED": return LyricsSource.lrcRed.rawValue
        case "BINI_LYRICS": return LyricsSource.biniLyrics.rawValue
        // Sources that need a paid API key are gone; an order that mentions
        // them simply skips those entries.
        case "BETTER_LYRICS", "BETTER_LYRICS_PORTATO", "PAXSENIX",
             "PAXSENIX_SPOTIFY", "PAXSENIX_MUSIXMATCH": return nil
        case "LYRICS_PLUS": return LyricsSource.lyricsPlus.rawValue
        case "UNISON": return LyricsSource.unison.rawValue
        case "KUGOU": return LyricsSource.kuGou.rawValue
        case "LRCLIB": return LyricsSource.lrcLib.rawValue
        default: return nil
        }
    }

    private static func parseMonth(_ raw: [String: Any]) -> ListeningMonth? {
        guard let month = raw["month"] as? String else { return nil }
        let tracks: [ListeningTrack] = (raw["tracks"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String,
                  let title = item["title"] as? String else { return nil }
            return ListeningTrack(
                id: id,
                title: title,
                artist: item["artist"] as? String ?? "",
                album: item["album"] as? String,
                art: item["art"] as? String,
                ms: (item["ms"] as? NSNumber)?.doubleValue ?? 0,
                plays: (item["plays"] as? NSNumber)?.intValue ?? 1,
                last: (item["last"] as? NSNumber)?.doubleValue ?? 0
            )
        }
        let artists: [ListeningArtist] = (raw["artists"] as? [[String: Any]] ?? []).compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            return ListeningArtist(
                name: name,
                art: item["art"] as? String,
                ms: (item["ms"] as? NSNumber)?.doubleValue ?? 0,
                plays: (item["plays"] as? NSNumber)?.intValue ?? 0,
                id: item["id"] as? String,
                sub: item["sub"] as? String
            )
        }
        let albums: [ListeningArtist] = (raw["albums"] as? [[String: Any]] ?? []).compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            return ListeningArtist(
                name: name,
                art: item["art"] as? String,
                ms: (item["ms"] as? NSNumber)?.doubleValue ?? 0,
                plays: (item["plays"] as? NSNumber)?.intValue ?? 0,
                id: item["id"] as? String,
                sub: item["sub"] as? String
            )
        }
        let hours = (raw["hours"] as? [NSNumber] ?? []).map(\.doubleValue)
        let total = tracks.reduce(0) { $0 + $1.ms }
        return ListeningMonth(month: month, totalMs: total, tracks: tracks,
                              artists: artists, albums: albums, hours: hours)
    }
}

// MARK: - Picker

@MainActor
enum BackupPicker {
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Importar"
        panel.message = "Escolha o backup do BitGranada (JSON)"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
