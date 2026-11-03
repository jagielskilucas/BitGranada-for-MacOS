//
//  ShellView.swift
//  BitChord for macOS
//
//  The window: page content under a floating top bar, the now-playing column on
//  the right, the mini player and the floating tab bar at the bottom, and the
//  player sheet over all of it.
//
//  Android counterpart: MainActivity's Box (MA:2749-4202) — the same z-order,
//  the same 440 pt cap on the bar, the same 8 pt gap between the bars.
//

import SwiftUI
import UniformTypeIdentifiers

struct ShellView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var player: PlayerEngine
    @ObservedObject var library: LibraryStore

    @Environment(\.l10n) private var inheritedL10n
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var isDropTarget = false
    @Namespace private var dockNamespace
    /// Shared between the pill's thumbnail and the player's sleeve, so the cover
    /// morphs instead of disappearing and reappearing.
    @Namespace private var artNamespace
    /// Observed so the page and the player overlay can follow the gesture.
    @ObservedObject private var gestures = TrackpadGestures.shared


    /// Follows the system when the theme is "Sistema" — reading
    /// `colorScheme` here is what makes SwiftUI re-render on a macOS
    /// appearance change instead of keeping the palette it booted with.
    private var theme: BitTheme {
        guard settings.appearance == .system else { return settings.theme }
        let dark = systemColorScheme == .dark
        return BitTheme(colors: dark ? .dark : .light, isDark: dark)
    }
    private var l10n: L10n { L10n(language: L10n.resolved(settings.language)) }

    @State private var trackPalette: ArtworkPalette?
    private var paletteKey: String { player.current?.id ?? "none" }

    var body: some View {
        ZStack {
            // Paints every pixel of the window, safe-area insets included, so
            // no strip at the top or bottom is left to the window's own
            // background colour.
            theme.colors.background.ignoresSafeArea()

            // A fade of the playing track's own colour, the way the artist page
            // tints itself: strong at the top, gone by the middle.
            // The tint lives in its own stack: the crossfade needs the incoming
            // layer above the outgoing one, and that z-order must not leak to the
            // interface — it was painting over the logo and the round buttons.
            ZStack {
                if let palette = trackPalette {
                    LinearGradient(
                        stops: [
                            .init(color: palette.accent.opacity(theme.isDark ? 0.30 : 0.20), location: 0),
                            .init(color: palette.accent.opacity(theme.isDark ? 0.18 : 0.12), location: 0.28),
                            .init(color: palette.accent.opacity(theme.isDark ? 0.08 : 0.05), location: 0.55),
                            .init(color: .clear, location: 0.82),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                    .id(paletteKey)
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            GeometryReader { proxy in
            let railWidth: CGFloat = 330
            let showRail = model.isRailVisible
                && settings.showNowPlayingRail
                && player.current != nil
                && !model.isPlayerOpen
                && proxy.size.width >= 1120
            let contentWidth = max(320, proxy.size.width - (showRail ? railWidth : 0))

            HStack(spacing: 0) {
                ZStack(alignment: .top) {
                    // Transparent here: the window already paints the base colour
                    // and the track's fade, and an opaque layer hid both.
                    Color.clear

                    pageContent
                        .frame(width: contentWidth, height: proxy.size.height)
                        .clipped()
                        // Follows the fingers while the back gesture runs.
                        .offset(x: gestures.backProgress * 90)
                        .opacity(1 - Double(gestures.backProgress) * 0.25)
                        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.86),
                                   value: gestures.backProgress)

                    topBar(railVisible: showRail, width: contentWidth)
                        .frame(width: contentWidth)
                        .zIndex(2)

                    // A fade behind the bars: the shelf artwork slides under
                    // them, and without it the labels fight the covers.
                    // Half strength at most: enough to lift the bars off the
                    // artwork without blacking the shelf covers out behind them.
                    LinearGradient(
                        stops: [
                            .init(color: theme.colors.background.opacity(0), location: 0),
                            .init(color: theme.colors.background.opacity(0.18), location: 0.45),
                            .init(color: theme.colors.background.opacity(0.36), location: 0.78),
                            .init(color: theme.colors.background.opacity(0.5), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                    // The track's own colour replaces this veil while it is on.
                    .opacity(trackPalette == nil ? 1 : 0)
                    .animation(.easeInOut(duration: 0.45), value: trackPalette == nil)
                    .frame(height: 210)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
                    .zIndex(2)

                    // The bars live inside the content column, so an open
                    // lyrics column keeps the full height on the right.
                    VStack(spacing: 6) {
                        Spacer(minLength: 0)
                        // Only the compact dock exists now: the round tabs and
                        // the player pill, with no wide menu under them.
                        if player.current != nil {
                            HStack(spacing: 9) {
                                DockCircleButton(systemName: Tab.home.icon, theme: theme) {
                                    model.select(.home)
                                }
                                MiniPlayerView(expanded: false, artNamespace: artNamespace,
                                               model: model, settings: settings,
                                               player: player, library: library)
                                    .matchedGeometryEffect(id: "playerBar", in: dockNamespace)
                                ForEach([Tab.explore, .library, .search], id: \.self) { tab in
                                    DockCircleButton(systemName: tab.icon, theme: theme) {
                                        model.select(tab)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .transition(.opacity)
                        } else {
                            // Nothing playing: the dock has no pill to show, so
                            // the wide menu comes back on its own.
                            LiquidGlassContainer(spacing: 8) {
                                FloatingTabBar(model: model, theme: theme, settings: settings)
                            }
                            .padding(.bottom, 2)
                            .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 16)
                    .zIndex(3)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: player.current?.id)
                }
                .frame(width: contentWidth)

                if showRail {
                    NowPlayingRail(
                        model: model,
                        settings: settings,
                        player: player,
                        library: library,
                        lyricsStore: model.lyrics,
                        width: railWidth
                    ) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                            model.isRailVisible = false
                        }
                    }
                    .frame(width: railWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.86), value: showRail)
            }
            .ignoresSafeArea()
        }
        .environment(\.bit, theme)
        .environment(\.l10n, l10n)
        .task(id: player.current?.id) {
            guard let song = player.current, let url = song.artwork(400) else {
                // Clearing is a transition too: animate it, or the background
                // snaps back to the plain theme colour.
                withAnimation(.easeInOut(duration: 0.5)) { trackPalette = nil }
                return
            }
            guard let art = await ArtworkLoader.shared.image(for: url) else {
                withAnimation(.easeInOut(duration: 0.5)) { trackPalette = nil }
                return
            }
            let next = PaletteExtractor.extract(from: art, key: url.absoluteString)
            // The crossfade: the new gradient is inserted while the previous one
            // is still on screen, and the two dissolve into each other.
            withAnimation(.easeInOut(duration: 0.5)) { trackPalette = next }
        }
        .onAppear {
            // Trackpad: a swipe from the left edge goes back, a downward swipe
            // over the player dismisses it.
            TrackpadGestures.shared.onBack = { [weak model] in model?.pop() }
            TrackpadGestures.shared.onDismissPlayer = { [weak model] in model?.closePlayer() }
            TrackpadGestures.shared.isPlayerOpen = model.isPlayerOpen
            TrackpadGestures.shared.start()
        }
        .onChange(of: model.isPlayerOpen) { _, open in
            TrackpadGestures.shared.isPlayerOpen = open
        }
        .overlay {
            // Mounted as soon as there is something to play, and only moved by
            // state afterwards: the slide is a pure transform, so every opening
            // animates the same way instead of landing on its final frame.
            if player.current != nil {
                PlayerSheet(isOpen: model.isPlayerOpen,
                            dismissProgress: gestures.dismissProgress) {
                    ZStack {
                        theme.colors.background
                        if let accent = trackPalette?.accent {
                            accent.opacity(theme.isDark ? 0.55 : 0.35)
                        }
                        NowPlayingView(model: model, settings: settings,
                                       player: player, library: library,
                                       artNamespace: artNamespace)
                            .environment(\.bit, theme)
                            .environment(\.l10n, l10n)
                    }
                }
            }
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.black.opacity(0.45))
                    )
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.down.on.square")
                                .font(.system(size: 30, weight: .light))
                            Text("Solte o backup do BitChord para importar")
                                .font(BitFont.font(.medium, 14))
                        }
                        .foregroundStyle(.white)
                    }
                    .padding(24)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Dragging the Android backup JSON onto the window imports it, the same
    /// path as Settings → Backup and Replay → Importar backup.
    private func importDroppedBackup(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension.lowercased() == "json" else { return }
            Task { @MainActor in
                guard let object = try? BackupImporter.read(from: url) else { return }
                model.lastBackupReport = BackupImporter.apply(object, settings: settings, library: library)
                model.push(.replay)
            }
        }
        return true
    }

    // MARK: Pages

    @ViewBuilder
    private var pageContent: some View {
        ZStack {
            if let route = model.path.last {
                routeView(route)
                    .id(route.id)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            } else {
                tabView
                    .id(model.tab)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.path.last?.id)
        .animation(.easeInOut(duration: 0.18), value: model.tab)
    }

    @ViewBuilder
    private var tabView: some View {
        switch model.tab {
        case .home:
            HomeView(model: model, library: library, theme: theme)
        case .explore:
            ExploreView(model: model, theme: theme)
        case .library:
            LibraryView(model: model, library: library, theme: theme)
        case .search:
            SearchView(model: model, library: library, theme: theme)
        }
    }

    @ViewBuilder
    private func routeView(_ route: Route) -> some View {
        switch route {
        case .release(let kind, let browseId, let title, let subtitle, let thumbnail):
            ReleaseView(
                model: model,
                library: library,
                theme: theme,
                kind: kind,
                browseId: browseId,
                fallbackTitle: title,
                fallbackSubtitle: subtitle,
                fallbackThumbnail: thumbnail
            )
        case .localPlaylist(let id):
            LocalPlaylistView(model: model, library: library, theme: theme, playlistID: id)
        case .moods:
            MoodsGridView(model: model, theme: theme)
        case .mood(let browseId, let params, let title):
            MoodView(model: model, theme: theme, browseId: browseId, params: params, title: title)
        case .settings:
            SettingsView(model: model, settings: settings, library: library, theme: theme)
        case .downloads:
            DownloadsView(model: model, settings: settings, library: library, theme: theme)
        case .replay:
            ReplayView(model: model, library: library, theme: theme)
        }
    }

    // MARK: Top bar

    /// True while an artist page is on the stack: those pages show their
    /// photograph edge to edge, so the scrim above them would only darken it.
    private var isArtistPage: Bool {
        for route in model.path.reversed() {
            if case .release(let kind, _, _, _, _) = route { return kind == .artist }
        }
        return false
    }

    private func topBar(railVisible: Bool, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            // The same frost everywhere, but an artist page opens on a hero
            // image: there it keeps a whisper of tint and a longer fade, so the
            // portrait is not cut by a band.
            FrostBand(tintOpacity: isArtistPage ? 0.08 : (theme.isDark ? 0.28 : 0.18))
                .mask(
                    LinearGradient(
                        stops: isArtistPage
                            ? [.init(color: .white.opacity(0.55), location: 0),
                               .init(color: .white.opacity(0.32), location: 0.45),
                               .init(color: .white.opacity(0.10), location: 0.75),
                               .init(color: .clear, location: 1)]
                            : [.init(color: .white, location: 0),
                               .init(color: .white.opacity(0.88), location: 0.5),
                               .init(color: .white.opacity(0.4), location: 0.8),
                               .init(color: .clear, location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            .frame(height: 122)
            .allowsHitTesting(false)
            .overlay(alignment: .top) {
                HStack(spacing: 8) {
                    if model.path.isEmpty && model.tab == .home {
                        Wordmark(height: 26, color: theme.colors.onSurface)
                            .padding(.leading, 20)
                            .allowsHitTesting(false)
                    }
                    if !model.path.isEmpty {
                        GlassCircleButton(systemName: "chevron.left", size: 27, glyph: 11, theme: theme) {
                            model.pop()
                        }
                        .padding(.leading, 8)
                    }

                    if model.tab == .search && model.path.isEmpty {
                        // The 1.9 search screen: one wide field across the
                        // window, the actions pushed to the far right.
                        SearchField(
                            text: $model.query,
                            theme: theme,
                            placeholder: l10n.t(.searchPlaceholder),
                            onSubmit: { model.searchNow() },
                            onClear: { model.clearSearch() }
                        )
                        .frame(maxWidth: .infinity)
                    } else {
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 6) {
                        if player.current != nil {
                            GlassCircleButton(
                                systemName: railVisible ? "sidebar.right" : "sidebar.trailing",
                                size: 27, glyph: 10, theme: theme
                            ) {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                                    model.isRailVisible.toggle()
                                }
                            }
                            .help(l10n.t(.nowPlaying))

                            GlassCircleButton(systemName: "list.bullet", size: 27, glyph: 10, theme: theme,
                                              help: l10n.t(.queue)) {
                                model.openPlayer(.queue)
                            }
                        }
                        GlassCircleButton(systemName: "gearshape", size: 27, glyph: 11, theme: theme,
                                          help: l10n.t(.settings)) {
                            model.push(.settings)
                        }
                    }
                }
                .padding(.horizontal, 20)
                // Always clear of the traffic lights: the content column starts
                // at the window's left edge, so raising this row any further
                // puts the back button under them.
                .padding(.top, 46)
                .frame(maxWidth: .infinity)
            }
            .overlay(alignment: .top) {
                #if !SNAPSHOT
                WindowDragArea().frame(height: 44)
                #endif
            }
        }
    }
}

// MARK: - Floating tab bar

/// The four-tab floating bar: a 440 pt capsule with a sliding 14 % indicator.
struct FloatingTabBar: View {
    @ObservedObject var model: AppModel
    var theme: BitTheme
    @ObservedObject var settings: AppSettings

    @Namespace private var indicator
    @Environment(\.l10n) private var l10n

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(4)
        .frame(width: 440, height: BitMetrics.tabBarHeight)
        .liquidGlass(in: Capsule(), tint: theme.isDark ? .black.opacity(0.66) : .white.opacity(0.26), interactive: true)
        .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.12), radius: 20, y: 8)
    }

    private func tabButton(_ tab: Tab) -> some View {
        let selected = model.tab == tab
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.76)) {
                model.select(tab)
            }
        } label: {
            VStack(spacing: 1) {
                Image(systemName: tab.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(height: 26)
                Text(l10n.t(tab.labelKey))
                    .font(BitFont.font(.medium, 10))
                    .tracking(0.5)
            }
            .foregroundStyle(selected ? theme.colors.onSurface : theme.colors.onSurfaceVariant)
            .frame(maxWidth: .infinity)
            .frame(height: BitMetrics.tabBarHeight - 8)
            .background {
                if selected {
                    Capsule()
                        .fill(theme.isDark ? Color.white.opacity(0.22) : Color.black.opacity(0.10))
                        .overlay {
                            Capsule().strokeBorder(Color.white.opacity(theme.isDark ? 0.18 : 0.0), lineWidth: 0.5)
                        }
                        .matchedGeometryEffect(id: "selection", in: indicator)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One of the two round buttons flanking the collapsed player.
struct DockCircleButton: View {
    var systemName: String
    var theme: BitTheme
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.colors.onSurface)
                .frame(width: 58, height: 58)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .liquidGlass(in: Circle(), tint: theme.isDark ? .black.opacity(0.5) : .white.opacity(0.22), interactive: true)
        .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.10), radius: 14, y: 6)
        .scaleEffect(hovering ? 1.04 : 1)
        .onHover { hovering = $0 }
    }
}

// MARK: - Search field

/// The 44 pt squircle search field the phone puts in its top bar.
struct SearchField: View {
    @Binding var text: String
    var theme: BitTheme
    var placeholder: String
    var onSubmit: () -> Void
    var onClear: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Button {
                onSubmit()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.colors.onSurfaceVariant)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(BitFont.font(.regular, 16))
                .foregroundStyle(theme.colors.onSurface)
                .focused($focused)
                .onSubmit(onSubmit)

            if !text.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.colors.onSurfaceVariant)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(height: 46)
        .background {
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .fill(theme.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .strokeBorder(
                    focused ? theme.colors.onSurface.opacity(0.25) : Color.white.opacity(theme.isDark ? 0.08 : 0),
                    lineWidth: 0.5
                )
        }
    }
}

// MARK: - Mini player

/// The player bar above the tab bar — Apple Music's arrangement: transport on
/// the left, credits in the middle, the listening controls on the right, and a
/// hairline of progress along the bottom edge.
struct MiniPlayerView: View {
    /// Whether the bar is in its large form. Passed in because the shell owns
    /// the rule (the full bar belongs to Home), and the bar must not disagree.
    var expanded: Bool = false
    var artNamespace: Namespace.ID
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var player: PlayerEngine
    @ObservedObject var library: LibraryStore

    /// Follows the system when the theme is "Sistema" — reading
    /// `colorScheme` here is what makes SwiftUI re-render on a macOS
    /// appearance change instead of keeping the palette it booted with.
    private var theme: BitTheme {
        guard settings.appearance == .system else { return settings.theme }
        let dark = systemColorScheme == .dark
        return BitTheme(colors: dark ? .dark : .light, isDark: dark)
    }
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var hovering = false
    @State private var hoveringScrubber = false
    @State private var scrubbing = false
    @Environment(\.l10n) private var l10n

    var body: some View {
        if let song = player.current {
            GeometryReader { proxy in
            let wide = proxy.size.width >= 1040
            let medium = proxy.size.width >= 860

            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    transport(compact: !medium)

                HStack(spacing: expanded ? 12 : 9) {
                    // The artwork and the title open the player; the artist
                    // line is its own target and goes straight to the artist.
                    Button { model.openPlayer() } label: {
                        CoverArt(url: song.artwork(160),
                                 size: expanded ? 54 : 34,
                                 radius: expanded ? 9 : 6,
                                 theme: theme)
                            .matchedGeometryEffect(id: "playerArt", in: artNamespace,
                                                   isSource: !model.isPlayerOpen)
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 7) {
                        Button { model.openPlayer() } label: {
                            Text(song.title)
                                .font(BitFont.font(.medium, expanded ? 15 : 13))
                                .foregroundStyle(theme.colors.onSurface)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)

                        // Time beside the title, on its line, centred with it.
                        Text("\(Self.dockTime(player.currentTime)) / -\(Self.dockTime(max(0, player.duration - player.currentTime)))")
                            .font(BitFont.font(.medium, 9))
                            .monospacedDigit()
                            .foregroundStyle(theme.colors.onSurfaceVariant.opacity(0.85))
                        }

                        Button {
                            model.closePlayer()
                            model.openArtist(named: song.artist, matching: song.title)
                        } label: {
                            Text(shortArtist(song))
                                .font(BitFont.font(.regular, expanded ? 12 : 11))
                                .foregroundStyle(theme.colors.onSurfaceVariant)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .help("Abrir artista")

                        // The quality badge lives in the side column now: on the
                        // bar it made a compact row taller than it needs to be.

                    }
                }

                Spacer(minLength: 8)

                    rightControls(song, showVolume: wide)
                }
            }
            .padding(.horizontal, expanded ? 18 : 14)
            .padding(.top, 13)
            .padding(.bottom, 7)
            .frame(height: expanded ? 84 : 58)
            // Same liquid glass as the round dock buttons: the pill was the only
            // surface still using a plain material.
            .liquidGlass(in: Capsule(),
                         tint: theme.isDark ? .black.opacity(0.5) : .white.opacity(0.22),
                         interactive: true)
            // The progress line touches the top edge, as in the wireframe; the
            // capsule's own curve is what trims it at the corners — so the clip
            // has to come *after* the overlay, or the line paints outside it.
            .overlay(alignment: .top) {
                scrubberRow
                    // Flush with the top edge, inset by the capsule's radius so
                    // the line starts where the curve ends — the wireframe's
                    // proportion.
                    .padding(.horizontal, 30)
                    .padding(.top, 1)
            }
            .clipShape(Capsule())
            .shadow(color: .black.opacity(theme.isDark ? 0.45 : 0.14), radius: 20, y: 9)
            .onHover { hovering = $0 }
            }
            .frame(height: expanded ? 84 : 58)
        }
    }

    /// The progress line: the pill's first row, draggable end to end, with a
    /// knob at the playhead as in the bar's wireframe.
    private var scrubberRow: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let played = width * min(1, max(0, player.progress))
            ZStack(alignment: .leading) {
                // The remaining stretch has to read as the same bar, not as an
                // invisible gap: at low opacity the track looked like it stopped
                // where the fill ended.
                Capsule()
                    .fill(theme.colors.onSurface.opacity(theme.isDark ? 0.30 : 0.22))
                    .frame(height: 4)
                Capsule()
                    .stroke(theme.colors.onSurface.opacity(theme.isDark ? 0.18 : 0.14), lineWidth: 0.5)
                    .frame(height: 4)
                Capsule()
                    .fill(theme.colors.onSurface.opacity(0.95))
                    .frame(width: played, height: 4)
                Circle()
                    .fill(theme.colors.onSurface)
                    .frame(width: 7, height: 7)
                    // The knob only exists while the controller is in use: it
                    // fades in with the pointer and grows while dragging, so the
                    // bar stays clean at rest.
                    .scaleEffect(scrubbing ? 1.45 : (hoveringScrubber ? 1.15 : 1))
                    .opacity(scrubbing || hoveringScrubber || hovering ? 1 : 0)
                    .shadow(color: .black.opacity(scrubbing ? 0.35 : 0), radius: scrubbing ? 5 : 0)
                    .offset(x: max(0, played - 3.5))
                    .animation(.spring(response: 0.26, dampingFraction: 0.7), value: scrubbing)
                    .animation(.spring(response: 0.26, dampingFraction: 0.72), value: hoveringScrubber)
                    .animation(.easeInOut(duration: 0.2), value: hovering)
            }
            .frame(width: width, height: 12)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active: hoveringScrubber = true
                case .ended: hoveringScrubber = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !scrubbing {
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.65)) { scrubbing = true }
                        }
                        let fraction = min(1, max(0, value.location.x / max(1, width)))
                        player.seek(to: player.duration * fraction)
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { scrubbing = false }
                    }
            )
        }
        .frame(height: 12)
    }

    private static func dockTime(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func transport(compact: Bool) -> some View {
        HStack(spacing: 10) {
            if !compact && model.isPlayerBarExpanded {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(player.isShuffled ? theme.colors.onSurface : theme.colors.onSurfaceVariant)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(l10n.t(.shuffle))
            }

            Button { player.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.colors.onSurface)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(l10n.t(.previous))

            Button { player.togglePlayPause() } label: {
                ZStack {
                    if player.isLoading {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(theme.colors.onSurface)
                    }
                }
                .frame(width: 28, height: 28)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(player.isPlaying ? l10n.t(.pause) : l10n.t(.play))

            Button { player.next(userInitiated: true) } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.colors.onSurface)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(l10n.t(.next))

            if !compact && model.isPlayerBarExpanded {
            Button {
                player.repeatMode = player.repeatMode == .one ? .off
                    : (player.repeatMode == .off ? .all : .one)
            } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(player.repeatMode == .off ? theme.colors.onSurfaceVariant : theme.colors.onSurface)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(l10n.t(.repeatLabel))
            }
        }
        .padding(.trailing, 4)
    }

    private func rightControls(_ song: Song, showVolume: Bool) -> some View {
        HStack(spacing: 8) {
            barGlyph("quote.bubble", help: l10n.t(.lyrics), highlighted: model.playerTab == .lyrics) {
                model.openPlayer(.lyrics)
            }
            barGlyph("list.bullet", help: l10n.t(.queue), highlighted: model.playerTab == .queue) {
                model.openPlayer(.queue)
            }
            barGlyph("rectangle.expand.vertical", help: l10n.t(.nowPlaying), highlighted: false) {
                model.openPlayer(.nowPlaying)
            }

            if hovering {
                Button {
                    library.toggleFavourite(song)
                } label: {
                    Image(systemName: library.isFavourite(song) ? "heart.fill" : "heart")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(library.isFavourite(song) ? BitColors.accentRed : theme.colors.onSurfaceVariant)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }

            if showVolume {
                HStack(spacing: 5) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.colors.onSurfaceVariant)
                    Slider(value: $player.volume, in: 0...1)
                        .frame(width: 64)
                        .tint(theme.colors.onSurface.opacity(0.8))
                        .controlSize(.mini)
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.colors.onSurfaceVariant)
                }
                .opacity(hovering ? 1 : 0.75)
            }
        }
    }

    private func barGlyph(_ name: String, help: String, highlighted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(highlighted ? theme.colors.onSurface : theme.colors.onSurfaceVariant)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The bar has one line for the credit, so the album stays out of it.
    private func shortArtist(_ song: Song) -> String {
        song.artist
    }
}


/// Frosted glass for the top bar: a subtle blur of whatever passes behind it,
/// with a faint tint of the current track so it does not read as grey.
private struct FrostBand: View {
    @Environment(\.bit) private var theme: BitTheme
    /// How much black sits over the blur. Artist pages pass a whisper, because
    /// their top is the hero image itself.
    var tintOpacity: Double = 0.28

    var body: some View {
        ZStack {
            // Dark appearance and a black tint: the system's light variant is
            // what turned the band milky over bright sleeves.
            BlurMaterial(material: .hudWindow, blending: .withinWindow, darkAppearance: true)
            Color.black.opacity(tintOpacity)
        }
    }
}


/// The player sheet: one composited surface that slides in from the bottom.
///
/// The transition is expressed as data (an offset derived from the window
/// height and the finger drag) rather than as an insertion transition, so every
/// opening runs the same animation — a newly inserted view used to render its
/// final frame on first layout and look like it "appeared at once".
struct PlayerSheet<Content: View>: View {
    var isOpen: Bool
    var dismissProgress: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            content
                .frame(width: proxy.size.width, height: proxy.size.height)
                // Same corner language as the cards and the other sheets.
                .clipShape(UnevenRoundedRectangle(
                    topLeadingRadius: 18, bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0, topTrailingRadius: 18,
                    style: .continuous
                ))
                .clipped()
                .compositingGroup()
                // Closed means fully below the window: the drag adds to that.
                .offset(y: isOpen ? dismissProgress * proxy.size.height * 0.5
                                  : proxy.size.height + dismissProgress * proxy.size.height * 0.5)
                .opacity(isOpen ? 1 : 0)
                .allowsHitTesting(isOpen)
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: isOpen)
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.86), value: dismissProgress)
        .zIndex(10)
    }
}
