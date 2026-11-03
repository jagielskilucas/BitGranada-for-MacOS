//
//  NowPlayingRail.swift
//  BitChord for macOS
//
//  The right-hand column: what is playing, its canvas loop, and the synced
//  lyrics — the desktop equivalent of the phone's "peek" at the player, and of
//  the lyric column Apple Music keeps beside the library.
//
//  It appears whenever a track is playing and the full player is closed, and
//  leaves the window entirely below ~1100 pt so the grid keeps its room.
//

import SwiftUI
import AppKit

struct NowPlayingRail: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var player: PlayerEngine
    @ObservedObject var library: LibraryStore
    /// Observed on its own: reading `lyricsStore.lyrics` through the parent
    /// model compiles but never re-renders when the store publishes.
    @ObservedObject var lyricsStore: LyricsStore
    /// The music video, when one is playing: it keeps running here after the
    /// fullscreen view closes.
    /// Whether the clip is being shown behind the column.
    /// On by default: the clip is the column's background, as the canvas was.
    var width: CGFloat
    var onClose: () -> Void

    @Environment(\.l10n) private var l10n

    @State private var canvas: CanvasClip?
    @State private var artwork: NSImage?
    @State private var palette: ArtworkPalette = .fallback

    private var theme: BitTheme { settings.theme }

    /// How bright the column's own backdrop is. The glass is tinted by the
    /// artwork's accent, so that colour decides whether white ink survives.
    private var backdropLuminance: Double {
        guard let colour = NSColor(palette.accent).usingColorSpace(.sRGB) else { return 0 }
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(colour.redComponent)
            + 0.7152 * channel(colour.greenComponent)
            + 0.0722 * channel(colour.blueComponent)
    }
    private var backdropIsLight: Bool { backdropLuminance > 0.42 }
    /// Ink that keeps its contrast: dark on a bright sleeve, white on a dark one.
    private var ink: Color { backdropIsLight ? Color.black.opacity(0.88) : .white }
    private var inkSoft: Color { backdropIsLight ? Color.black.opacity(0.62) : .white.opacity(0.66) }
    /// One gutter for every row of the column — artwork, credits, divider and
    /// lyrics all line up on the same edge.
    private let margin: CGFloat = 12
    private var song: Song? { player.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            artworkView(side: max(80, width - margin * 2))
                .padding(.horizontal, margin)
                .padding(.top, 8)
            credits
                .padding(.horizontal, margin)
                .padding(.top, 14)
            Divider().overlay(theme.colors.outline).padding(.horizontal, margin).padding(.top, 14)
            lyrics
            footer
        }
        .frame(width: width)
        .background {
            // Blurred backdrop (canvas when there is one), with a dark veil
            // between it and the text so the lyrics keep their contrast.
            ZStack {
                if settings.canvasEnabled, let canvas {
                    // No blur over live video: that forces an offscreen pass per
                    // frame. A slight scale plus the scrim below gives the same
                    // soft backdrop and keeps the compositing on the GPU.
                    // A light blur keeps the lyrics legible over the motion
                    // artwork without the cost of the old 16 pt pass.
                    CanvasVideoView(url: canvas.url)
                        .id(canvas.url)
                        .scaleEffect(1.06)
                        .blur(radius: 7)
                } else if let artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 20)
                }
                Color.black.opacity(theme.isDark ? 0.42 : 0.26)
            }
            .compositingGroup()
            // The blurred backdrop must not swallow clicks meant for the page
            // behind the column's edges.
            .allowsHitTesting(false)
        }
        // Clipping the *outside* is what keeps the blur from painting over the
        // content column: a blur renders beyond its frame, so it has to be cut
        // after the background is composited.
        .clipShape(Rectangle())
        // Square corners: the column reads as a panel of the window, not a card
        // floating over it.
        // Frosted glass tinted with the cover's own colour: the column picks up
        // whatever album is playing instead of staying a fixed dark panel.
        .liquidGlass(in: Rectangle(),
                     tint: theme.isDark ? palette.accent.opacity(0.32)
                                        : palette.tint.opacity(0.38))
        .padding(.top, 0)
        .padding(.bottom, 0)
        .task(id: song?.id) {
            await refresh()
        }
    }

    // MARK: Pieces

    private var header: some View {
        // Sits below the window's traffic-light line even though the panel
        // itself runs to the top edge.
        HStack(spacing: 6) {
            Text(l10n.t(.nowPlaying).uppercased())
                .font(BitFont.font(.medium, 10))
                .tracking(1.0)
                // Same ink as the lyrics: it follows the artwork's brightness.
                .foregroundStyle(ink.opacity(0.8))
            Spacer(minLength: 0)

            Button { model.openPlayer() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(l10n.t(.nowPlaying))

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(l10n.t(.close))
        }
        .padding(.horizontal, margin)
        // Level with the back button of the page beside it, not 40 pt lower.
        .padding(.top, 20)
        .padding(.bottom, 6)
    }

    private func artworkView(side: CGFloat) -> some View {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.colors.surfaceVariant)

                // The sleeve: the clip when the track has one (muted, on the
                // music's clock), the canvas or the cover underneath.
                if let song {
                    // The square holds the cover: the canvas lives in the panel
                    // background, so the artwork is what shows until the clip has
                    // its first frame.
                    ClipSleeve(song: song, side: side, radius: 12, player: player) {
                        if let artwork {
                            Image(nsImage: artwork)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: side, height: side)
                                .clipped()
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: side * 0.22, weight: .light))
                                .foregroundStyle(theme.colors.onSurfaceVariant.opacity(0.6))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if !player.isPlaying {
                    Color.black.opacity(0.32)
                    Image(systemName: "play.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture { model.openPlayer() }
    }

    @ViewBuilder
    private var credits: some View {
        if let song {
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(BitFont.font(.semibold, 19))
                    .tracking(-0.2)
                    .foregroundStyle(ink)
                    .lineLimit(1)
                Button {
                    model.closePlayer()
                    model.openArtist(named: song.artist, matching: song.title)
                } label: {
                    Text(song.artist)
                        .font(BitFont.font(.regular, 14))
                        .foregroundStyle(inkSoft)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Abrir artista")
                StreamQualityBadge(label: player.streamLabel, color: inkSoft)
                    .padding(.top, 1)
                if let album = song.album, !album.isEmpty {
                    Text(album)
                        .font(BitFont.font(.regular, 12))
                        .foregroundStyle(inkSoft.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .padding(.top, 4)
        }
    }

    private var lyrics: some View {
        Group {
            if lyricsStore.isLoading {
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    if let provider = lyricsStore.currentProvider {
                        Text("\(l10n.t(.loadingLyrics)) \(provider)")
                            .font(BitFont.font(.regular, 10))
                            .foregroundStyle(theme.colors.onSurfaceVariant)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if lyricsStore.lyrics.isEmpty {
                VStack(spacing: 8) {
                    Text(lyricsStore.lyrics.instrumental ? l10n.t(.instrumental) : l10n.t(.noLyrics))
                        .font(BitFont.font(.medium, 13))
                        .foregroundStyle(ink.opacity(0.92))
                    Text(lyricsStore.lyrics.instrumental
                         ? "Esta faixa é instrumental."
                         : "Não há letra disponível para esta música.")
                        .font(BitFont.font(.regular, 12))
                        .foregroundStyle(inkSoft)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, margin)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if !lyricsStore.lyrics.synced {
                        Text("Letra sem sincronia com a faixa")
                            .font(BitFont.font(.medium, 10))
                            .foregroundStyle(theme.colors.onSurfaceVariant.opacity(0.8))
                            .padding(.horizontal, 20)
                    }
                    CompactLyrics(
                        lyrics: lyricsStore.lyrics,
                        player: player,
                        theme: theme,
                        ink: ink,
                        backdropIsLight: backdropIsLight
                    )
                }
            }
        }
        .frame(maxHeight: .infinity)
        .padding(.top, 6)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                model.openPlayer(.queue)
            } label: {
                Label(l10n.t(.upNext), systemImage: "list.bullet")
                    .font(BitFont.font(.medium, 12))
                    .foregroundStyle(theme.colors.onSurface)
                    .padding(.horizontal, margin)
                    .frame(height: 34)
                    .background(Capsule().fill(theme.colors.onSurface.opacity(0.08)))
            }
            .buttonStyle(.plain)

            if let song {
                Button {
                    library.toggleFavourite(song)
                } label: {
                    Image(systemName: library.isFavourite(song) ? "star.fill" : "star")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(library.isFavourite(song) ? BitColors.accentRed : theme.colors.onSurface)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(theme.colors.onSurface.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, margin)
        .padding(.vertical, 12)
    }

    // MARK: Data

    private func refresh() async {
        guard let song else {
            canvas = nil
            artwork = nil
            return
        }
        model.loadLyrics(for: song)
        if let url = song.artwork(600) {
            artwork = await ArtworkLoader.shared.image(for: url)
            if let artwork {
                palette = PaletteExtractor.extract(from: artwork, key: url.absoluteString)
            }
        } else {
            artwork = nil
        }
        if settings.canvasEnabled {
            canvas = await CanvasService.shared.clip(for: song)
            if canvas == nil {
                // A single miss used to leave the column without its loop until
                // the next track; give the service a second chance.
                canvas = await CanvasService.shared.clip(for: song)
            }
        } else {
            canvas = nil
        }
    }
}

/// A rectangle with only its leading corners rounded — the shape a panel takes
/// when it is flush with the window's right edge.
struct LeftRoundedRectangle: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + radius),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.maxY),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The rail's lyrics: fewer words on screen than the full player, same
/// behaviour — the sung line lifts, the neighbours fade, a tap seeks.
struct CompactLyrics: View {
    var lyrics: Lyrics
    @ObservedObject var player: PlayerEngine
    var theme: BitTheme
    /// Ink chosen by the column from the artwork's brightness.
    var ink: Color = .white
    var backdropIsLight: Bool = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(lyrics.displayLines) { line in
                        let active = line.index == activeIndex
                        let distance = abs((activeIndex ?? -1) - line.index)
                        Button {
                            player.seek(to: line.start)
                        } label: {
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(BitFont.font(.semibold, 16, for: line.text))
                                .shadow(color: backdropIsLight ? .black.opacity(0.18)
                                                               : .black.opacity(0.45),
                                        radius: 6, y: 1)
                                .lineSpacing(3)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                // The sung line is full ink, the next ones step
                                // back — on a bright sleeve the ink is dark.
                                .foregroundStyle(active ? ink
                                                         : ink.opacity(distance <= 2 ? 0.82 : 0.55))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(line.index)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .onChange(of: activeIndex) { _, index in
                guard let index else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
    }

    private var activeIndex: Int? { lyrics.activeIndex(at: player.currentTime) }
}
