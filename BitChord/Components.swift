//
//  Components.swift
//  BitChord for macOS
//
//  The pieces every screen is built from: the wordmark, cover art, the floating
//  bar material, shelf cards, song rows, the mesh backdrop. Metrics are the
//  phone's (see docs/spec/01-shell-home-search-library.md), expressed in points.
//

import SwiftUI
import AppKit

// MARK: - Mark

/// The BitChord mark — three stacked arcs — traced from the Android vector
/// (`res/drawable/ic_logo.xml`, 730 × 484) so both apps carry the same logo.
struct BitChordMark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 6.7373, y: 316.937))
        p.addCurve(to: CGPoint(x: 72.4033, y: 300.174), control1: CGPoint(x: 20.201, y: 294.159), control2: CGPoint(x: 49.6986, y: 286.649))
        p.addLine(to: CGPoint(x: 72.4277, y: 300.174))
        p.addCurve(to: CGPoint(x: 667.823, y: 359.439), control1: CGPoint(x: 237.603, y: 398.282), control2: CGPoint(x: 510.121, y: 407.302))
        p.addCurve(to: CGPoint(x: 727.602, y: 391.378), control1: CGPoint(x: 693.147, y: 351.759), control2: CGPoint(x: 719.927, y: 366.055))
        p.addCurve(to: CGPoint(x: 695.649, y: 451.176), control1: CGPoint(x: 735.276, y: 416.715), control2: CGPoint(x: 720.992, y: 443.477))
        p.addCurve(to: CGPoint(x: 23.5058, y: 382.622), control1: CGPoint(x: 514.618, y: 506.132), control2: CGPoint(x: 213.674, y: 495.514))
        p.addCurve(to: CGPoint(x: 6.7373, y: 316.937), control1: CGPoint(x: 0.6788, y: 369.103), control2: CGPoint(x: -6.7876, y: 339.685))
        p.closeSubpath()
        p.move(to: CGPoint(x: 77.8135, y: 154.865))
        p.addCurve(to: CGPoint(x: 132.77, y: 141.676), control1: CGPoint(x: 89.38, y: 136.046), control2: CGPoint(x: 113.982, y: 130.11))
        p.addCurve(to: CGPoint(x: 643.46, y: 201.43), control1: CGPoint(x: 270.528, y: 226.369), control2: CGPoint(x: 480.519, y: 250.891))
        p.addCurve(to: CGPoint(x: 693.324, y: 228.052), control1: CGPoint(x: 664.592, y: 195.047), control2: CGPoint(x: 686.911, y: 206.957))
        p.addCurve(to: CGPoint(x: 666.679, y: 277.886), control1: CGPoint(x: 699.689, y: 249.184), control2: CGPoint(x: 687.774, y: 271.46))
        p.addCurve(to: CGPoint(x: 90.9707, y: 209.79), control1: CGPoint(x: 480.555, y: 334.36), control2: CGPoint(x: 249.169, y: 307.004))
        p.addCurve(to: CGPoint(x: 77.8135, y: 154.865), control1: CGPoint(x: 72.1827, y: 198.224), control2: CGPoint(x: 66.247, y: 173.628))
        p.closeSubpath()
        p.move(to: CGPoint(x: 140.542, y: 15.3012))
        p.addCurve(to: CGPoint(x: 184.482, y: 4.7134), control1: CGPoint(x: 149.722, y: 0.2464), control2: CGPoint(x: 169.428, y: -4.5276))
        p.addCurve(to: CGPoint(x: 634.684, y: 54.101), control1: CGPoint(x: 304.811, y: 78.2128), control2: CGPoint(x: 456.29, y: 94.8593))
        p.addCurve(to: CGPoint(x: 672.927, y: 78.1518), control1: CGPoint(x: 651.874, y: 50.1843), control2: CGPoint(x: 669.01, y: 60.9551))
        p.addCurve(to: CGPoint(x: 648.9, y: 116.401), control1: CGPoint(x: 676.862, y: 95.3486), control2: CGPoint(x: 666.134, y: 112.484))
        p.addCurve(to: CGPoint(x: 151.129, y: 59.2417), control1: CGPoint(x: 453.677, y: 161.021), control2: CGPoint(x: 286.219, y: 141.799))
        p.addCurve(to: CGPoint(x: 140.542, y: 15.3012), control1: CGPoint(x: 136.074, y: 50.0006), control2: CGPoint(x: 131.301, y: 30.3561))
        p.closeSubpath()

        let scale = min(rect.width / 730, rect.height / 484)
        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(
                translationX: rect.midX - 730 * scale / 2,
                y: rect.midY - 484 * scale / 2
            ))
        return p.applying(transform)
    }
}

/// The Home header: just the mark, 30.6 pt tall, exactly as `HomeTitle` draws it
/// on the phone (the "Listen Now" text is commented out there too).
struct Wordmark: View {
    var height: CGFloat = 30.6
    var color: Color = .white

    var body: some View {
        BitChordMark()
            .fill(color, style: FillStyle(eoFill: true))
            .frame(width: height * (730.0 / 484.0), height: height)
            .accessibilityLabel("BitGranada")
    }
}

// MARK: - Materials

/// A real macOS blur behind a floating bar. `.withinWindow` samples the app's
/// own content, which is what the phone's Haze-backed bars do.
struct BlurMaterial: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .withinWindow
    /// Forces the material's own appearance. A light-mode system draws the
    /// light variant, which over artwork reads as a white veil.
    var darkAppearance: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        view.isEmphasized = false
        if darkAppearance { view.appearance = NSAppearance(named: .darkAqua) }
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
        view.state = .active
        view.appearance = darkAppearance ? NSAppearance(named: .darkAqua) : nil
    }
}

/// The floating-bar surface: blur, a surface tint, and the 0.5 pt hairline the
/// phone draws on every one of its bars.
struct BarSurface: ViewModifier {
    var theme: BitTheme
    var radius: CGFloat
    var tint: Double = 0.42

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    #if SNAPSHOT
                    theme.colors.surface
                    #else
                    BlurMaterial()
                    #endif
                    theme.colors.surface.opacity(theme.isDark ? tint : 0.55)
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        theme.isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.06),
                        lineWidth: 0.5
                    )
            }
    }
}

extension View {
    func barSurface(_ theme: BitTheme, radius: CGFloat, tint: Double = 0.42) -> some View {
        modifier(BarSurface(theme: theme, radius: radius, tint: tint))
    }
}

// MARK: - Buttons

/// The 44 pt circular control the phone uses in its top bar and player.
struct CircleIconButton: View {
    var systemName: String
    var size: CGFloat = 44
    var glyph: CGFloat = 18
    var theme: BitTheme
    var tint: Color? = nil
    var action: () -> Void

    @State private var hovering = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: glyph, weight: .semibold))
                .foregroundStyle(tint ?? theme.colors.onSurface)
                .frame(width: size, height: size)
                .background {
                    Circle()
                        .fill(hovering ? (theme.isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.06))
                                       : Color.clear)
                }
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Cover art

/// Remote artwork at a fixed square, with the phone's placeholder and ring.
/// A cover that resolves itself: YouTube Music's URL when there is one, the
/// Cover Art Archive when there is not.
struct ResolvedArt: View {
    var url: String?
    var title: String
    var artist: String
    var size: CGFloat
    var radius: CGFloat = 0
    var theme: BitTheme

    @State private var resolved: String?

    var body: some View {
        Group {
            if let shown = url ?? resolved, let parsed = URL(string: shown) {
                CoverArt(url: parsed, size: size, radius: radius, theme: theme)
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(theme.colors.surfaceVariant)
            }
        }
        .task(id: "\(url ?? "")|\(title)|\(artist)") {
            guard url == nil else { return }
            resolved = await CoverArtArchive.shared.cover(title: title, artist: artist)
        }
    }
}

struct CoverArt: View {
    var url: URL?
    var size: CGFloat
    var radius: CGFloat
    var theme: BitTheme
    var isPlaying: Bool = false

    @State private var image: NSImage?
    @State private var visible = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(theme.colors.surfaceVariant)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity.animation(.easeOut(duration: 0.18)))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.28, weight: .medium))
                    .foregroundStyle(theme.colors.onSurfaceVariant.opacity(0.7))
            }
            if isPlaying {
                PlayingBars(size: min(24, size * 0.4))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    theme.isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.06),
                    lineWidth: 1
                )
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task(id: visible ? url : nil) {
            guard let url else {
                image = nil
                return
            }
            if let cached = ArtworkLoader.shared.cached(url) {
                image = cached
                return
            }
            guard visible else { return }
            image = nil
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            image = await ArtworkLoader.shared.image(for: url)
        }
    }
}

/// Artwork that fills an arbitrary box, cropped — the hero card's sleeve and
/// any other non-square frame.
struct FillArtwork: View {
    var url: URL?
    var theme: BitTheme
    var glyphScale: CGFloat = 0.22

    @State private var image: NSImage?
    @State private var visible = false

    var body: some View {
        // Cache consulted at render time: if the @State was lost (view rebuilt)
        // or the image arrived while off screen, it still paints immediately.
        let shown = image ?? url.flatMap { ArtworkLoader.shared.cached($0) }
        return GeometryReader { proxy in
            ZStack {
                theme.colors.surfaceVariant
                if let shown {
                    Image(nsImage: shown)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: max(18, proxy.size.width * glyphScale), weight: .medium))
                        .foregroundStyle(theme.colors.onSurfaceVariant.opacity(0.7))
                }
            }
        }
        // Lazy: nothing is fetched until the card is actually on screen, and
        // the request dies with the view if the listener scrolls past it.
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task(id: visible ? url : nil) {
            guard let url else { image = nil; return }
            // Coming back (or scrolling back) paints from cache at once, even
            // while the view is technically off screen again.
            if let cached = ArtworkLoader.shared.cached(url) { image = cached; return }
            guard visible else { return }
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            image = await ArtworkLoader.shared.image(for: url)
        }
    }
}

/// The three white bars the phone draws over the row that is playing.
struct PlayingBars: View {
    var size: CGFloat = 24
    @State private var animate = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.52))
            HStack(spacing: size * 0.083) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(Color.white)
                        .frame(width: size * 0.125, height: size * 0.34)
                        .scaleEffect(y: animate ? [0.5, 1.0, 0.7][index] : [1.0, 0.55, 0.9][index],
                                     anchor: .bottom)
                        .animation(
                            .easeInOut(duration: 0.5 + Double(index) * 0.12)
                                .repeatForever(autoreverses: true),
                            value: animate
                        )
                }
            }
            .frame(height: size * 0.5)
        }
        .frame(width: size, height: size)
        .onAppear { animate = true }
    }
}

// MARK: - Section header

struct SectionHeader: View {
    var title: String
    var subtitle: String?
    var theme: BitTheme
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .bitStyle(.titleMedium)
                    .foregroundStyle(theme.colors.onSurface)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .bitStyle(.bodyMedium)
                        .foregroundStyle(theme.colors.onSurfaceVariant)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .bitStyle(.labelMedium)
                    .foregroundStyle(theme.colors.onSurfaceVariant)
                    .padding(.vertical, 4)
                    .padding(.leading, 12)
            }
        }
        .padding(.horizontal, BitMetrics.gutter)
        .padding(.vertical, 10)
    }
}

// MARK: - Shelf card

/// A 150 pt shelf card: square art, title, subtitle — the unit the phone's
/// Home, Library and Explore are all made of.
/// Press feedback shared by the cards: a spring scale-down while the mouse is
/// down, so a click feels physical instead of instant.
struct PressScaleButtonStyle: ButtonStyle {
    var pressed: CGFloat = 0.98
    var hover: CGFloat = 1.02
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressed : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.72),
                       value: configuration.isPressed)
    }
}

struct ShelfCard: View {
    var item: ShelfItem
    var theme: BitTheme
    var width: CGFloat = 150
    var radius: CGFloat = 12
    var isPlaying: Bool = false
    /// Asks the Cover Art Archive when the item has no artwork of its own.
    var fallbackArt: Bool = false
    var onTap: () -> Void

    @State private var hovering = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if fallbackArt, item.thumbnailURL == nil {
                        ResolvedArt(url: nil, title: item.albumTitle,
                                    artist: item.albumArtist,
                                    size: width, radius: radius, theme: theme)
                    } else {
                        CoverArt(url: item.artwork(Int(width * 2)), size: width, radius: radius,
                                 theme: theme, isPlaying: isPlaying)
                    }
                }
                    .overlay(alignment: .bottomTrailing) {
                        if hovering {
                            Image(systemName: "play.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(.white.opacity(0.92)))
                                .padding(8)
                                .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        }
                    }
                    .scaleEffect(hovering ? 1.02 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.78), value: hovering)

                HStack(spacing: 4) {
                    Text(item.title)
                        .bitStyle(.titleMedium)
                        .foregroundStyle(theme.colors.onSurface)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.top, 10)

                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .bitStyle(.bodyMedium)
                        .foregroundStyle(theme.colors.onSurfaceVariant)
                        .lineLimit(1)
                        .padding(.top, 1)
                }
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .onHover { hovering = $0 }
    }
}

/// The first shelf's lead card: taller than wide, caption over a scrim.
struct HeroCard: View {
    var item: ShelfItem
    var theme: BitTheme
    var width: CGFloat
    var onTap: () -> Void

    @State private var hovering = false
    @State private var hideTask: Task<Void, Never>?

    private var height: CGFloat { width / 0.92 }

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                FillArtwork(url: item.artwork(Int(width * 2)), theme: theme, glyphScale: 0.3)
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.45),
                        .init(color: .black.opacity(0.55), location: 0.78),
                        .init(color: .black.opacity(0.85), location: 1.0),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .bitStyle(.titleLarge)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .bitStyle(.bodyMedium)
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
                .padding(.top, 34)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            }
            .overlay(alignment: .bottomTrailing) {
                if hovering {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(.white.opacity(0.92)))
                        .padding(16)
                }
            }
            .shadow(color: .black.opacity(hovering ? 0.5 : 0.28), radius: hovering ? 22 : 14, y: 8)
            .scaleEffect(hovering ? 1.02 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.78), value: hovering)
            .animation(.spring(response: 0.3, dampingFraction: 0.82), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle())
        .onHover { hovering = $0 }
    }
}

/// A music video: 16:9 artwork, title, and the "artist · views" line.
struct VideoShelfCard: View {
    var item: ShelfItem
    var theme: BitTheme
    var width: CGFloat = 248
    var onTap: () -> Void

    @State private var hovering = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                FillArtwork(url: item.artwork(Int(width * 2)), theme: theme)
                    .frame(width: width, height: width * 9 / 16)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if hovering {
                            Image(systemName: "play.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(.white.opacity(0.92)))
                                .padding(8)
                        }
                    }
                Text(item.title)
                    .bitStyle(.titleMedium)
                    .foregroundStyle(theme.colors.onSurface)
                    .lineLimit(2)
                    .padding(.top, 10)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .bitStyle(.bodyMedium)
                        .foregroundStyle(theme.colors.onSurfaceVariant)
                        .lineLimit(1)
                        .padding(.top, 1)
                }
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Song row

/// A list row: 52 pt art, title over artist, duration, and a hover-revealed
/// play affordance. The phone's `SongRow`, scaled to pointer input.
struct SongRow: View {
    var song: Song
    var theme: BitTheme
    var isCurrent: Bool = false
    var isPlaying: Bool = false
    var showArtwork: Bool = true
    /// Shown when the row carries no artwork of its own — album pages list
    /// tracks without thumbnails, and the album cover is the right picture.
    var fallbackArtwork: URL? = nil
    var index: Int? = nil
    var trailing: String? = nil
    var onTap: () -> Void
    var onMenu: (() -> Void)? = nil

    @State private var hovering = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                if let index, !showArtwork {
                    Text("\(index)")
                        .bitStyle(.labelMedium)
                        .foregroundStyle(theme.colors.onSurfaceVariant)
                        .monospacedDigit()
                        .frame(width: 26, alignment: .trailing)
                }
                if showArtwork {
                    CoverArt(url: song.artwork(104) ?? fallbackArtwork,
                             size: 52, radius: 8, theme: theme,
                             isPlaying: isCurrent && isPlaying)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .bitStyle(.titleMedium)
                        .foregroundStyle(isCurrent ? theme.colors.primary : theme.colors.onSurface)
                        .lineLimit(1)
                    Text(song.artist.isEmpty ? "Unknown artist" : song.artist)
                        .bitStyle(.bodyMedium)
                        .foregroundStyle(theme.colors.onSurfaceVariant)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                if let trailing {
                    Text(trailing)
                        .bitStyle(.labelMedium)
                        .foregroundStyle(theme.colors.onSurfaceVariant)
                } else if !song.durationText.isEmpty {
                    Text(song.durationText)
                        .bitStyle(.labelMedium)
                        .foregroundStyle(theme.colors.onSurfaceVariant)
                        .monospacedDigit()
                }
                if hovering, let onMenu {
                    Button(action: onMenu) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.colors.onSurfaceVariant)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .frame(height: 60)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? (theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)) : .clear)
                    .padding(.horizontal, 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Chips

struct FilterChip: View {
    var title: String
    var isSelected: Bool
    var theme: BitTheme
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .bitStyle(.labelMedium)
                .foregroundStyle(isSelected ? theme.colors.onPrimary : theme.colors.onSurface)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    Capsule().fill(isSelected ? theme.colors.primary : theme.colors.surfaceVariant)
                }
        }
        .buttonStyle(.plain)
    }
}

/// The phone's squircle segmented control (`PillSegmentedControl`).
struct SegmentedPill<T: Hashable>: View {
    var options: [T]
    var selection: T
    var label: (T) -> String
    var theme: BitTheme
    var onChange: (T) -> Void

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { onChange(option) }
                } label: {
                    Text(label(option))
                        .bitStyle(.labelMedium)
                        .foregroundStyle(selected ? (theme.isDark ? Color.white : Color.black) : theme.colors.onSurfaceVariant)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(theme.isDark ? Color(hex: 0x636366) : .white)
                                    .matchedGeometryEffect(id: "pill", in: namespace)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background {
            Capsule().fill(theme.isDark ? Color(hex: 0x767680, alpha: 0.24) : Color(hex: 0x767680, alpha: 0.12))
        }
    }
}

// MARK: - Mesh backdrop

/// The artwork-driven mesh the phone paints behind the player: a few soft
/// colour fields from the cover's palette over the theme's background, drifting
/// slowly. `TimelineView` keeps the drift cheap — the blobs move, nothing is
/// re-rendered from scratch.
struct MeshBackdrop: View {
    var palette: ArtworkPalette
    var theme: BitTheme
    var intensity: Double = 1

    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack {
                (theme.isDark ? Color.black : Color(hex: 0xF2F2F7))

                blob(palette.colors[0], size: max(w, h) * 0.9)
                    .offset(x: -w * 0.24 + sin(phase) * 26, y: -h * 0.30 + cos(phase * 0.8) * 22)
                blob(palette.colors[1], size: max(w, h) * 0.8)
                    .offset(x: w * 0.30 + cos(phase * 0.7) * 30, y: -h * 0.12 + sin(phase * 0.6) * 24)
                blob(palette.colors[2], size: max(w, h) * 0.75)
                    .offset(x: w * 0.10 + sin(phase * 0.5) * 34, y: h * 0.34 + cos(phase * 0.9) * 18)
                blob(palette.colors[3], size: max(w, h) * 0.6)
                    .offset(x: -w * 0.34 + cos(phase * 0.4) * 20, y: h * 0.36)

                LinearGradient(
                    colors: theme.isDark
                        ? [Color.black.opacity(0.10), Color.black.opacity(0.55), Color.black.opacity(0.82)]
                        : [Color.white.opacity(0.25), Color.white.opacity(0.6), Color.white.opacity(0.9)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .drawingGroup()
            .onAppear {
                withAnimation(.easeInOut(duration: 18).repeatForever(autoreverses: true)) {
                    phase = .pi * 2
                }
            }
        }
        .ignoresSafeArea()
        .opacity(intensity)
    }

    private func blob(_ color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(theme.isDark ? 0.62 : 0.50), color.opacity(0.0)],
                    center: .center, startRadius: 0, endRadius: size / 2
                )
            )
            .frame(width: size, height: size)
            .blur(radius: 46)
            .blendMode(theme.isDark ? .plusLighter : .multiply)
    }
}

// MARK: - States

struct MessageState: View {
    var title: String
    var subtitle: String?
    var theme: BitTheme
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .bitStyle(.bodyLarge)
                .foregroundStyle(theme.colors.onSurfaceVariant)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .bitStyle(.bodyMedium)
                    .foregroundStyle(theme.colors.onSurfaceVariant.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .bitStyle(.labelMedium)
                        .foregroundStyle(theme.colors.onPrimary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(theme.colors.primary))
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
    }
}

/// The phone's shimmer skeleton: a moving band over `surfaceVariant`.
struct ShimmerBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var radius: CGFloat = 8
    var theme: BitTheme

    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(theme.colors.surfaceVariant)
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, theme.colors.onSurfaceVariant.opacity(0.16), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.5)
                    .offset(x: phase * proxy.size.width * 1.6)
                }
                .clipped()
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

// MARK: - Scroll direction

/// Reports whether the page is being scrolled up (towards its top) or down.
///
/// The global `scrollWheel` monitor could not be relied on — SwiftUI's
/// ScrollView consumes those events before the dock reacts — so the page itself
/// reports its own offset, which is authoritative and works with the scroll
/// wheel, the trackpad and the keyboard alike.
struct ScrollDirectionModifier: ViewModifier {
    var onChange: (Bool) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { oldValue, newValue in
                let delta = newValue - oldValue
                // Ignore the little jitter of a trackpad settling.
                guard abs(delta) > 2 else { return }
                onChange(delta < 0)
            }
        } else {
            content
        }
    }
}

extension View {
    func tracksScrollDirection(_ onChange: @escaping (Bool) -> Void) -> some View {
        modifier(ScrollDirectionModifier(onChange: onChange))
    }
}

// MARK: - Draggable title bar

/// A strip that drags the window, standing in for the titlebar the app hides.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DraggableNSView()
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggableNSView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}


// MARK: - Carousel

/// A horizontal row with the system's own scroll affordance: a grey pill with a
/// chevron at each end, shown while the pointer is over the row, which pages the
/// content instead of nudging it by a fixed amount.
struct CarouselScroller<Content: View>: View {
    var count: Int
    var theme: BitTheme
    var itemWidth: CGFloat = 150
    @ViewBuilder var content: Content

    @State private var hovering = false
    @State private var hideTask: Task<Void, Never>?
    /// Where the last jump landed. Paging is index-based on purpose: measuring
    /// SwiftUI's scroll offset inside a `LazyHStack` never reported reliably,
    /// and an `NSScrollView` stripped the hosted content of its size.
    @State private var index = 0
    @State private var viewport: CGFloat = 0

    private var page: Int { 4 }
    /// Width the row would need if every card were laid out edge to edge.
    private var estimatedWidth: CGFloat {
        CGFloat(count) * (itemWidth + 14) + 40
    }
    /// A row that fits the window has nothing to page: no arrows at all.
    private var fitsViewport: Bool { viewport > 40 && estimatedWidth <= viewport + 12 }
    private var canGoBack: Bool { !fitsViewport && index > 0 }
    private var canGoForward: Bool { !fitsViewport && index + page < count }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                content
            }
            .scrollIndicators(.never)
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { viewport = geo.size.width }
                        .onChange(of: geo.size.width) { _, value in viewport = value }
                }
            }
            .overlay(alignment: .leading) {
                if hovering, canGoBack {
                    arrow(.left) { jump(proxy, by: -1) }
                        .padding(.leading, 6)
                        .padding(.bottom, 26)
                }
            }
            .overlay(alignment: .trailing) {
                if hovering, canGoForward {
                    arrow(.right) { jump(proxy, by: 1) }
                        .padding(.trailing, 6)
                        .padding(.bottom, 26)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    hideTask?.cancel()
                    if !hovering { withAnimation(.easeInOut(duration: 0.16)) { hovering = true } }
                case .ended:
                    hideTask?.cancel()
                    hideTask = Task {
                        try? await Task.sleep(nanoseconds: 1_400_000_000)
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { hovering = false }
                    }
                }
            }
            .onDisappear { hideTask?.cancel() }
            .onChange(of: count) { _, _ in index = 0 }
        }
    }

    private func jump(_ proxy: ScrollViewProxy, by direction: Int) {
        let target = min(max(0, count - 1), index + direction * page)
        index = target
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            proxy.scrollTo("carousel-\(target)", anchor: .leading)
        }
    }

    private enum Side { case left, right }

    private func arrow(_ side: Side, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: side == .left ? "chevron.left" : "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 52)
                .background(Capsule().fill(Color(white: 0.32).opacity(0.92)))
                .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }
}

private struct CarouselMetrics: Equatable {
    var minX: CGFloat
    var width: CGFloat
}

private struct CarouselMetricsKey: PreferenceKey {
    static var defaultValue = CarouselMetrics(minX: 0, width: 0)
    static func reduce(value: inout CarouselMetrics, nextValue: () -> CarouselMetrics) {
        value = nextValue()
    }
}

private struct CarouselViewportKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

