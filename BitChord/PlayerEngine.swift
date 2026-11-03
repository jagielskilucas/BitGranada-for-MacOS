//
//  PlayerEngine.swift
//  BitChord for macOS
//
//  Queue, transport and the AVPlayer that actually makes sound.
//
//  Android counterpart: playback/PlaybackService.kt + QueueCoordinator.kt.
//  The queue semantics are kept: playing a track on its own continues into
//  YouTube Music's radio for that track, while playing from a release walks
//  that release and never leaks into a radio.
//

import Foundation
import AVFoundation
import MediaPlayer
import AppKit

@MainActor
final class PlayerEngine: NSObject, ObservableObject {
    // MARK: Published state

    @Published private(set) var queue: [Song] = []
    @Published private(set) var index: Int = -1
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isBuffering = false
    @Published var errorMessage: String?
    @Published var repeatMode: RepeatMode = .all
    @Published var isShuffled = false
    @Published var volume: Double = 0.8 {
        didSet { player.volume = Float(volume) }
    }

    /// The queue the user sees in Up Next. `manualQueue` holds "play next"
    /// entries, which sit ahead of the natural order.
    @Published private(set) var manualQueue: [Song] = []

    var current: Song? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    // MARK: Private

    /// The playing player and the one the next track is faded in on. They are
    /// swapped when a crossfade completes, so `player` is always the audible
    /// one and every observer checks which object it was attached to.
    private var player = AVPlayer()
    private var aux = AVPlayer()
    private var timeObservers: [(player: AVPlayer, token: Any)] = []
    private var timeObserver: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var playEndObserver: NSObjectProtocol?
    private var shuffleOrder: [Int] = []
    private var nextStream: (videoId: String, url: URL)?
    private var resolutionTask: Task<Void, Never>?
    private let streamCache = StreamURLCache()

    /// Callback so the UI can persist history without the engine knowing about
    /// the library store.
    var onTrackStarted: ((Song) -> Void)?

    /// Set by AppModel so playback prefers a downloaded file over the network.
    var downloadResolver: (@MainActor (Song) -> URL?)?
    /// Addon sources: asked before YouTube so a lossless stream wins when one
    /// matches. Returns nil to fall through to YouTube.
    var externalResolver: (@MainActor (Song) async -> StreamInfo?)?
    /// What is actually playing, for the quality line ("FLAC 24-bit · Qobuz").
    @Published private(set) var streamLabel: String?
    /// Where the audio is coming from: the addon's name, YouTube Music, or a
    /// local/downloaded file. The player's "Tocando de" line reads this.
    @Published private(set) var playingSource: String?
    /// Seconds of overlap; 0 turns crossfade off and keeps the plain hand-off.
    var crossfadeSeconds: Double = 0
    /// Resolve the next track ahead of time so the end of a track doesn't wait
    /// on a network round trip.
    var gaplessEnabled = true

    private var crossfading = false
    /// Set after an addon stream failed to play, so the retry takes YouTube.
    private var allowAddon = true

    override init() {
        super.init()
        player.volume = Float(volume)
        player.actionAtItemEnd = .pause
        configureAudioSession()
        installTimeObserver()
        installRemoteCommands()
    }

    // MARK: Setup

    private func configureAudioSession() {
        // macOS has no AVAudioSession; AVPlayer routes to the default output.
        player.automaticallyWaitsToMinimizeStalling = true
    }

    private func installTimeObserver() {
        installTimeObserver(on: player)
        installTimeObserver(on: aux)
    }

    private func installTimeObserver(on observed: AVPlayer) {
        // 4 updates a second is only worth it while a progress bar is visible;
        // the observer is re-created at a lower rate otherwise.
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        let token = observed.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak observed] time in
            guard let self, let observed else { return }
            MainActor.assumeIsolated {
                // Both players run observers; only the audible one drives the UI.
                guard observed === self.player else { return }
                guard !self.isSeeking else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                // YouTube's fragmented MP4 reports a container duration at
                // twice the real length to AVFoundation; the metadata duration
                // from InnerTube is the one that matches the audio.
                if self.duration <= 0,
                   let item = self.player.currentItem,
                   item.duration.seconds.isFinite, item.duration.seconds > 0 {
                    self.duration = item.duration.seconds / (self.halvesContainerDuration ? 2 : 1)
                }
                self.updateNowPlayingProgress()
                self.maybePrefetchNext()
                self.maybeCrossfade()
            }
        }
        timeObservers.append((observed, token))
    }

    private var isSeeking = false

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next(userInitiated: true) }
            return .success
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    // MARK: Transport

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    /// Silences the music completely while the clip owns the sound: both players
    /// stop and their outputs are muted, so no tail keeps playing underneath.
    /// Set while the clip owns the sound: the music refuses to start on its own,
    /// so a queue advance cannot put two tracks on top of each other.
    var isHushedForClip = false

    func hushForClip() {
        isHushedForClip = true
        player.pause()
        aux.pause()
        aux.volume = 0
        isPlaying = false
        updateNowPlayingPlayback()
    }

    func resume() {
        guard !isHushedForClip else { return }
        guard player.currentItem != nil else {
            if let current { play(current) }
            return
        }
        player.play()
        isPlaying = true
        updateNowPlayingPlayback()
    }

    func pause() {
        player.pause()
        // The crossfade hand-off can leave the second player audible; pausing
        // only the primary one kept the previous track sounding.
        aux.pause()
        isPlaying = false
        updateNowPlayingPlayback()
    }

    func seek(to seconds: TimeInterval) {
        let clamped = max(0, min(seconds, max(duration, 0)))
        isSeeking = true
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.isSeeking = false }
        }
        updateNowPlayingProgress()
    }

    func next(userInitiated: Bool = false) {
        if repeatMode == .one && !userInitiated {
            seek(to: 0)
            resume()
            return
        }
        if !manualQueue.isEmpty {
            let song = manualQueue.removeFirst()
            queue.insert(song, at: index + 1)
            advance(to: index + 1)
            return
        }
        guard !queue.isEmpty else { return }
        if index + 1 < queue.count {
            advance(to: index + 1)
            return
        }
        // End of the queue.
        switch repeatMode {
        case .all:
            advance(to: 0)
        case .one:
            seek(to: 0)
            resume()
        case .off:
            pause()
        }
    }

    func previous() {
        // The phone's behaviour: restart the track unless we're still in the
        // first few seconds, which is when "previous" means the last track.
        if currentTime > 4 {
            seek(to: 0)
            return
        }
        guard !queue.isEmpty else { return }
        advance(to: max(0, index - 1))
    }

    // MARK: Playing

    /// Plays `song` and replaces the queue with `queue`.
    func play(_ song: Song, in newQueue: [Song]? = nil, startRadio: Bool = false) {
        // The clip owns the sound: keep the queue selection but stay silent.
        isHushedForClip = false
        if let newQueue, !newQueue.isEmpty {
            queue = newQueue
            index = newQueue.firstIndex(of: song) ?? 0
        } else if let existing = queue.firstIndex(of: song) {
            index = existing
        } else {
            queue.insert(song, at: 0)
            index = 0
        }
        loadCurrent(startRadio: startRadio)
    }

    /// Plays a whole release (album, playlist, artist top songs) from the top,
    /// or from `song` when one is given.
    func playAll(_ songs: [Song], startingAt song: Song? = nil) {
        guard !songs.isEmpty else { return }
        queue = songs
        index = song.flatMap { songs.firstIndex(of: $0) } ?? 0
        manualQueue = []
        loadCurrent(startRadio: false)
    }

    func playNext(_ song: Song) {
        manualQueue.append(song)
    }

    func addToQueue(_ song: Song) {
        queue.append(song)
    }

    func removeFromQueue(at offsets: IndexSet) {
        let adjusted = offsets.filter { $0 < queue.count && $0 != index }
        for offset in adjusted.sorted(by: >) {
            queue.remove(at: offset)
            if offset < index { index -= 1 }
        }
    }

    func moveQueue(from source: IndexSet, to destination: Int) {
        let moving = source.map { queue[$0] }
        let currentSong = current
        for offset in source.sorted(by: >) { queue.remove(at: offset) }
        var insertAt = destination
        for offset in source.sorted() where offset < destination { insertAt -= 1 }
        insertAt = max(0, min(insertAt, queue.count))
        queue.insert(contentsOf: moving, at: insertAt)
        if let currentSong, let newIndex = queue.firstIndex(of: currentSong) { index = newIndex }
    }

    func toggleShuffle() {
        isShuffled.toggle()
        rebuildShuffleOrder()
    }

    private func rebuildShuffleOrder() {
        shuffleOrder = queue.indices.shuffled()
        if let currentSong = current, let currentIndex = queue.firstIndex(of: currentSong) {
            shuffleOrder.removeAll { $0 == currentIndex }
            shuffleOrder.insert(currentIndex, at: 0)
        }
    }

    private func advance(to newIndex: Int) {
        guard queue.indices.contains(newIndex) else { return }
        index = newIndex
        loadCurrent(startRadio: false)
    }

    private func loadCurrent(startRadio: Bool) {
        guard let song = current else { return }
        resolutionTask?.cancel()
        // Nothing from the previous track may survive: without this, a fade in
        // flight (or an aux player mid-swap) kept playing over the new song.
        player.pause()
        player.replaceCurrentItem(with: nil)
        player.volume = Float(volume)
        aux.pause()
        aux.replaceCurrentItem(with: nil)
        aux.volume = 0
        crossfading = false
        isLoading = true
        errorMessage = nil
        currentTime = 0
        duration = song.duration ?? 0
        isPlaying = false
        updateNowPlayingMetadata(song)

        resolutionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.resolve(song)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.playingSource = stream.sourceName
                        ?? (self.streamLabel?.contains("YouTube") == true ? "YouTube Music" : nil)
                    self.startPlayback(stream: stream, song: song)
                }
            } catch {
                // A cancelled resolution is not a failure: the clip took the
                // audio, or another track was chosen. Reporting it printed
                // "cancelado" under the transport and left the UI paused.
                if error is CancellationError || Task.isCancelled {
                    await MainActor.run { self.isLoading = false }
                    return
                }
                await MainActor.run {
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }

        onTrackStarted?(song)
        if startRadio {
            fillRadio(for: song)
        }
    }

    private func resolve(_ song: Song) async throws -> StreamInfo {
        // Local files never touch the network: AVPlayer opens the file itself.
        if let localURL = song.localURL, let url = URL(string: localURL) {
            return StreamInfo(url: url, mimeType: "file", bitrate: 0, itag: 0,
                              duration: song.duration, sourceName: "Arquivo local")
        }
        // A downloaded file always wins: it is the same audio and needs no
        // network at all.
        if let local = downloadResolver?(song) {
            return StreamInfo(url: local, mimeType: "file", bitrate: 0, itag: 0,
                              duration: song.duration, sourceName: "Download")
        }
        if let cached = await streamCache.url(for: song.videoId) {
            return cached
        }
        // Highest quality first: an addon that matches this track answers with
        // FLAC; YouTube's AAC is the fallback.
        if allowAddon, let external = externalResolver, let addon = await external(song) {
            streamLabel = addon.label
            return addon
        }
        // Second source: JioSaavn, between the Qobuz addon and YouTube.
        if allowAddon,
           let jiosaavn = await JioSaavn.shared.stream(title: song.title, artist: song.artist,
                                                       expectedDuration: song.duration) {
            streamLabel = jiosaavn.label
            await streamCache.store(StreamInfo(url: jiosaavn.url, mimeType: jiosaavn.mimeType,
                                               bitrate: 320, itag: 9100,
                                               duration: jiosaavn.duration,
                                               label: jiosaavn.label,
                                               sourceName: "JioSaavn"),
                                    for: song.videoId)
            return StreamInfo(url: jiosaavn.url, mimeType: jiosaavn.mimeType,
                              bitrate: 320, itag: 9100, duration: jiosaavn.duration,
                              label: jiosaavn.label, sourceName: "JioSaavn")
        }
        let stream = try await InnerTubeClient.shared.streamURL(videoId: song.videoId)
        streamLabel = "AAC · YouTube Music"
        await streamCache.store(stream, for: song.videoId)
        return stream
    }

    /// YouTube's DASH audio is served with a `sidx` whose timescale makes
    /// AVFoundation report roughly twice the real duration. When the metadata
    /// duration is missing, halving the container value lands on the right
    /// length; with metadata present this is never consulted.
    private static func containerDurationFactor(_ item: AVPlayerItem) -> Double { 2 }

    /// Only YouTube's fragmented MP4 lies about its length; a FLAC from an addon
    /// reports the real duration, and halving it made the bar stop at 58%.
    private var halvesContainerDuration = true

    private func startPlayback(stream: StreamInfo, song: Song) {
        halvesContainerDuration = (stream.sourceName ?? "").contains("YouTube")
            || stream.mimeType.contains("mp4")
        let item = AVPlayerItem(url: stream.url)
        item.audioTimePitchAlgorithm = .timeDomain
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Whatever the container claimed, the track ended here: use that
                // as the length so the bar reaches the end on the next play.
                if let self, self.currentTime > 1 { self.duration = self.currentTime }
                self?.next(userInitiated: false)
            }
        }
        itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.isLoading = false
                    self.isBuffering = false
                    // The container is the authority once it is known: addon
                    // metadata can be off by minutes, which left the bar at 58%
                    // when the track actually ended.
                    let actual = item.duration.seconds / (self.halvesContainerDuration ? 2 : 1)
                    if actual.isFinite, actual > 1 {
                        let differs = abs(actual - self.duration) > max(3, self.duration * 0.05)
                        if self.duration <= 0 || differs {
                            self.duration = actual
                        }
                    }
                    self.player.play()
                    self.isPlaying = true
                    self.updateNowPlayingPlayback()
                case .failed:
                    // An addon stream that AVPlayer refuses drops back to
                    // YouTube once, rather than failing the track.
                    if self.allowAddon, self.streamLabel?.contains("YouTube") != true {
                        self.allowAddon = false
                        self.errorMessage = nil
                        self.loadCurrent(startRadio: false)
                        return
                    }
                    self.allowAddon = true
                    self.isLoading = false
                    self.isPlaying = false
                    self.errorMessage = item.error?.localizedDescription ?? "Playback failed."
                default:
                    break
                }
            }
        }
        player.replaceCurrentItem(with: item)
        player.volume = Float(volume)
        updateNowPlayingMetadata(song)
    }

    /// Starts the radio for a track played on its own, and appends it behind
    /// the track — the phone's `playRadio`.
    private func fillRadio(for song: Song) {
        let playlistId = InnerTubeClient.radioPlaylistId(videoId: song.videoId, playlistId: song.playlistId)
        Task { [weak self] in
            guard let self else { return }
            guard let songs = try? await InnerTubeClient.shared.upNext(videoId: song.videoId, playlistId: playlistId),
                  !songs.isEmpty else { return }
            await MainActor.run {
                // Keep whatever the user already had behind the current track,
                // then append the radio behind it.
                let existing = Set(self.queue.map(\.id))
                let additions = songs.filter { !existing.contains($0.id) }
                guard !additions.isEmpty else { return }
                self.queue.append(contentsOf: additions)
                self.rebuildShuffleOrder()
            }
        }
    }

    private func maybePrefetchNext() {
        guard nextStream == nil, queue.indices.contains(index + 1), duration - currentTime < 25 else { return }
        let song = queue[index + 1]
        if song.localURL != nil { return }
        Task { [weak self] in
            guard let self else { return }
            if let url = try? await InnerTubeClient.shared.streamURL(videoId: song.videoId) {
                await MainActor.run { self.nextStream = (song.videoId, url.url) }
            }
        }
    }

    // MARK: Crossfade

    /// Fades the next track in over the tail of the current one, then makes the
    /// incoming player the active one. No-op while crossfade is off.
    private func maybeCrossfade() {
        guard crossfadeSeconds > 0, !crossfading, isPlaying,
              duration > 0, queue.indices.contains(index + 1) else { return }
        let remaining = duration - currentTime
        guard remaining <= crossfadeSeconds, remaining > 0.15 else { return }

        let nextSong = queue[index + 1]
        crossfading = true

        Task { [weak self] in
            guard let self else { return }
            guard let stream = try? await self.resolve(nextSong) else {
                await MainActor.run { self.crossfading = false }
                return
            }
            await MainActor.run {
                self.aux.replaceCurrentItem(with: AVPlayerItem(url: stream.url))
                self.aux.volume = 0
                self.aux.play()
            }
            let steps = 24
            let stepSeconds = max(0.03, self.crossfadeSeconds / Double(steps))
            let target = Float(self.volume)
            for step in 1...steps {
                try? await Task.sleep(nanoseconds: UInt64(stepSeconds * 1_000_000_000))
                let fraction = Float(step) / Float(steps)
                await MainActor.run {
                    self.aux.volume = target * fraction
                    self.player.volume = target * (1 - fraction)
                }
            }
            await MainActor.run {
                self.player.pause()
                self.player.replaceCurrentItem(with: nil)
                swap(&self.player, &self.aux)
                self.player.volume = target
                self.aux.volume = 0
                self.index += 1
                self.crossfading = false
                guard let song = self.current else { return }
                self.currentTime = 0
                self.duration = song.duration ?? 0
                self.isPlaying = true
                self.updateNowPlayingMetadata(song)
                self.updateNowPlayingPlayback()
                self.onTrackStarted?(song)
            }
        }
    }

    // MARK: Now Playing (system)

    private func updateNowPlayingMetadata(_ song: Song) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
        ]
        if let album = song.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let duration = song.duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if let url = song.artwork(600) {
            loadNowPlayingArtwork(url, song: song)
        }
    }

    private func loadNowPlayingArtwork(_ url: URL, song: Song) {
        Task {
            guard let image = await ArtworkLoader.shared.image(for: url, pixels: 600) else { return }
            await MainActor.run {
                guard self.current?.id == song.id else { return }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }

    private func updateNowPlayingProgress() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingPlayback() {
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        updateNowPlayingProgress()
    }

    #if SNAPSHOT
    /// Snapshot-harness only: put the engine in a believable playing state
    /// without touching the network.
    func previewLoad(queue songs: [Song], index position: Int) {
        queue = songs
        index = position
        isPlaying = true
        currentTime = 72
        duration = songs[safe: position]?.duration ?? 213
        volume = 0.8
    }
    #endif

    /// Progress in 0…1, for the sliders.
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }
}

/// A short-lived cache of resolved stream URLs. They expire after minutes, so
/// the cache is small and short — enough to make a skip back instant.
actor StreamURLCache {
    private var entries: [String: (info: StreamInfo, date: Date)] = [:]
    private let ttl: TimeInterval = 60 * 5

    func url(for videoId: String) -> StreamInfo? {
        guard let entry = entries[videoId], Date().timeIntervalSince(entry.date) < ttl else { return nil }
        return entry.info
    }

    func store(_ info: StreamInfo, for videoId: String) {
        entries[videoId] = (info, Date())
        if entries.count > 40 {
            let oldest = entries.min { $0.value.date < $1.value.date }?.key
            if let oldest { entries.removeValue(forKey: oldest) }
        }
    }
}
