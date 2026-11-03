//
//  Theme.swift
//  BitChord for macOS
//
//  Design tokens carried over one-to-one from the Android app's
//  ui/theme/Theme.kt, so the macOS build reads as the same product.
//
//  Android: app/src/main/java/com/music/bitchord/ui/theme/Theme.kt
//

import SwiftUI
import AppKit
import CoreText

// MARK: - Fonts

/// SF Pro Display, the face the Android app bundles and sets every screen in.
///
/// Theme.kt draws each weight one cut lighter than the name suggests — Heavy
/// draws Bold, Bold draws Semibold, Semibold draws Medium, Medium draws
/// Regular. That mapping is reproduced here in `BitFont.cut(for:)` so the type
/// scale and any weight set in place both match the phone's screens.
enum BitFont {
    enum Weight {
        case regular   // W400 / W500
        case medium    // W600
        case semibold  // W700
        case bold      // W800

        /// The bundled cut this weight draws, exactly as Theme.kt pairs them.
        var postScriptName: String {
            switch self {
            case .regular: return "SFProDisplay-Regular"
            case .medium: return "SFProDisplay-Medium"
            case .semibold: return "SFProDisplay-Semibold"
            case .bold: return "SFProDisplay-Bold"
            }
        }
    }

    private static var registered = false

    /// Registers the five OTFs under Contents/Resources/fonts.
    ///
    /// Info.plist's ATSApplicationFontsPath does this too, but registration is
    /// repeated here so the SwiftUI preview/snapshot harness — which has no
    /// bundle plist — renders in the same face.
    static func registerFonts() {
        guard !registered else { return }
        registered = true
        let dir = Bundle.main.resourceURL?.appendingPathComponent("fonts")
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/fonts")
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }
        for url in urls where url.pathExtension.lowercased() == "otf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Whether the bundled cut actually maps Latin text.
    ///
    /// A face that loads but carries no usable glyphs renders every character
    /// as the "last resort" box — a row of "?" where a lyric should be — so
    /// existence is checked by coverage, not by `NSFont(name:)` returning
    /// something.
    private static var usable: [String: Bool] = [:]

    private static func isUsable(_ postScriptName: String) -> Bool {
        if let cached = usable[postScriptName] { return cached }
        let font = CTFontCreateWithName(postScriptName as CFString, 16, nil)
        var character: UniChar = 0x41  // "A"
        var glyph = CGGlyph(0)
        let mapped = CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        let hasCoverage = mapped && glyph != 0
        usable[postScriptName] = hasCoverage
        if !hasCoverage { print("theme: \(postScriptName) has no Latin coverage; using the system face") }
        return hasCoverage
    }

    static func font(_ weight: Weight, _ size: CGFloat) -> Font {
        registerFonts()
        let name = weight.postScriptName
        if isUsable(name) {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: weight.systemEquivalent)
    }
}

extension BitFont {
    /// SF Pro Display ships Latin only. Lyrics and titles from YouTube Music can
    /// arrive in Chinese, Japanese, Korean, Cyrillic or Arabic — drawing those in
    /// the bundled face yields rows of "?" boxes, so anything outside what the
    /// face actually covers is set in the system font, which has the full
    /// cascade list behind it.
    static func font(_ weight: Weight, _ size: CGFloat, for text: String) -> Font {
        guard needsSystemFace(text) else { return font(weight, size) }
        return .system(size: size, weight: weight.systemEquivalent)
    }

    static func needsSystemFace(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            // Basic Latin, Latin-1 Supplement, Latin Extended-A/B, punctuation,
            // currency signs and the few typographic marks the app sets.
            if value <= 0x024F { continue }
            if (0x2000...0x206F).contains(value) { continue }
            if (0x20A0...0x20CF).contains(value) { continue }
            if value == 0x00A0 || value == 0x2022 || value == 0x2026 { continue }
            return true
        }
        return false
    }
}

extension BitFont.Weight {
    var systemEquivalent: Font.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }
}

// MARK: - Type scale

/// Theme.kt's `BitChordTypography`, size for size and tracking for tracking.
struct BitTextStyle {
    let font: Font
    let tracking: CGFloat
    let lineSpacing: CGFloat

    static let displayLarge = BitTextStyle(font: BitFont.font(.bold, 34), tracking: -0.5, lineSpacing: 2)
    static let headlineLarge = BitTextStyle(font: BitFont.font(.bold, 30), tracking: -0.4, lineSpacing: 2)
    static let headlineMedium = BitTextStyle(font: BitFont.font(.semibold, 22), tracking: -0.25, lineSpacing: 1)
    static let titleLarge = BitTextStyle(font: BitFont.font(.semibold, 20), tracking: -0.2, lineSpacing: 1)
    static let titleMedium = BitTextStyle(font: BitFont.font(.medium, 16), tracking: 0.05, lineSpacing: 1)
    static let bodyLarge = BitTextStyle(font: BitFont.font(.regular, 16), tracking: 0.2, lineSpacing: 2)
    static let bodyMedium = BitTextStyle(font: BitFont.font(.regular, 14), tracking: 0.3, lineSpacing: 2)
    static let labelMedium = BitTextStyle(font: BitFont.font(.medium, 12), tracking: 0.25, lineSpacing: 0)
    static let labelSmall = BitTextStyle(font: BitFont.font(.medium, 11), tracking: 0.3, lineSpacing: 0)
}

extension View {
    func bitStyle(_ style: BitTextStyle) -> some View {
        self.font(style.font).tracking(style.tracking)
    }
}

// MARK: - Colours

/// The two schemes in Theme.kt, as a value the whole app reads.
struct BitColors {
    var primary: Color
    var onPrimary: Color
    var background: Color
    var surface: Color
    var surfaceVariant: Color
    var onSurface: Color
    var onBackground: Color
    var onSurfaceVariant: Color
    var outline: Color

    /// Apple Music's signature red. No longer the accent, but the Replay badge
    /// and the app mark still want that specific red in every theme.
    static let accentRed = Color(hex: 0xFA2D48)

    static let dark = BitColors(
        primary: .white,
        onPrimary: .black,
        background: .black,
        surface: Color(hex: 0x0D0D0F),
        surfaceVariant: Color(hex: 0x1C1C1E),
        onSurface: .white,
        onBackground: .white,
        onSurfaceVariant: Color(hex: 0x8E8E93),
        outline: Color(hex: 0x2C2C2E)
    )

    static let light = BitColors(
        primary: .black,
        onPrimary: .white,
        background: .white,
        surface: Color(hex: 0xF7F7F9),
        surfaceVariant: Color(hex: 0xF2F2F7),
        onSurface: .black,
        onBackground: .black,
        onSurfaceVariant: Color(hex: 0x6E6E73),
        outline: Color(hex: 0xE5E5EA)
    )
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Environment

/// Theme mirror of the Android `MaterialTheme` lookup: one object every view
/// reads colours and the scheme's polarity from.
struct BitTheme {
    var colors: BitColors
    var isDark: Bool

    static func resolve(_ appearance: AppAppearance) -> BitTheme {
        switch appearance {
        case .dark: return BitTheme(colors: .dark, isDark: true)
        case .light: return BitTheme(colors: .light, isDark: false)
        case .system:
            let dark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return BitTheme(colors: dark ? .dark : .light, isDark: dark)
        }
    }
}

private struct BitThemeKey: EnvironmentKey {
    static let defaultValue = BitTheme(colors: .dark, isDark: true)
}

extension EnvironmentValues {
    var bit: BitTheme {
        get { self[BitThemeKey.self] }
        set { self[BitThemeKey.self] = newValue }
    }
}

// MARK: - Metrics

/// Spacing and radius constants the phone's screens repeat everywhere.
enum BitMetrics {
    /// The horizontal gutter every scroll view sets its content to.
    static let gutter: CGFloat = 20
    /// Artwork corner radius used by rows and mini player.
    static let smallArtRadius: CGFloat = 6
    /// Artwork corner radius used by shelf cards.
    static let cardArtRadius: CGFloat = 8
    /// Artwork corner radius used by the now-playing screen.
    static let largeArtRadius: CGFloat = 12
    /// Corner radius of the floating bars (nav bar, mini player).
    static let barRadius: CGFloat = 22
    /// Height of the floating tab bar.
    static let tabBarHeight: CGFloat = 62
    /// Height of the mini player.
    static let miniPlayerHeight: CGFloat = 60
}
