//
//  AppSettings.swift
//  BitChord for macOS
//
//  The settings the desktop build actually honours. Each one is backed by
//  UserDefaults and applied live, the same way the phone's DataStore-backed
//  AppSettings.kt entries are.
//

import SwiftUI
import Combine

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }
}

enum AudioQuality: String, CaseIterable, Identifiable {
    case standard, high
    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard: return "Standard"
        case .high: return "High"
        }
    }
    var detail: String {
        switch self {
        case .standard: return "AAC, up to 128 kbps"
        case .high: return "AAC, highest available bitrate"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance") }
    }
    /// Tint the player and the shell from the cover, as the phone's mesh does.
    @Published var artworkBackdrop: Bool {
        didSet { defaults.set(artworkBackdrop, forKey: "artworkBackdrop") }
    }
    /// Open the lyrics tab automatically when a track starts.
    @Published var showLyricsOnOpen: Bool {
        didSet { defaults.set(showLyricsOnOpen, forKey: "showLyricsOnOpen") }
    }
    @Published var audioQuality: AudioQuality {
        didSet { defaults.set(audioQuality.rawValue, forKey: "audioQuality") }
    }
    /// Kept as a preference even though the AVPlayer engine doesn't crossfade
    /// yet — the value is shown in Settings with that caveat rather than
    /// silently pretending.
    @Published var crossfadeSeconds: Double {
        didSet { defaults.set(crossfadeSeconds, forKey: "crossfadeSeconds") }
    }
    @Published var showMiniPlayerProgress: Bool {
        didSet { defaults.set(showMiniPlayerProgress, forKey: "showMiniPlayerProgress") }
    }
    /// The right-hand now-playing column, beside the library.
    @Published var showNowPlayingRail: Bool {
        didSet { defaults.set(showNowPlayingRail, forKey: "showNowPlayingRail") }
    }
    /// Spotify Canvas loops behind the artwork, when one exists for the track.
    @Published var canvasEnabled: Bool {
        didSet { defaults.set(canvasEnabled, forKey: "canvasEnabled") }
    }
    /// Preload the next track so an album flows without a gap.
    @Published var gaplessEnabled: Bool {
        didSet { defaults.set(gaplessEnabled, forKey: "gaplessEnabled") }
    }
    /// Addon sources, by base URL (without `/manifest.json`).
    @Published var addonSources: [String] {
        didSet { defaults.set(addonSources, forKey: "addonSources") }
    }
    /// Prefer an addon's lossless stream over YouTube's AAC when one matches.
    @Published var preferAddonQuality: Bool {
        didSet { defaults.set(preferAddonQuality, forKey: "preferAddonQuality") }
    }
    /// Optional artist-signature API (the 1.9 integration).
    @Published var signatureApiEnabled: Bool {
        didSet { defaults.set(signatureApiEnabled, forKey: "signatureApiEnabled") }
    }
    @Published var signatureApiURL: String {
        didSet { defaults.set(signatureApiURL, forKey: "signatureApiURL") }
    }
    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: "language") }
    }
    /// Lyrics provider ids, in the order they are tried.
    @Published var lyricsProviders: [String] {
        didSet { defaults.set(lyricsProviders, forKey: "lyricsProviders") }
    }
    /// API keys for the providers that need one (PaxSenix, BetterLyrics).
    @Published var lyricsKeys: [String: String] {
        didSet { defaults.set(lyricsKeys, forKey: "lyricsKeys") }
    }

    private let defaults = UserDefaults.standard

    init() {
        let savedAppearance = defaults.string(forKey: "appearance").flatMap(AppAppearance.init(rawValue:)) ?? .dark
        appearance = savedAppearance
        artworkBackdrop = defaults.object(forKey: "artworkBackdrop") as? Bool ?? true
        showLyricsOnOpen = defaults.object(forKey: "showLyricsOnOpen") as? Bool ?? false
        audioQuality = defaults.string(forKey: "audioQuality").flatMap(AudioQuality.init(rawValue:)) ?? .high
        crossfadeSeconds = defaults.object(forKey: "crossfadeSeconds") as? Double ?? 0
        showMiniPlayerProgress = defaults.object(forKey: "showMiniPlayerProgress") as? Bool ?? true
        showNowPlayingRail = defaults.object(forKey: "showNowPlayingRail") as? Bool ?? true
        canvasEnabled = defaults.object(forKey: "canvasEnabled") as? Bool ?? true
        gaplessEnabled = defaults.object(forKey: "gaplessEnabled") as? Bool ?? true
        signatureApiEnabled = defaults.object(forKey: "signatureApiEnabled") as? Bool ?? true
        signatureApiURL = defaults.string(forKey: "signatureApiURL")
            ?? "https://artist-signature.onrender.com"
        addonSources = defaults.stringArray(forKey: "addonSources") ?? AppSettings.defaultAddons
        preferAddonQuality = defaults.object(forKey: "preferAddonQuality") as? Bool ?? true
        language = defaults.string(forKey: "language").flatMap(AppLanguage.init(rawValue:)) ?? .system
        lyricsProviders = defaults.stringArray(forKey: "lyricsProviders") ?? LyricsSource.defaultOrder
        lyricsKeys = defaults.dictionary(forKey: "lyricsKeys") as? [String: String] ?? [:]
    }

    var l10n: L10n { L10n(language: Self.resolvedLanguage(language)) }

    static let defaultAddons = ["https://soundfean-musics.onrender.com/a"]

    static func resolvedLanguage(_ language: AppLanguage) -> AppLanguage { L10n.resolved(language) }

    var theme: BitTheme { BitTheme.resolve(appearance) }
}
