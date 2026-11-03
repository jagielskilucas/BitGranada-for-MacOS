//
//  ClipEngine.swift
//  BitGranada
//
//  The YouTube clip, muted, following the music's clock.
//
//  It is a second screen for the track: no audio of its own, no controls, no
//  button — if a clip exists it simply appears in the sleeve and stays in step
//  with what is playing. The canvas keeps the background.
//

import SwiftUI
import AVFoundation
import AppKit

@MainActor
final class ClipEngine: ObservableObject {
    static let shared = ClipEngine()

    @Published private(set) var player: AVPlayer?
    @Published private(set) var ready = false
    @Published private(set) var clipVideoId: String?
    @Published private(set) var songId: String?

    /// The music player whose clock the picture follows.
    weak var music: PlayerEngine?
    private var task: Task<Void, Never>?
    private var loadedSongId: String?
    /// Quality ladder: starts at 720p and climbs once playback proves stable.
    private var currentCap = 720
    private var stableTicks = 0
    private var stallObserver: NSObjectProtocol?
    private var tick: Task<Void, Never>?

    /// Starts (or restarts) the clip for `song`. A track without a clip simply
    /// leaves the sleeve to the artwork.
    func attach(song: Song, from music: PlayerEngine) {
        self.music = music
        let time = music.currentTime
        guard loadedSongId != song.id else { return }
        detach()
        loadedSongId = song.id
        songId = song.id
        task = Task { [weak self] in
            guard let self else { return }
            let clipId = await InnerTubeClient.shared.officialVideoId(
                title: song.title, artist: song.artist, expectedDuration: song.duration)
            guard let clipId, !Task.isCancelled else { return }
            let stream: (url: URL, height: Int)
            do {
                stream = try await InnerTubeClient.shared.videoStream(videoId: clipId, heightCap: 720)
            } catch {
                // No playable picture for this track: the sleeve keeps the
                // artwork and nothing else happens.
                return
            }
            guard !Task.isCancelled, loadedSongId == song.id else { return }
            // The CDN answers differently per client: the item is opened with the
            // same headers the API call used, or AVFoundation is served a body it
            // cannot parse and the item sits at `.unknown`.
            let asset = AVURLAsset(url: stream.url, options: [
                "AVURLAssetHTTPHeaderFieldsKey": [
                    "User-Agent": "com.apple.CoreMedia",
                    "Referer": "https://www.youtube.com/",
                    "Origin": "https://www.youtube.com",
                ],
            ])
            let item = AVPlayerItem(asset: asset)
            // Buffer before showing, not during: five seconds ahead is enough to
            // ride out the CDN's jitter without a visible stall.
            item.preferredForwardBufferDuration = 5
            if #available(macOS 11.0, *) {
                // Start light so the first frame appears fast, then climb.
                item.preferredMaximumResolution = Self.cap(for: 720)
            }
            let player = AVPlayer(playerItem: item)
            player.isMuted = true                      // the sound is the music's
            player.actionAtItemEnd = .none
            // Let it fill the buffer instead of stalling mid-frame.
            player.automaticallyWaitsToMinimizeStalling = true
            await player.seek(to: CMTime(seconds: max(0, time), preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .zero)
            self.clipVideoId = clipId
            self.currentCap = 720
            self.stableTicks = 0
            if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
            self.stallObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main
            ) { [weak self] _ in
                // A stall drops the ceiling back to where it was smooth.
                MainActor.assumeIsolated { self?.dropCap() }
            }
            self.player = player
            player.play()
            self.startTicking()
        }
    }

    func detach() {
        task?.cancel()
        tick?.cancel()
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
        stallObserver = nil
        stableTicks = 0
        currentCap = 720
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        ready = false
        clipVideoId = nil
        loadedSongId = nil
        songId = nil
    }

    /// Keeps the picture on the music's clock: a nudge while it is close, a seek
    /// when it drifts away.
    private func startTicking() {
        tick?.cancel()
        tick = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await MainActor.run { self?.step(to: self?.musicTime ?? 0) }
            }
        }
    }

    private var musicTime: TimeInterval { music?.currentTime ?? 0 }

    private func step(to time: TimeInterval) {
        guard let player, let item = player.currentItem else { return }
        // While the buffer is empty any seek makes it worse: wait it out and let
        // the player recover on its own.
        if item.isPlaybackBufferEmpty || !item.isPlaybackLikelyToKeepUp {
            stableTicks = 0
            return
        }
        climbIfStable(item)
        let drift = player.currentTime().seconds - time
        if abs(drift) > 0.45 {
            player.seek(to: CMTime(seconds: max(0, time), preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        } else if abs(drift) > 0.08 {
            player.rate = drift > 0 ? 0.96 : 1.04
        } else {
            player.rate = 1
        }
        // Only reveal the picture once it has actually advanced: the first
        // frames of an HLS stream can be black, and the artwork should stay on
        // screen until there is something to see.
        let readyNow = item.status == .readyToPlay && player.currentTime().seconds > 0.35
        if readyNow != ready {
            withAnimation(.easeInOut(duration: 0.25)) { ready = readyNow }
        }
    }

    /// 720p → 1080p once the stream has been steady for a few seconds; the HLS
    /// playlist carries both, so raising the ceiling is all that is needed.
    private func climbIfStable(_ item: AVPlayerItem) {
        guard currentCap < 1080 else { return }
        stableTicks += 1
        guard stableTicks >= 16 else { return }          // ~8 s at 500 ms
        currentCap = 1080
        stableTicks = 0
        if #available(macOS 11.0, *) {
            item.preferredMaximumResolution = Self.cap(for: currentCap)
        }
    }

    private func dropCap() {
        guard currentCap > 720 else { return }
        currentCap = 720
        stableTicks = 0
        if #available(macOS 11.0, *) {
            player?.currentItem?.preferredMaximumResolution = Self.cap(for: 720)
        }
    }

    private static func cap(for height: Int) -> CGSize {
        CGSize(width: Int(Double(height) * 16.0 / 9.0), height: height)
    }
}

/// The clip drawn into a square: an `AVPlayerLayer`, no interaction.
struct ClipSurface: NSViewRepresentable {
    var player: AVPlayer?
    var fill = true

    func makeNSView(context: Context) -> ClipHostView {
        let view = ClipHostView()
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: ClipHostView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        let gravity: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
        if view.playerLayer.videoGravity != gravity { view.playerLayer.videoGravity = gravity }
    }

    final class ClipHostView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            playerLayer.frame = bounds
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError() }

        /// Decorative: the buttons drawn above it must keep receiving clicks.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

/// Applies the shared-element transition only when a namespace was given.
struct SleeveMorph: ViewModifier {
    var namespace: Namespace.ID?
    var isSource: Bool

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: "playerArt", in: namespace, isSource: isSource)
        } else {
            content
        }
    }
}

/// The sleeve: the clip when it has a picture, the artwork until then.
struct ClipSleeve<Fallback: View>: View {
    var song: Song
    var side: CGFloat
    var radius: CGFloat
    var player: PlayerEngine
    /// When the sleeve travels between the mini player and the big one, the
    /// whole square morphs — not just the cover — so the clip rides along with
    /// it instead of popping in at the end.
    var artNamespace: Namespace.ID?
    var isSource = false
    @ViewBuilder var fallback: Fallback

    @ObservedObject private var engine = ClipEngine.shared
    /// False for the first moments on screen: the sleeve arrives by shared
    /// element, and a video layer that just appeared has no frame yet — it would
    /// flash black over the cover. The cover travels, then the clip fades in.
    @State private var settled = false

    private var showsClip: Bool { engine.ready && engine.player != nil && settled }

    var body: some View {
        ZStack {
            fallback
            if showsClip, let player = engine.player {
                ClipSurface(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: showsClip)
        .onAppear {
            settled = false
            Task {
                try? await Task.sleep(nanoseconds: 320_000_000)
                await MainActor.run { withAnimation(.easeInOut(duration: 0.3)) { settled = true } }
            }
        }
        .onDisappear { settled = false }
        .frame(width: side, height: side)
        .modifier(SleeveMorph(namespace: artNamespace, isSource: isSource))
        .task(id: song.id) {
            engine.attach(song: song, from: player)
        }
        // No detach on disappear: closing the column (or opening the player)
        // used to stop the clip, and the next surface reloaded it from scratch.
        // The engine keeps running for the track and is replaced on song change.
    }
}
