//
//  SongActions.swift
//  BitChord for macOS
//
//  The right-click menu every track row and shelf card shares: queue edits,
//  favourites, playlists, downloads.
//
//  Android counterpart: ui/components/SongActionsMenu.kt.
//

import SwiftUI

extension View {
    func songActions(
        song: Song,
        model: AppModel,
        library: LibraryStore,
        downloads: DownloadStore = .shared
    ) -> some View {
        modifier(SongActionsModifier(song: song, model: model, library: library, downloads: downloads))
    }
}

extension View {
    @ViewBuilder
    func songActionsIfSong(row: SearchRow, model: AppModel, library: LibraryStore) -> some View {
        if let song = row.song {
            songActions(song: song, model: model, library: library)
        } else {
            self
        }
    }
}

struct SongActionsModifier: ViewModifier {
    var song: Song
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryStore
    @ObservedObject var downloads: DownloadStore

    @Environment(\.l10n) private var l10n
    @State private var showingPlaylistPicker = false

    func body(content: Content) -> some View {
        content.contextMenu {
            Button(l10n.t(.playNext)) { model.player.playNext(song) }
            Button(l10n.t(.addToQueue)) { model.player.addToQueue(song) }
            Divider()
            Button(library.isFavourite(song) ? l10n.t(.removeFromFavorites) : l10n.t(.addToFavorites)) {
                library.toggleFavourite(song)
            }
            Button(l10n.t(.addToPlaylist)) { showingPlaylistPicker = true }

            if downloads.isDownloaded(song) {
                Button(l10n.t(.removeDownload)) { downloads.remove(song) }
            } else if song.localURL == nil {
                Button(l10n.t(.download)) {
                    downloads.download(song, highQuality: model.settings.audioQuality == .high)
                }
            }

            Divider()
            Button(l10n.t(.copyLink)) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("https://music.youtube.com/watch?v=\(song.videoId)",
                                               forType: .string)
            }
        }
        .popover(isPresented: $showingPlaylistPicker, arrowEdge: .bottom) {
            PlaylistPicker(song: song, library: library) { name in
                let playlist = library.playlists.first { $0.name == name }
                    ?? library.createPlaylist(named: name)
                library.add(song, to: playlist)
                showingPlaylistPicker = false
            }
        }
    }
}

struct PlaylistPicker: View {
    var song: Song
    @ObservedObject var library: LibraryStore
    var onPick: (String) -> Void

    @Environment(\.l10n) private var l10n
    @Environment(\.bit) private var theme
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(l10n.t(.addToPlaylist))
                .font(BitFont.font(.medium, 13))
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

            ForEach(library.playlists) { playlist in
                Button {
                    library.add(song, to: playlist)
                    onPick(playlist.name)
                } label: {
                    HStack {
                        Text(playlist.name)
                            .font(BitFont.font(.regular, 13))
                        Spacer()
                        Text("\(playlist.songs.count)")
                            .font(BitFont.font(.regular, 11))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                }
                .buttonStyle(.plain)
            }

            Divider().padding(.vertical, 6)

            HStack(spacing: 6) {
                TextField(l10n.t(.newPlaylist), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                Button(l10n.t(.create)) {
                    guard !draft.isEmpty else { return }
                    onPick(draft)
                    draft = ""
                }
                .disabled(draft.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .frame(width: 260)
        .background(theme.colors.surface)
    }
}
