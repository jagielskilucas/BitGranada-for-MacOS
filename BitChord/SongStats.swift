//
//  SongStats.swift
//  BitGranada
//
//  "Estatísticas" for the track that is playing: what Last.fm knows about it
//  globally, and what the app itself is using to play it right now.
//

import SwiftUI

@MainActor
final class SongStatsModel: ObservableObject {
    @Published private(set) var info: LastFM.TrackInfo?
    @Published private(set) var error: String?
    @Published private(set) var loading = false

    func load(song: Song) async {
        loading = true
        error = nil
        do {
            info = try await LastFM.shared.trackInfo(title: song.title, artist: song.artist)
        } catch {
            info = nil
            self.error = error.localizedDescription
        }
        loading = false
    }
}

struct SongStatsSheet: View {
    var song: Song
    var player: PlayerEngine
    var theme: BitTheme

    @StateObject private var model = SongStatsModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 12)
            if model.loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Consultando o Last.fm…")
                        .bitStyle(.bodyMedium)
                        .foregroundStyle(theme.colors.onSurfaceVariant)
                }
                .padding(.vertical, 8)
            } else if let info = model.info {
                global(info)
            } else if let error = model.error {
                Text(error)
                    .bitStyle(.bodyMedium)
                    .foregroundStyle(theme.colors.onSurfaceVariant)
            }
            Divider().padding(.vertical, 12)
            playback
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 420, height: 420, alignment: .topLeading)
        .background(theme.colors.background)
        .task(id: song.id) { await model.load(song: song) }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title)
                    .bitStyle(.titleLarge)
                    .foregroundStyle(theme.colors.onSurface)
                    .lineLimit(1)
                Text(song.artist)
                    .bitStyle(.bodyMedium)
                    .foregroundStyle(theme.colors.onSurfaceVariant)
                    .lineLimit(1)
            }
            Spacer()
            Button("Fechar") { dismiss() }
                .buttonStyle(.plain)
                .bitStyle(.labelMedium)
                .foregroundStyle(theme.colors.primary)
        }
    }

    private func global(_ info: LastFM.TrackInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            statRow("Ouvintes", Self.number(info.listeners))
            statRow("Execuções", Self.number(info.playcount))
            if let album = info.album, !album.isEmpty {
                statRow("Álbum", album)
            }
            if !info.tags.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text("Tags")
                        .bitStyle(.labelMedium)
                        .foregroundStyle(theme.colors.onSurfaceVariant)
                        .frame(width: 92, alignment: .leading)
                    Text(info.tags.prefix(5).joined(separator: " · "))
                        .bitStyle(.bodyMedium)
                        .foregroundStyle(theme.colors.onSurface)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var playback: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Como está tocando")
                .bitStyle(.labelMedium)
                .foregroundStyle(theme.colors.onSurfaceVariant)
            statRow("Fonte", player.playingSource ?? player.streamLabel ?? "—")
            statRow("Formato", player.streamLabel ?? "—")
            statRow("Duração", TimeFormat.playback(player.duration))
            if let year = song.album, !year.isEmpty {
                statRow("Álbum", year)
            }
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .bitStyle(.labelMedium)
                .foregroundStyle(theme.colors.onSurfaceVariant)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .bitStyle(.bodyMedium)
                .foregroundStyle(theme.colors.onSurface)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private static func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "pt_BR")
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
