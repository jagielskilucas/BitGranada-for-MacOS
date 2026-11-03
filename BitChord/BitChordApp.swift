//
//  BitChordApp.swift
//  BitChord for macOS
//
//  App entry, window chrome, menu commands. The window hides its title bar and
//  lets the app paint its own floating chrome, which is what keeps the phone's
//  look at the top edge of the window.
//

import SwiftUI
import AppKit

#if !SNAPSHOT
@main
struct BitChordApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ShellView(
                model: model,
                settings: model.settings,
                player: model.player,
                library: model.library
            )
            .frame(minWidth: 980, minHeight: 640)
            .background(WindowConfigurator())
            .onAppear {
                model.bootstrap()
                ScreenshotDriver.startIfRequested(model: model)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) { }

            CommandMenu("Reprodução") {
                Button(model.player.isPlaying ? "Pause" : "Play") {
                    model.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Próxima") { model.player.next(userInitiated: true) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Anterior") { model.player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)

                Divider()

                Button("Avançar 5s") {
                    model.player.seek(to: model.player.currentTime + 5)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                Button("Voltar 5s") {
                    model.player.seek(to: max(0, model.player.currentTime - 5))
                }
                .keyboardShortcut(.leftArrow, modifiers: [])

                Divider()

                Button(model.player.isShuffled ? "Shuffle Off" : "Shuffle On") {
                    model.player.toggleShuffle()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Picker("Repeat", selection: Binding(
                    get: { model.player.repeatMode },
                    set: { model.player.repeatMode = $0 }
                )) {
                    ForEach(RepeatMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }

            CommandGroup(after: .sidebar) {
                Button("Início") { model.select(.home) }.keyboardShortcut("1", modifiers: .command)
                Button("Explorar") { model.select(.explore) }.keyboardShortcut("2", modifiers: .command)
                Button("Biblioteca") { model.select(.library) }.keyboardShortcut("3", modifiers: .command)
                Button("Buscar") { model.select(.search) }.keyboardShortcut("f", modifiers: .command)
                Divider()
                Button("Now Playing") {
                    if model.player.current != nil { model.openPlayer() }
                }
                .keyboardShortcut("p", modifiers: .command)
                Button("Up Next") {
                    if model.player.current != nil { model.openPlayer(.queue) }
                }
                .keyboardShortcut("u", modifiers: .command)
                Button("Letras") {
                    if model.player.current != nil { model.openPlayer(.lyrics) }
                }
                .keyboardShortcut("l", modifiers: .command)
                Divider()
                Button("Voltar") {
                    if model.isPlayerOpen {
                        model.closePlayer()
                    } else {
                        model.pop()
                    }
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
    }
}
#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A small shared HTTP cache: the app's own artwork cache already holds
        // what it needs, and the default URLCache keeps decoded bodies in RAM.
        URLCache.shared = URLCache(memoryCapacity: 8 * 1024 * 1024,
                                   diskCapacity: 192 * 1024 * 1024)
        NSApp.setActivationPolicy(.regular)
        // Deliberately no `NSApp.appearance`: the window follows the system so
        // Settings → Theme → Sistema keeps working, and light mode keeps the
        // glass materials light.
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Window-level chrome the SwiftUI scene API doesn't expose: a hidden title,
/// full-size content view and a dark appearance so the app's blur materials
/// render as dark glass.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = false
            window.backgroundColor = .windowBackgroundColor
            window.minSize = NSSize(width: 980, height: 640)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
