//
//  SnapshotFixtures.swift + SnapshotMain.swift
//  Compiled only by scripts/snapshot.sh (-DSNAPSHOT), never into the app.
//
//  The harness renders whole screens with ImageRenderer and writes PNGs, so
//  the layout can be reviewed without a display server or screen-recording
//  permission. Run: ./scripts/snapshot.sh
//

#if SNAPSHOT
import SwiftUI
import AppKit

enum SnapshotFixtures {
    static let songs: [Song] = [
        Song(videoId: "a1", title: "Get Lucky", artist: "Daft Punk, Pharrell Williams",
             album: "Random Access Memories", duration: 369,
             thumbnailURL: nil, playlistId: "RDAMVMa1"),
        Song(videoId: "a2", title: "Instant Crush", artist: "Daft Punk, Julian Casablancas",
             album: "Random Access Memories", duration: 337,
             thumbnailURL: nil, playlistId: "RDAMVMa2"),
        Song(videoId: "a3", title: "One More Time", artist: "Daft Punk",
             album: "Discovery", duration: 320,
             thumbnailURL: nil, playlistId: nil),
        Song(videoId: "a4", title: "Harder, Better, Faster, Stronger", artist: "Daft Punk",
             album: "Discovery", duration: 224,
             thumbnailURL: nil, playlistId: nil),
        Song(videoId: "a5", title: "Digital Love", artist: "Daft Punk",
             album: "Discovery", duration: 301,
             thumbnailURL: nil, playlistId: nil),
        Song(videoId: "a6", title: "Around the World", artist: "Daft Punk",
             album: "Homework", duration: 429,
             thumbnailURL: nil, playlistId: nil),
    ]

    static let shelves: [Shelf] = [
        Shelf(title: "Quick picks", items: [
            ShelfItem(title: "Random Access Memories", subtitle: "Daft Punk", videoId: nil,
                      browseId: "MPREb_1", pageKind: .album),
            ShelfItem(title: "Discovery", subtitle: "Daft Punk", videoId: nil,
                      browseId: "MPREb_2", pageKind: .album),
            ShelfItem(title: "Homework", subtitle: "Daft Punk", videoId: nil,
                      browseId: "MPREb_3", pageKind: .album),
            ShelfItem(title: "Alive 2007", subtitle: "Daft Punk", videoId: nil,
                      browseId: "MPREb_4", pageKind: .album),
        ]),
        Shelf(title: "Listen again", items: [
            ShelfItem(title: "Get Lucky", subtitle: "Daft Punk • Random Access Memories", videoId: "a1",
                      playlistId: "RDAMVMa1", duration: 369, pageKind: .mix),
            ShelfItem(title: "Instant Crush", subtitle: "Daft Punk • Random Access Memories", videoId: "a2",
                      playlistId: "RDAMVMa2", duration: 337, pageKind: .mix),
            ShelfItem(title: "One More Time", subtitle: "Daft Punk • Discovery", videoId: "a3",
                      duration: 320, pageKind: .mix),
            ShelfItem(title: "Digital Love", subtitle: "Daft Punk • Discovery", videoId: "a5",
                      duration: 301, pageKind: .mix),
            ShelfItem(title: "Around the World", subtitle: "Daft Punk • Homework", videoId: "a6",
                      duration: 429, pageKind: .mix),
            ShelfItem(title: "Veridis Quo", subtitle: "Daft Punk • Discovery", videoId: "a7",
                      duration: 344, pageKind: .mix),
        ]),
        Shelf(title: "Made for you", items: [
            ShelfItem(title: "French Touch Radio", subtitle: "Daft Punk, Justice, SebastiAn",
                      videoId: nil, browseId: "RDAMVMradio", pageKind: .playlist),
            ShelfItem(title: "Chill Electronic", subtitle: "Playlist", videoId: nil,
                      browseId: "VLPL1", pageKind: .playlist),
            ShelfItem(title: "Late Night Drive", subtitle: "Playlist", videoId: nil,
                      browseId: "VLPL2", pageKind: .playlist),
            ShelfItem(title: "Focus Flow", subtitle: "Playlist", videoId: nil,
                      browseId: "VLPL3", pageKind: .playlist),
            ShelfItem(title: "Disco Revival", subtitle: "Playlist", videoId: nil,
                      browseId: "VLPL4", pageKind: .playlist),
        ]),
    ]

    static let searchRows: [SearchRow] = songs.map { song in
        SearchRow(kind: .song, title: song.title, subtitle: song.artist, thumbnailURL: nil,
                  videoId: song.videoId, browseId: nil, playlistId: song.playlistId,
                  duration: song.duration)
    } + [
        SearchRow(kind: .album, title: "Random Access Memories", subtitle: "Daft Punk • 2013",
                  thumbnailURL: nil, videoId: nil, browseId: "MPREb_1", playlistId: nil, duration: nil),
        SearchRow(kind: .artist, title: "Daft Punk", subtitle: "Artist", thumbnailURL: nil,
                  videoId: nil, browseId: "UC1", playlistId: nil, duration: nil),
    ]

    static let moods: [MoodTile] = [
        MoodTile(title: "Chill", browseId: "m", params: "1", color: Color(hex: 0x5E5CE6)),
        MoodTile(title: "Energy", browseId: "m", params: "2", color: Color(hex: 0xFF375F)),
        MoodTile(title: "Feel good", browseId: "m", params: "3", color: Color(hex: 0xFF9F0A)),
        MoodTile(title: "Focus", browseId: "m", params: "4", color: Color(hex: 0x30D158)),
        MoodTile(title: "Romance", browseId: "m", params: "5", color: Color(hex: 0xFF2D55)),
        MoodTile(title: "Sleep", browseId: "m", params: "6", color: Color(hex: 0x64D2FF)),
        MoodTile(title: "Workout", browseId: "m", params: "7", color: Color(hex: 0xBF5AF2)),
        MoodTile(title: "Party", browseId: "m", params: "8", color: Color(hex: 0x0A84FF)),
    ]
}

@MainActor
enum SnapshotMain {
    static func render(_ view: some View, size: CGSize, name: String) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("failed to render \(name)")
            return
        }
        let url = URL(fileURLWithPath: "build/snapshots/\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: url)
        print("wrote \(url.path)")
    }

    static func run() {
        BitFont.registerFonts()
        let size = CGSize(width: 1280, height: 820)

        let model = AppModel()
        model.previewSeed()

        render(HomeView(model: model, library: model.library, theme: BitTheme(colors: .dark, isDark: true)),
               size: size, name: "00-home-content")

        render(
            ShellView(model: model, settings: model.settings, player: model.player, library: model.library)
                .environment(\.colorScheme, .dark)
                .preferredColorScheme(.dark),
            size: size, name: "01-home"
        )

        model.tab = .search
        render(
            ShellView(model: model, settings: model.settings, player: model.player, library: model.library)
                .environment(\.colorScheme, .dark)
                .preferredColorScheme(.dark),
            size: size, name: "02-search"
        )

        model.tab = .library
        render(
            ShellView(model: model, settings: model.settings, player: model.player, library: model.library)
                .environment(\.colorScheme, .dark)
                .preferredColorScheme(.dark),
            size: size, name: "03-library"
        )

        model.tab = .explore
        render(
            ShellView(model: model, settings: model.settings, player: model.player, library: model.library)
                .environment(\.colorScheme, .dark)
                .preferredColorScheme(.dark),
            size: size, name: "04-explore"
        )

        model.tab = .home
        model.isPlayerOpen = true
        model.playerTab = .nowPlaying
        render(
            NowPlayingView(model: model, settings: model.settings, player: model.player, library: model.library),
            size: size, name: "05-now-playing"
        )

        model.playerTab = .lyrics
        let lyricLines = [
            "Like the legend of the phoenix",
            "All ends with beginnings",
            "What keeps the planet spinning",
            "The force from the beginning",
            "We've come too far",
            "To give up who we are",
            "So let's raise the bar",
            "And our cups to the stars",
            "She's up all night 'til the sun",
            "I'm up all night to get some",
            "She's up all night for good fun",
            "I'm up all night to get lucky",
        ]
        model.lyrics.previewSet(Lyrics(
            lines: lyricLines.enumerated().map { index, text in
                LyricLine(index: index, start: Double(index) * 8, text: text, words: nil)
            },
            plain: lyricLines.joined(separator: "\n"),
            synced: true,
            source: "LRCLIB"
        ))
        render(
            NowPlayingView(model: model, settings: model.settings, player: model.player, library: model.library),
            size: size, name: "06-lyrics"
        )

        model.playerTab = .queue
        render(
            NowPlayingView(model: model, settings: model.settings, player: model.player, library: model.library),
            size: size, name: "07-queue"
        )

        model.isPlayerOpen = false
        model.push(.settings)
        render(
            ShellView(model: model, settings: model.settings, player: model.player, library: model.library)
                .environment(\.colorScheme, .dark)
                .preferredColorScheme(.dark),
            size: size, name: "08-settings"
        )

        model.path = [.release(kind: .album, browseId: "MPREb_1", title: "Random Access Memories",
                               subtitle: "Daft Punk • 2013", thumbnail: nil)]
        render(
            ShellView(model: model, settings: model.settings, player: model.player, library: model.library)
                .environment(\.colorScheme, .dark)
                .preferredColorScheme(.dark),
            size: size, name: "09-release"
        )

        exit(0)
    }
}

@main
struct SnapshotApp {
    static func main() {
        MainActor.assumeIsolated { SnapshotMain.run() }
    }
}
#endif
