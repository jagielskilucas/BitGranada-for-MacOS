//
//  ReplayView.swift
//  BitChord for macOS
//
//  The listening archive the Android backup carries: hours per month, the
//  tracks that ran the most and the artists behind them.
//
//  Android counterpart: ui/replay/ReplayScreen.kt.
//

import SwiftUI

struct ReplayView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryStore
    var theme: BitTheme

    @Environment(\.l10n) private var l10n
    @State private var importing = false
    @State private var report: BackupReport?
    @State private var errorText: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 92)

                HStack(alignment: .firstTextBaseline) {
                    Text("Replay")
                        .font(BitFont.font(.bold, 34))
                        .tracking(-0.5)
                        .foregroundStyle(theme.colors.onSurface)
                    Spacer()
                    Button {
                        chooseBackup()
                    } label: {
                        Label("Importar backup", systemImage: "square.and.arrow.down")
                            .font(BitFont.font(.medium, 12))
                            .foregroundStyle(theme.colors.onSurface)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(Capsule().fill(theme.colors.onSurface.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, BitMetrics.gutter)
                .padding(.bottom, 4)

                if let report {
                    Text(report.summary)
                        .bitStyle(.labelSmall)
                        .foregroundStyle(theme.colors.onSurfaceVariant)
                        .padding(.horizontal, BitMetrics.gutter)
                        .padding(.bottom, 8)
                }
                if let errorText {
                    Text(errorText)
                        .bitStyle(.labelSmall)
                        .foregroundStyle(BitColors.accentRed)
                        .padding(.horizontal, BitMetrics.gutter)
                }

                if library.listeningMonths.isEmpty {
                    MessageState(
                        title: "Nenhum histórico importado",
                        subtitle: "Importe o backup do BitChord do Android para ver seus meses aqui.",
                        theme: theme,
                        actionTitle: "Importar backup",
                        action: { chooseBackup() }
                    )
                } else {
                    ForEach(library.listeningMonths) { month in
                        monthCard(month)
                    }
                }

                Color.clear.frame(height: 176)
            }
        }
        .scrollIndicators(.never)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): importBackup(url)
            case .failure(let error): errorText = error.localizedDescription
            }
        }
    }

    // MARK: Pieces

    private func monthCard(_ month: ListeningMonth) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.monthName(month.month))
                    .font(BitFont.font(.bold, 24))
                    .tracking(-0.3)
                    .foregroundStyle(theme.colors.onSurface)
                Spacer()
                Text(hoursText(month.hoursListened))
                    .bitStyle(.labelMedium)
                    .foregroundStyle(theme.colors.onSurfaceVariant)
            }
            .padding(.horizontal, BitMetrics.gutter)
            .padding(.top, 14)

            Text("\(month.trackCount) faixas · \(month.artists.count) artistas · \(month.albums.count) álbuns")
                .bitStyle(.labelSmall)
                .foregroundStyle(theme.colors.onSurfaceVariant)
                .padding(.horizontal, BitMetrics.gutter)
                .padding(.bottom, 10)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(topArtists(month), id: \.name) { artist in
                        VStack(spacing: 6) {
                            artwork(artist.art, size: 92, radius: 46)
                            Text(artist.name)
                                .bitStyle(.labelMedium)
                                .foregroundStyle(theme.colors.onSurface)
                                .lineLimit(1)
                                .frame(width: 92)
                            Text(hoursText(artist.ms / 3_600_000))
                                .bitStyle(.labelSmall)
                                .foregroundStyle(theme.colors.onSurfaceVariant)
                        }
                    }
                }
                .padding(.horizontal, BitMetrics.gutter)
            }
            .scrollIndicators(.never)
            .padding(.bottom, 10)

            ForEach(topTracks(month), id: \.id) { track in
                trackRow(track)
            }

            Rectangle()
                .fill(theme.colors.outline)
                .frame(height: 0.5)
                .padding(.horizontal, BitMetrics.gutter)
                .padding(.top, 12)
        }
    }

    private func trackRow(_ track: ListeningTrack) -> some View {
        Button {
            let song = Song(
                videoId: track.id, title: track.title, artist: track.artist,
                album: track.album, duration: track.ms / 1000, thumbnailURL: track.art
            )
            model.player.play(song, startRadio: true)
            model.isRailVisible = true
        } label: {
            HStack(spacing: 12) {
                artwork(track.art, size: 44, radius: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .bitStyle(.titleMedium)
                        .foregroundStyle(theme.colors.onSurface)
                        .lineLimit(1)
                    Text(track.artist)
                        .bitStyle(.bodyMedium)
                        .foregroundStyle(theme.colors.onSurfaceVariant)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("\(track.plays)×")
                    .bitStyle(.labelMedium)
                    .foregroundStyle(theme.colors.onSurfaceVariant)
                Text(TimeFormat.playback(track.ms / 1000))
                    .bitStyle(.labelSmall)
                    .foregroundStyle(theme.colors.onSurfaceVariant.opacity(0.7))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            .padding(.horizontal, BitMetrics.gutter)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func artwork(_ url: String?, size: CGFloat, radius: CGFloat) -> some View {
        Group {
            if let url = ArtworkURL.resized(url, Int(size * 2)) {
                CoverArt(url: url, size: size, radius: radius, theme: theme)
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(theme.colors.surfaceVariant)
                    .frame(width: size, height: size)
            }
        }
    }

    private func topTracks(_ month: ListeningMonth) -> [ListeningTrack] {
        month.tracks.sorted { lhs, rhs in
            lhs.plays == rhs.plays ? lhs.ms > rhs.ms : lhs.plays > rhs.plays
        }.prefix(8).map { $0 }
    }

    private func topArtists(_ month: ListeningMonth) -> [ListeningArtist] {
        month.artists.sorted { $0.ms > $1.ms }.prefix(10).map { $0 }
    }

    private func hoursText(_ hours: Double) -> String {
        if hours < 1 { return "\(Int(hours * 60)) min" }
        let whole = Int(hours)
        let minutes = Int((hours - Double(whole)) * 60)
        return minutes == 0 ? "\(whole) h" : "\(whole) h \(minutes) min"
    }

    static func monthName(_ month: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM"
        guard let date = parser.date(from: month) else { return month }
        let out = DateFormatter()
        out.locale = Locale(identifier: L10n.resolved(.system) == .ptBR ? "pt_BR" : "en_US")
        out.dateFormat = "LLLL 'de' yyyy"
        let text = out.string(from: date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    // MARK: Import

    private func chooseBackup() {
        importing = true
    }

    private func importBackup(_ url: URL) {
        errorText = nil
        let needsAccess = url.startAccessingSecurityScopedResource()
        defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let object = try BackupImporter.read(from: url)
            let result = BackupImporter.apply(object, settings: model.settings, library: library)
            withAnimation(.easeInOut(duration: 0.25)) { report = result }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
