//
//  Downloads.swift
//  BitChord for macOS
//
//  Offline tracks: resolve the stream once, keep the file, and play it from
//  disk afterwards — including when there is no connection at all.
//
//  Android counterpart: download/Downloads.kt plus the offline playlist store.
//

import Foundation
import SwiftUI

struct DownloadRecord: Codable, Identifiable {
    var id: String { song.id }
    var song: Song
    var fileName: String
    var bytes: Int64
    var downloadedAt: Date
}

@MainActor
final class DownloadStore: ObservableObject {
    @Published private(set) var records: [String: DownloadRecord] = [:]
    @Published private(set) var active: Set<String> = []
    @Published private(set) var progress: [String: Double] = [:]
    @Published var lastError: String?

    private var tasks: [String: Task<Void, Never>] = [:]

    static let shared = DownloadStore()

    init() {
        load()
    }

    // MARK: Paths

    var folder: URL {
        let url = LibraryStore.storageDirectory.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var indexURL: URL { folder.appendingPathComponent("index.json") }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([String: DownloadRecord].self, from: data) else { return }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: State

    func localURL(for song: Song) -> URL? {
        guard let record = records[song.id] else { return nil }
        let url = folder.appendingPathComponent(record.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func isDownloaded(_ song: Song) -> Bool {
        localURL(for: song) != nil
    }

    func isDownloading(_ song: Song) -> Bool {
        active.contains(song.id)
    }

    var downloadedSongs: [Song] {
        records.values
            .sorted { $0.downloadedAt > $1.downloadedAt }
            .filter { localURL(for: $0.song) != nil }
            .map(\.song)
    }

    var totalBytes: Int64 { records.values.reduce(0) { $0 + $1.bytes } }

    // MARK: Actions

    func download(_ song: Song, highQuality: Bool) {
        guard !isDownloading(song), !isDownloaded(song), song.localURL == nil else { return }
        active.insert(song.id)
        progress[song.id] = 0
        lastError = nil

        tasks[song.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await InnerTubeClient.shared.streamURL(videoId: song.videoId, highQuality: highQuality)
                let (temporary, response) = try await URLSession.shared.download(from: stream.url)
                let expected = response.expectedContentLength
                let attributes = try? FileManager.default.attributesOfItem(atPath: temporary.path)
                let bytes = (attributes?[.size] as? Int64) ?? expected

                let ext = stream.mimeType.contains("mp4") ? "m4a" : "audio"
                let fileName = "\(song.videoId).\(ext)"
                let destination = self.folder.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)

                await MainActor.run {
                    self.records[song.id] = DownloadRecord(
                        song: song, fileName: fileName, bytes: max(0, bytes), downloadedAt: Date()
                    )
                    self.active.remove(song.id)
                    self.progress[song.id] = nil
                    self.save()
                }
            } catch {
                await MainActor.run {
                    self.active.remove(song.id)
                    self.progress[song.id] = nil
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    func remove(_ song: Song) {
        tasks[song.id]?.cancel()
        tasks[song.id] = nil
        guard let record = records[song.id] else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(record.fileName))
        records[song.id] = nil
        save()
    }

    func removeAll() {
        for key in records.keys { tasks[key]?.cancel() }
        tasks.removeAll()
        records.removeAll()
        active.removeAll()
        progress.removeAll()
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        save()
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

// MARK: - Downloads screen

struct DownloadsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var library: LibraryStore
    var theme: BitTheme

    @Environment(\.l10n) private var l10n

    private var store: DownloadStore { DownloadStore.shared }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 92)
                HStack(alignment: .firstTextBaseline) {
                    Text(l10n.t(.downloads))
                        .font(BitFont.font(.bold, 34))
                        .tracking(-0.5)
                        .foregroundStyle(theme.colors.onSurface)
                    Spacer()
                    if !store.records.isEmpty {
                        Text(ByteCountFormatter.string(fromByteCount: store.totalBytes, countStyle: .file))
                            .bitStyle(.labelMedium)
                            .foregroundStyle(theme.colors.onSurfaceVariant)
                    }
                }
                .padding(.horizontal, BitMetrics.gutter)
                .padding(.bottom, 10)

                if store.downloadedSongs.isEmpty {
                    MessageState(
                        title: l10n.t(.emptyLibrary),
                        subtitle: "Use o menu de qualquer faixa → Baixar.",
                        theme: theme
                    )
                } else {
                    ForEach(store.downloadedSongs) { song in
                        SongRow(song: song, theme: theme,
                                isCurrent: song.id == model.player.current?.id,
                                isPlaying: model.player.isPlaying) {
                            model.player.playAll(store.downloadedSongs, startingAt: song)
                            model.isRailVisible = true
                        } onMenu: {
                            store.remove(song)
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button(l10n.t(.openFolder)) { store.revealInFinder() }
                        .buttonStyle(.plain)
                        .bitStyle(.labelMedium)
                        .foregroundStyle(theme.colors.primary)
                    Button(l10n.t(.clearDownloads)) { store.removeAll() }
                        .buttonStyle(.plain)
                        .bitStyle(.labelMedium)
                        .foregroundStyle(BitColors.accentRed)
                }
                .padding(.horizontal, BitMetrics.gutter)
                .padding(.top, 16)

                Color.clear.frame(height: 176)
            }
        }
        .scrollIndicators(.never)
    }
}
