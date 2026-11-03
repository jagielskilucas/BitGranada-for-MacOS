//
//  Localization.swift
//  BitChord for macOS
//
//  Two languages, one table. The phone ships a full Android resource set; this
//  build carries Portuguese (pt-BR) and English, chosen in Settings or taken
//  from the system, and every visible string goes through `t(_:)`.
//

import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, ptBR, en
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Sistema"
        case .ptBR: return "Português (Brasil)"
        case .en: return "English"
        }
    }
}

enum LKey: String, CaseIterable {
    // Navigation
    case home, search, explore, library, settings, favorites, recent, localFiles, downloads
    case playlists, newPlaylist, searchPlaceholder, yourLibrary, playingFrom, youtubeMusic
    // Home
    case listenNow, trending, showAll, loading, retry, couldNotReach, noResultsTitle
    // Search
    case searchTitle, recentSearches, clear, all, songs, albums, artists, videos, topResult
    case searchHint, noResultsFor, searchFailed
    // Library
    case libraryTitle, favouriteSongs, recentlyPlayed, addFolder, scanning, watchedFolders
    case remove, empty, tracks, songsCount, emptyPlaylist, addSongsHint
    // Player
    case nowPlaying, upNext, lyrics, play, pause, shuffle, shuffleOn, shuffleOff, repeatLabel, repeatOff
    case repeatAll, repeatOne, previous, next, closePlayer, volume, queue, currentPlaying
    case nextInQueue, nextFromYouTube, previouslyPlayed, clearQueue, song, unknownArtist
    case instrumental, noLyrics, noLyricsHint, tryAgain, loadingLyrics, lyricsBy
    // Settings
    case appearance, theme, systemLabel, dark, light, artworkBackdrop, artworkBackdropDetail
    case playback, audioQuality, standard, high, miniPlayerProgress, openLyricsOnStart
    case crossfade, crossfadeOff, crossfadeNote, gapless, gaplessDetail
    case language, languageDetail, about, version, engine, licensed
    case lyricsProviders, lyricsProvidersDetail, lyricsProviderPriority, apiKey, apiKeyDetail
    case downloadsSection, downloadQuality, downloadFolder, openFolder, clearDownloads
    // Errors
    case playbackError, streamUnavailable, networkError, offlineBanner
    // Context menus
    case playNext, addToQueue, addToFavorites, removeFromFavorites, download, removeDownload
    case addToPlaylist, newPlaylistFrom, goToAlbum, goToArtist, copyLink, removeFromPlaylist
    // Misc
    case cancel, done, create, delete, rename, save, ok, close, emptyLibrary, signInNotAvailable
}

struct L10n {
    var language: AppLanguage

    func t(_ key: LKey) -> String {
        let table = language == .ptBR || (language == .system && Self.systemPrefersPortuguese)
            ? Self.pt : Self.en
        return table[key] ?? Self.en[key] ?? key.rawValue
    }

    static var systemPrefersPortuguese: Bool {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("pt") ?? false
    }

    /// Effective language, resolving `.system` against the OS preference.
    static func resolved(_ language: AppLanguage) -> AppLanguage {
        switch language {
        case .system: return systemPrefersPortuguese ? .ptBR : .en
        case .ptBR, .en: return language
        }
    }

    // MARK: English

    private static let en: [LKey: String] = [
        .home: "Home", .search: "Search", .explore: "Explore", .library: "Library",
        .settings: "Settings", .favorites: "Favourite Songs", .recent: "Recently Played",
        .localFiles: "Local Files", .downloads: "Downloads", .playlists: "Playlists",
        .newPlaylist: "New Playlist", .searchPlaceholder: "Artists, Songs, Lyrics and More",
        .yourLibrary: "Your Library", .playingFrom: "PLAYING FROM", .youtubeMusic: "YouTube Music",
        .listenNow: "Listen Now", .trending: "Trending", .showAll: "Show all",
        .loading: "Loading…", .retry: "Try again",
        .couldNotReach: "Couldn't reach YouTube Music",
        .noResultsTitle: "No results",
        .searchTitle: "Search", .recentSearches: "Recent searches", .clear: "Clear",
        .all: "All", .songs: "Songs", .albums: "Albums", .artists: "Artists", .videos: "Videos",
        .topResult: "Top result",
        .searchHint: "Search millions of songs on YouTube Music.",
        .noResultsFor: "Nothing matched",
        .searchFailed: "Search failed",
        .libraryTitle: "Library", .favouriteSongs: "Favourite songs",
        .recentlyPlayed: "Recently played", .addFolder: "Add folder…",
        .scanning: "Scanning…", .watchedFolders: "Watched folders", .remove: "Remove",
        .empty: "Empty", .tracks: "tracks", .songsCount: "songs",
        .emptyPlaylist: "This playlist is empty",
        .addSongsHint: "Add songs from any track's menu, or from Search.",
        .nowPlaying: "Now Playing", .upNext: "Up Next", .lyrics: "Lyrics",
        .play: "Play", .pause: "Pause", .shuffle: "Shuffle", .shuffleOn: "Shuffle on",
        .shuffleOff: "Shuffle off", .repeatLabel: "Repeat", .repeatOff: "Repeat off",
        .repeatAll: "Repeat all", .repeatOne: "Repeat one", .previous: "Previous", .next: "Next",
        .closePlayer: "Close player", .volume: "Volume", .queue: "Queue",
        .currentPlaying: "Now playing", .nextInQueue: "Next in queue",
        .nextFromYouTube: "Next from YouTube Music", .previouslyPlayed: "Previously played",
        .clearQueue: "Clear queue", .song: "Song", .unknownArtist: "Unknown artist",
        .instrumental: "Instrumental", .noLyrics: "Lyrics not available",
        .noLyricsHint: "BitGranada looked across every enabled lyrics provider.",
        .tryAgain: "Try again", .loadingLyrics: "Loading lyrics…", .lyricsBy: "Lyrics",
        .appearance: "Appearance", .theme: "Theme", .systemLabel: "System", .dark: "Dark",
        .light: "Light", .artworkBackdrop: "Artwork backdrop",
        .artworkBackdropDetail: "Tint the player from the cover's palette",
        .playback: "Playback", .audioQuality: "Audio quality", .standard: "Standard",
        .high: "High", .miniPlayerProgress: "Show progress in the mini player",
        .openLyricsOnStart: "Open lyrics when a track starts",
        .crossfade: "Crossfade", .crossfadeOff: "Off",
        .crossfadeNote: "Blends the last seconds of a track into the next one.",
        .gapless: "Gapless playback", .gaplessDetail: "Preload the next track so albums flow",
        .language: "Language", .languageDetail: "App language, independent of the system",
        .about: "About", .version: "Version", .engine: "Engine",
        .licensed: "A native macOS adaptation of BitChord, GPLv3.",
        .lyricsProviders: "Lyrics providers",
        .lyricsProvidersDetail: "Tried in this order until one answers",
        .lyricsProviderPriority: "Priority", .apiKey: "API key (optional)",
        .apiKeyDetail: "Some providers only answer with a key",
        .downloadsSection: "Downloads", .downloadQuality: "Download quality",
        .downloadFolder: "Downloads folder", .openFolder: "Open folder",
        .clearDownloads: "Remove all downloads",
        .playbackError: "Playback error", .streamUnavailable: "This track can't be played",
        .networkError: "Network error", .offlineBanner: "Offline — showing downloaded music",
        .playNext: "Play next", .addToQueue: "Add to queue", .addToFavorites: "Add to favourites",
        .removeFromFavorites: "Remove from favourites", .download: "Download",
        .removeDownload: "Remove download", .addToPlaylist: "Add to playlist",
        .newPlaylistFrom: "New playlist from this", .goToAlbum: "Go to album",
        .goToArtist: "Go to artist", .copyLink: "Copy link", .removeFromPlaylist: "Remove from playlist",
        .cancel: "Cancel", .done: "Done", .create: "Create", .delete: "Delete", .rename: "Rename",
        .save: "Save", .ok: "OK", .close: "Close",
        .emptyLibrary: "Nothing here yet",
        .signInNotAvailable: "Sign-in isn't available in this build",
    ]

    // MARK: Portuguese (Brazil)

    private static let pt: [LKey: String] = [
        .home: "Início", .search: "Buscar", .explore: "Explorar", .library: "Biblioteca",
        .settings: "Ajustes", .favorites: "Músicas favoritas", .recent: "Tocadas recentemente",
        .localFiles: "Arquivos locais", .downloads: "Downloads", .playlists: "Playlists",
        .newPlaylist: "Nova playlist", .searchPlaceholder: "Artistas, músicas, letras e mais",
        .yourLibrary: "Sua biblioteca", .playingFrom: "TOCANDO DE", .youtubeMusic: "YouTube Music",
        .listenNow: "Ouça agora", .trending: "Em alta", .showAll: "Ver tudo",
        .loading: "Carregando…", .retry: "Tentar de novo",
        .couldNotReach: "Não foi possível acessar o YouTube Music",
        .noResultsTitle: "Nenhum resultado",
        .searchTitle: "Buscar", .recentSearches: "Buscas recentes", .clear: "Limpar",
        .all: "Tudo", .songs: "Músicas", .albums: "Álbuns", .artists: "Artistas", .videos: "Vídeos",
        .topResult: "Melhor resultado",
        .searchHint: "Busque milhões de músicas no YouTube Music.",
        .noResultsFor: "Nada encontrado para",
        .searchFailed: "A busca falhou",
        .libraryTitle: "Biblioteca", .favouriteSongs: "Músicas favoritas",
        .recentlyPlayed: "Tocadas recentemente", .addFolder: "Adicionar pasta…",
        .scanning: "Procurando…", .watchedFolders: "Pastas monitoradas", .remove: "Remover",
        .empty: "Vazia", .tracks: "faixas", .songsCount: "músicas",
        .emptyPlaylist: "Esta playlist está vazia",
        .addSongsHint: "Adicione músicas pelo menu de qualquer faixa ou pela busca.",
        .nowPlaying: "Tocando agora", .upNext: "A seguir", .lyrics: "Letras",
        .play: "Reproduzir", .pause: "Pausar", .shuffle: "Aleatório", .shuffleOn: "Aleatório ligado",
        .shuffleOff: "Aleatório desligado", .repeatLabel: "Repetir", .repeatOff: "Repetir desligado",
        .repeatAll: "Repetir tudo", .repeatOne: "Repetir uma", .previous: "Anterior",
        .next: "Próxima", .closePlayer: "Fechar player", .volume: "Volume", .queue: "Fila",
        .currentPlaying: "Tocando agora", .nextInQueue: "Próximas da fila",
        .nextFromYouTube: "A seguir no YouTube Music", .previouslyPlayed: "Tocadas antes",
        .clearQueue: "Limpar fila", .song: "Música", .unknownArtist: "Artista desconhecido",
        .instrumental: "Instrumental", .noLyrics: "Letra não disponível",
        .noLyricsHint: "O BitGranada procurou em todos os provedores de letras ativos.",
        .tryAgain: "Tentar de novo", .loadingLyrics: "Carregando letra…", .lyricsBy: "Letra",
        .appearance: "Aparência", .theme: "Tema", .systemLabel: "Sistema", .dark: "Escuro",
        .light: "Claro", .artworkBackdrop: "Fundo da capa",
        .artworkBackdropDetail: "Colore o player a partir da paleta da capa",
        .playback: "Reprodução", .audioQuality: "Qualidade de áudio", .standard: "Padrão",
        .high: "Alta", .miniPlayerProgress: "Mostrar progresso no mini player",
        .openLyricsOnStart: "Abrir letras quando uma música começar",
        .crossfade: "Crossfade", .crossfadeOff: "Desligado",
        .crossfadeNote: "Mistura os últimos segundos de uma faixa na próxima.",
        .gapless: "Reprodução sem pausa",
        .gaplessDetail: "Pré-carrega a próxima faixa para o álbum fluir",
        .language: "Idioma", .languageDetail: "Idioma do app, independente do sistema",
        .about: "Sobre", .version: "Versão", .engine: "Motor",
        .licensed: "Adaptação nativa para macOS do BitChord, GPLv3.",
        .lyricsProviders: "Provedores de letras",
        .lyricsProvidersDetail: "Consultados nesta ordem até um responder",
        .lyricsProviderPriority: "Prioridade", .apiKey: "Chave de API (opcional)",
        .apiKeyDetail: "Alguns provedores só respondem com chave",
        .downloadsSection: "Downloads", .downloadQuality: "Qualidade dos downloads",
        .downloadFolder: "Pasta de downloads", .openFolder: "Abrir pasta",
        .clearDownloads: "Remover todos os downloads",
        .playbackError: "Erro de reprodução", .streamUnavailable: "Esta faixa não pode ser tocada",
        .networkError: "Erro de rede", .offlineBanner: "Offline — mostrando o que foi baixado",
        .playNext: "Tocar em seguida", .addToQueue: "Adicionar à fila",
        .addToFavorites: "Adicionar aos favoritos", .removeFromFavorites: "Remover dos favoritos",
        .download: "Baixar", .removeDownload: "Remover download",
        .addToPlaylist: "Adicionar à playlist", .newPlaylistFrom: "Nova playlist com isto",
        .goToAlbum: "Ir para o álbum", .goToArtist: "Ir para o artista", .copyLink: "Copiar link",
        .removeFromPlaylist: "Remover da playlist",
        .cancel: "Cancelar", .done: "Concluído", .create: "Criar", .delete: "Apagar",
        .rename: "Renomear", .save: "Salvar", .ok: "OK", .close: "Fechar",
        .emptyLibrary: "Nada por aqui ainda",
        .signInNotAvailable: "Login indisponível nesta versão",
    ]
}

// MARK: - Environment

private struct L10nKey: EnvironmentKey {
    static let defaultValue = L10n(language: .system)
}

extension EnvironmentValues {
    var l10n: L10n {
        get { self[L10nKey.self] }
        set { self[L10nKey.self] = newValue }
    }
}
