//
//  NowPlayingView.swift
//  BitChord for macOS
//
//  The player sheet: blurred cover backdrop, sleeve, credits, scrubber,
//  transport, lyrics and queue.
//
//  Android counterpart: sharedUi NowPlayingScreen.kt + PlayerLyrics.kt +
//  PlayerQueue.kt + PlayerControls.kt. On a window wider than 900 pt this uses
//  the project's own landscape arrangement (LandscapePlayer.kt): two equal
//  columns, 1100 pt cap, sleeve on the left and the page on the right.
//

import SwiftUI
import AppKit

struct NowPlayingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var player: PlayerEngine
    @ObservedObject var library: LibraryStore
    /// Namespace shared with the pill's thumbnail, for the cover morph.
    var artNamespace: Namespace.ID

    private var theme: BitTheme { settings.theme }

    @State private var palette: ArtworkPalette = .fallback
    @State private var canvas: CanvasClip?
    @State private var draggingArtwork = false
    @State private var showingStats = false

    @Environment(\.l10n) private var l10n

    private var song: Song? { player.current }


    private let headerHeight: CGFloat = 96

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width > 900
            let bodySize = CGSize(
                width: proxy.size.width,
                height: max(200, proxy.size.height - headerHeight)
            )
            ZStack(alignment: .top) {
                // The album art rises underneath the panel: it fades in with the
                // sheet, so the expansion reads as one movement.
                if settings.canvasEnabled, let canvas {
                    ZStack {
                        Color(hex: 0x121212)
                        CanvasVideoView(url: canvas.url)
                        LinearGradient(
                            stops: [
                                .init(color: .black.opacity(0.36), location: 0),
                                .init(color: .black.opacity(0.52), location: 0.55),
                                .init(color: .black.opacity(0.68), location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    }
                    .ignoresSafeArea()
                    .transition(.opacity.animation(.easeInOut(duration: 0.45)))
                } else {
                    // No canvas: the blurred cover, and if even that is missing a
                    // full-bleed gradient in the track's colour — never a flat
                    // panel, and always the whole window.
                    ZStack {
                        LinearGradient(
                            colors: [palette.accent.opacity(theme.isDark ? 0.55 : 0.42),
                                     theme.colors.background],
                            startPoint: .topLeading, endPoint: .bottom
                        )
                        ArtworkBackdrop(url: song?.artwork(256), fallbackPalette: palette)
                    }
                    .ignoresSafeArea()
                }

                VStack(spacing: 0) {
                    header
                        .frame(height: headerHeight, alignment: .top)
                    Group {
                        if wide {
                            wideBody(size: bodySize)
                        } else {
                            narrowBody(size: bodySize)
                        }
                    }
                    .frame(width: proxy.size.width, height: bodySize.height, alignment: .center)
                }
            }
        }
        .ignoresSafeArea()
        .clipped()
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $showingStats) {
            if let song {
                SongStatsSheet(song: song, player: player, theme: theme)
                    .environment(\.l10n, l10n)
            }
        }
        .task(id: song?.id) {
            if let url = song?.artwork(256),
               let image = await ArtworkLoader.shared.image(for: url, pixels: 256) {
                palette = PaletteExtractor.extract(from: image, key: url.absoluteString)
            } else {
                palette = .fallback
            }
            if model.playerTab == .lyrics, let song {
                model.loadLyrics(for: song)
            }
            if settings.canvasEnabled, let song {
                canvas = await CanvasService.shared.clip(for: song)
                if canvas == nil {
                    // One retry: a single network miss used to leave the page
                    // without its motion artwork until the track changed.
                    canvas = await CanvasService.shared.clip(for: song)
                }
            } else {
                canvas = nil
            }
        }
        .onChange(of: model.playerTab) { _, tab in
            if tab == .lyrics, let song { model.loadLyrics(for: song) }
        }
    }

    // MARK: Layouts

    /// Two columns, per the project's landscape player: the sleeve never moves
    /// when the right-hand page turns.
    private func wideBody(size: CGSize) -> some View {
        let gap: CGFloat = size.height < 520 ? 20 : 30
        let contentWidth = min(1100, size.width - gap * 2)
        let columnWidth = (contentWidth - gap) / 2
        let switcherSpace: CGFloat = 44 + 30
        let sleeveSide = max(140, min(columnWidth, size.height - switcherSpace))
        _ = sleeveSide

        return HStack(alignment: .center, spacing: gap) {
            VStack(spacing: 18) {
                Spacer(minLength: 0)
                sleeve(size: sleeveSide)
                pageSwitcher(isWide: true)
                Spacer(minLength: 0)
            }
            .frame(width: columnWidth, height: size.height, alignment: .center)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                pageContent
                Spacer(minLength: 0)
            }
            .frame(width: columnWidth, height: size.height, alignment: .center)
        }
        .frame(width: contentWidth, height: size.height, alignment: .center)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .clipped()
        .padding(.bottom, 16)
    }

    private func narrowBody(size: CGSize) -> some View {
        let sleeveSide = max(140, min(size.width - 60, size.height - 250))
        return VStack(spacing: 0) {
            Spacer(minLength: 8)
            sleeve(size: sleeveSide)
            pageContent
                .frame(maxWidth: min(560, size.width - 60))
                .frame(maxHeight: .infinity)
            pageSwitcher(isWide: false)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch model.playerTab {
        case .nowPlaying:
            creditsAndTransport
        case .lyrics:
            LyricsPanel(model: model, player: player, palette: palette, wide: true)
        case .queue:
            QueuePanel(model: model, player: player, palette: palette)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Button { model.closePlayer() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close player")

            Spacer(minLength: 0)

            VStack(spacing: 2) {
                Text(l10n.t(.playingFrom))
                    .font(BitFont.font(.medium, 10))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.55))
                Text(player.playingSource ?? l10n.t(.youtubeMusic))
                    .font(BitFont.font(.medium, 12))
                    .foregroundStyle(.white.opacity(0.85))
            }

            Spacer(minLength: 0)

            Menu {
                if let song {
                    Button(library.isFavourite(song) ? "Remove from favourites" : "Add to favourites") {
                        library.toggleFavourite(song)
                    }
                    Button("Play next") { player.playNext(song) }
                    Button("Add to queue") { player.addToQueue(song) }
                    if DownloadStore.shared.isDownloaded(song) {
                        Button("Remove download") { DownloadStore.shared.remove(song) }
                    } else {
                        Button("Download") {
                            DownloadStore.shared.download(song, highQuality: settings.audioQuality == .high)
                        }
                    }
                    if let url = song.artwork(600) {
                        Button("Open artwork") { NSWorkspace.shared.open(url) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 44, height: 44)
        }
        .padding(.horizontal, 14)
        .padding(.top, 30)
        .frame(maxHeight: .infinity, alignment: .center)
        .overlay(alignment: .top) {
            #if !SNAPSHOT
            WindowDragArea().frame(height: 34)
            #endif
        }
    }

    // MARK: Sleeve

    private func sleeve(size: CGFloat) -> some View {
        let side = max(54, size)
        return AnyView(ZStack {
            if let song {
                // Same sleeve rule as the column: the clip when there is one,
                // the cover otherwise.
                ClipSleeve(song: song, side: side, radius: 8, player: player,
                           artNamespace: artNamespace, isSource: model.isPlayerOpen) {
                    Group {
                        if let url = song.artwork(Int(side * 2)) {
                            CoverArt(url: url, size: side, radius: 8,
                                     theme: BitTheme(colors: .dark, isDark: true))
                        } else {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.black.opacity(0.18))
                                .overlay {
                                    Image(systemName: "music.note")
                                        .font(.system(size: 40, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.35))
                                }
                        }
                    }
                }
                .shadow(color: .black.opacity(0.55), radius: 22, y: 10)
            }
        }
        .frame(width: side, height: side)
        .scaleEffect(player.isPlaying ? 1 : 0.86)
        .animation(.spring(response: 0.55, dampingFraction: 0.72), value: player.isPlaying)
        .offset(x: draggingArtwork ? 0 : 0)
        .gesture(
            DragGesture(minimumDistance: 24)
                .onChanged { _ in draggingArtwork = true }
                .onEnded { value in
                    draggingArtwork = false
                    if value.translation.width < -72 { player.next(userInitiated: true) }
                    if value.translation.width > 72 { player.previous() }
                }
        )
        .help(song?.title ?? ""))
    }

    // MARK: Credits + transport

    private var creditsAndTransport: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let song {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title)
                            .font(BitFont.font(.semibold, 20))
                            .tracking(-0.2)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Button {
                            // From the big player: shrink it, then go.
                            model.closePlayer()
                            model.openArtist(named: song.artist, matching: song.title)
                        } label: {
                            Text(song.artist)
                                .font(BitFont.font(.regular, 20))
                                .tracking(-0.1)
                                .foregroundStyle(palette.tint.opacity(0.9))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .help("Abrir artista")
                        if let label = player.streamLabel {
                            Text(label)
                                .font(BitFont.font(.regular, 11))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { showingStats = true } label: {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 40, height: 40)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Estatísticas da música")
                    .padding(.trailing, 4)

                    Button {
                        library.toggleFavourite(song)
                    } label: {
                        Image(systemName: library.isFavourite(song) ? "star.fill" : "star")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(.white.opacity(library.isFavourite(song) ? 0.95 : 0.7))
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.white.opacity(library.isFavourite(song) ? 0.20 : 0.10)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(library.isFavourite(song) ? "Remove from favourites" : "Add to favourites")
                }
                .frame(minHeight: 60)
            }

            Scrubber(player: player, tint: .white, sourceLabel: player.streamLabel)
                .padding(.top, 6)

            TransportRow(player: player, model: model)
                .padding(.top, 14)

            if let error = player.errorMessage {
                Text(error)
                    .bitStyle(.labelMedium)
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.top, 10)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Page switcher

    private func pageSwitcher(isWide: Bool) -> some View {
        HStack(spacing: 12) {
            glyphButton("quote.bubble", active: model.playerTab == .lyrics, help: "Lyrics") {
                toggle(.lyrics)
            }
            Spacer(minLength: 0)
            Capsule()
                .fill(Color.white.opacity(0.12))
                .frame(width: isWide ? 150 : 130, height: 44)
                .overlay {
                    HStack(spacing: 0) {
                        segment("shuffle", active: player.isShuffled) { player.toggleShuffle() }
                        Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1, height: 20)
                        segment(player.repeatMode == .one ? "repeat.1" : "repeat",
                                active: player.repeatMode != .off) {
                            player.repeatMode = player.repeatMode == .one ? .off
                                : (player.repeatMode == .off ? .all : .one)
                        }
                    }
                }
            Spacer(minLength: 0)
            glyphButton("list.bullet", active: model.playerTab == .queue, help: "Up Next") {
                toggle(.queue)
            }
        }
        .padding(.horizontal, 4)
    }

    private func toggle(_ tab: PlayerTab) {
        withAnimation(.easeInOut(duration: 0.22)) {
            model.playerTab = model.playerTab == tab ? .nowPlaying : tab
        }
    }

    private func glyphButton(_ name: String, active: Bool, help: String,
                             enabled: Bool = true,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? (active ? 1 : 0.75) : 0.28))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    private func segment(_ name: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(active ? 1 : 0.7))
                .frame(width: 64, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Backdrop

/// The shipping backdrop: the cover blurred hard, under a three-stop black
/// scrim. Deliberately not the mesh gradient, which is a legacy opt-in on the
/// phone too.
struct ArtworkBackdrop: View {
    var url: URL?
    var fallbackPalette: ArtworkPalette

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color(hex: 0x121212)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(1.25)
                    .blur(radius: 80, opaque: true)
                    .brightness(-0.08)
                    .transition(.opacity.animation(.easeInOut(duration: 0.32)))
            } else {
                LinearGradient(
                    colors: [fallbackPalette.colors[0].opacity(0.45), Color(hex: 0x121212)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.34), location: 0),
                    .init(color: .black.opacity(0.48), location: 0.55),
                    .init(color: .black.opacity(0.64), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .task(id: url) {
            guard let url else { return }
            let loaded = await ArtworkLoader.shared.image(for: url)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.32)) { image = loaded }
            }
        }
    }
}

// MARK: - Scrubber

/// The phone's `ThinSlider`: a capsule with no thumb, 7 pt at rest and 12 pt
/// while dragging, and its times pulled up into the touch area.
struct Scrubber: View {
    @ObservedObject var player: PlayerEngine
    var tint: Color
    /// What is making the sound right now; falls back to the player's own label.
    var sourceLabel: String? = nil

    @State private var dragging = false
    @State private var dragFraction: Double = 0
    @State private var hovering = false

    private var fraction: Double { dragging ? dragFraction : player.progress }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let height: CGFloat = dragging ? 12 : (hovering ? 9 : 7)
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.26))
                    Capsule()
                        .fill(tint.opacity(0.92))
                        .frame(width: max(height, width * fraction))
                }
                .frame(height: height)
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragging = true
                            dragFraction = min(1, max(0, value.location.x / max(width, 1)))
                        }
                        .onEnded { value in
                            let target = min(1, max(0, value.location.x / max(width, 1)))
                            player.seek(to: target * player.duration)
                            dragging = false
                        }
                )
                .onHover { hovering = $0 }
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragging)
            }
            .frame(height: 22)

            HStack {
                Text(TimeFormat.playback(dragging ? dragFraction * player.duration : player.currentTime))
                Spacer(minLength: 6)
                StreamQualityBadge(label: sourceLabel ?? player.streamLabel, color: .white)
                Spacer(minLength: 6)
                Text("-" + TimeFormat.playback(max(0, player.duration - (dragging ? dragFraction * player.duration : player.currentTime))))
            }
            .font(BitFont.font(.medium, 12))
            .monospacedDigit()
            .foregroundStyle(tint.opacity(0.55))
        }
    }
}

// MARK: - Transport

struct TransportRow: View {
    @ObservedObject var player: PlayerEngine
    var model: AppModel

    var body: some View {
        HStack(spacing: 34) {
            Spacer(minLength: 0)
            Button { player.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 30, weight: .regular))
                    .scaleEffect(x: 1, y: 0.85)
                    .foregroundStyle(.white)
                    .frame(width: 53, height: 53)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Previous")

            Button { player.togglePlayPause() } label: {
                ZStack {
                    if player.isLoading {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 56, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 92, height: 92)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(player.isPlaying ? "Pause" : "Play")

            Button { player.next(userInitiated: true) } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 30, weight: .regular))
                    .scaleEffect(x: 1, y: 0.85)
                    .foregroundStyle(.white)
                    .frame(width: 53, height: 53)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Next")
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Lyrics

struct LyricsPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlayerEngine
    var palette: ArtworkPalette
    var wide: Bool

    @Environment(\.l10n) private var l10n
    @State private var browsing = false

    private var lyrics: Lyrics { model.lyrics.lyrics }
    private var activeIndex: Int? { lyrics.activeIndex(at: player.currentTime) }

    var body: some View {
        Group {
            if model.lyrics.isLoading {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(.white)
                    if let provider = model.lyrics.currentProvider {
                        Text("\(l10n.t(.loadingLyrics)) \(provider)")
                            .font(BitFont.font(.regular, 11))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if lyrics.instrumental {
                message(l10n.t(.instrumental), l10n.t(.noLyricsHint))
            } else if lyrics.isEmpty {
                VStack(spacing: 10) {
                    message(l10n.t(.noLyrics), l10n.t(.noLyricsHint))
                    Button {
                        if let song = player.current { model.loadLyrics(for: song, force: true) }
                    } label: {
                        Text(l10n.t(.tryAgain))
                            .font(BitFont.font(.medium, 13))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Capsule().fill(.white))
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if lyrics.synced {
                syncedLines
            } else {
                ScrollView {
                    Text(lyrics.plain ?? "")
                        .font(BitFont.font(.semibold, wide ? 28 : 22, for: lyrics.plain ?? ""))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineSpacing(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 20)
                }
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
        .overlay(alignment: .bottomTrailing) {
            if !lyrics.isEmpty {
                Text("\(l10n.t(.lyricsBy)) · \(lyrics.source)")
                    .font(BitFont.font(.medium, 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(8)
            }
        }
    }

    private var syncedLines: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: wide ? 18 : 14) {
                    ForEach(lyrics.displayLines) { line in
                        let distance = abs((activeIndex ?? -1) - line.index)
                        Button {
                            player.seek(to: line.start)
                        } label: {
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(BitFont.font(.bold, wide ? 32 : 26, for: line.text))
                                .foregroundStyle(lineColor(distance, isActive: line.index == activeIndex))
                                .blur(radius: blurRadius(distance))
                                .scaleEffect(line.index == activeIndex ? 1 : 0.98, anchor: .leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(line.index)
                    }
                }
                .padding(.vertical, 18)
            }
            .onChange(of: activeIndex) { _, index in
                guard !browsing, let index else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
            .simultaneousGesture(
                DragGesture().onChanged { _ in browsing = true }
                    .onEnded { _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { browsing = false }
                    }
            )
        }
    }

    private func lineColor(_ distance: Int, isActive: Bool) -> Color {
        if browsing { return .white.opacity(0.8) }
        let alpha: Double
        switch distance {
        case 0: alpha = 1.0
        case 1: alpha = 0.80
        case 2: alpha = 0.70
        case 3: alpha = 0.58
        case 4: alpha = 0.46
        default: alpha = 0.46
        }
        return isActive ? .white : .white.opacity(alpha)
    }

    private func blurRadius(_ distance: Int) -> CGFloat {
        if browsing { return 0 }
        switch distance {
        case 0: return 0
        case 1, 2: return 0.6
        case 3: return 1.2
        default: return 1.8
        }
    }

    private func message(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(BitFont.font(.semibold, 22))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(BitFont.font(.regular, 14))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 30)
    }
}

// MARK: - Queue

struct QueuePanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlayerEngine
    var palette: ArtworkPalette

    @Environment(\.l10n) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(l10n.t(.queue))
                    .font(BitFont.font(.semibold, 20))
                    .tracking(-0.2)
                    .foregroundStyle(.white)
                Spacer()
                if !player.manualQueue.isEmpty {
                    Button("Clear") {
                        for song in player.manualQueue { player.addToQueue(song) }
                    }
                    .buttonStyle(.plain)
                    .font(BitFont.font(.regular, 15))
                    .foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(.vertical, 10)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let current = player.current {
                        sectionHeader(l10n.t(.currentPlaying))
                        queueRow(current, isCurrent: true)
                    }
                    if !player.manualQueue.isEmpty {
                        sectionHeader(l10n.t(.nextInQueue))
                        ForEach(player.manualQueue) { song in
                            queueRow(song, isCurrent: false)
                        }
                    }
                    let upcoming = upcomingSongs
                    if !upcoming.isEmpty {
                        sectionHeader(l10n.t(.nextFromYouTube))
                        ForEach(upcoming) { song in
                            queueRow(song, isCurrent: false)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
        }
    }

    private var upcomingSongs: [Song] {
        guard player.index + 1 < player.queue.count else { return [] }
        return Array(player.queue[(player.index + 1)...]).prefix(60).map { $0 }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(BitFont.font(.medium, 14))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    private func queueRow(_ song: Song, isCurrent: Bool) -> some View {
        HStack(spacing: 12) {
            CoverArt(url: song.artwork(88), size: 44, radius: 6, theme: BitTheme(colors: .dark, isDark: true))
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title)
                    .font(BitFont.font(.medium, 15))
                    .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.92))
                    .lineLimit(1)
                Text(song.artist)
                    .font(BitFont.font(.regular, 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if isCurrent {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(song.durationText)
                .font(BitFont.font(.medium, 12))
                .foregroundStyle(.white.opacity(0.45))
                .monospacedDigit()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrent ? Color.white.opacity(0.06) : .clear)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isCurrent { player.resume() } else { player.play(song) }
        }
    }
}
