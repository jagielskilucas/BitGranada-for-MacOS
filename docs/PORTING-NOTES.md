# Porting notes — BitChord Android → macOS/SwiftUI

Everything here answers one of two questions: *where did this come from in the Android project?*
and *why is it different on the Mac?* The visual extraction behind the numbers lives in
[`spec/`](spec/), three documents written by reading the Kotlin source line by line:

- [`spec/01-shell-home-search-library.md`](spec/01-shell-home-search-library.md) — tabs, bars, Home,
  Search, Library, colour and type tokens.
- [`spec/02-now-playing-lyrics.md`](spec/02-now-playing-lyrics.md) — player layout, backdrop, palette
  maths, lyrics falloff, queue, motion.
- [`spec/03-data-lyrics-settings.md`](spec/03-data-lyrics-settings.md) — InnerTube contract, stream
  selection, lyrics providers, settings defaults.

---

## 1. Module map

| Android / KMP | macOS | Notes |
|---|---|---|
| `ui/theme/Theme.kt` | `BitChord/Theme.swift` | Colours, type scale, the "one cut lighter" weight mapping, gutters. |
| `ui/MainActivity.kt` (shell) | `BitChord/ShellView.swift` | Tab bar, mini player, top bar, z-order. |
| `ui/navigation/AppNavigator.kt` | `AppModel.path` | A simple stack of `Route`; tab press clears it. |
| `sharedUi/.../HomeScreen.kt` | `Views.swift` → `HomeView` | Shelves, hero card, wordmark header, skeleton. |
| `sharedUi/.../SearchScreen.kt` | `Views.swift` → `SearchView` | Field lives in the top bar; filters; grouped results. |
| `sharedUi/.../LibraryScreen.kt` | `Views.swift` → `LibraryView` | Folders, playlists shelf, favourites, local files. |
| `ui/screens/DetailScreen.kt` | `DetailViews.swift` → `ReleaseView` | Album/playlist/artist header + track list. |
| `sharedUi/.../NowPlayingScreen.kt` | `NowPlayingView.swift` | Two-column landscape arrangement for desktop. |
| `sharedUi/.../PlayerLyrics.kt` | `NowPlayingView.swift` → `LyricsPanel` | Falloff alpha/blur, tap-to-seek, auto-follow. |
| `sharedUi/.../PlayerQueue.kt` | `NowPlayingView.swift` → `QueuePanel` | Sections, current marker, durations. |
| `playback/PlaybackService.kt` | `PlayerEngine.swift` | Queue semantics: radio for a single track, release for a page. |
| `data/innertube/Innertube.kt` + `InnertubeParser.kt` | `InnerTube.swift` | Same endpoints and renderer walking. |
| `data/canvas/*` (palette) | `Artwork.swift` | Median-cut-ish palette; simpler than android.graphics Palette. |
| `data/lyrics/*` (16 providers) | `Lyrics.swift` | LRCLIB only, for now. |
| `data/OfflinePlaylists.kt`, `LocalMediaRepository.kt` | `LibraryStore.swift` | One JSON document instead of DataStore tables. |
| `data/settings/AppSettings.kt` | `AppSettings.swift` | Only the settings the desktop honours. |

## 2. Decisions worth knowing

**SwiftUI, not Compose Desktop.** The repo already has a Compose Multiplatform port (1.8, Linux and
Windows), but it is a JVM application that ships a runtime and cannot be built for macOS arm64 as a
native binary. The request was a native macOS build for Apple Silicon, so the UI is re-created in
SwiftUI against the phone's measured tokens rather than reusing `DesktopApp.kt`.

**AVFoundation is the audio engine, and that constrains the format.** YouTube offers Opus-in-WebM
and AAC-in-MP4; AVPlayer only demuxes MP4. `InnerTubeClient.streamURL` therefore filters to
`audio/mp4` (itag 140 normally) and raises a clear error when only WebM exists. This is the main
quality ceiling relative to the phone, which can decode Opus and FLAC.

**The player client is `VISIONOS`.** The Android app mints PoTokens through a WebView and Android
hooks; a desktop has no equivalent. `VISIONOS` is the client that still returns un-ciphered,
directly playable URLs, provided the request carries a `visitorData` value and the client headers —
both of which `InnerTubeClient` sends. The music endpoints (`WEB_REMIX`) stay exactly as the phone
uses them.

**Duration comes from metadata, not from the container.** YouTube's fragmented MP4 makes
AVFoundation report roughly twice the real duration; the player prefers `Song.duration` (from
InnerTube's `lengthText`) and only halves the container value when the metadata is missing.

**The backdrop is the blurred cover, not the mesh.** `legacyMeshGradient` is off by default on the
phone too; the shipping look is a 128 px cover blurred hard under a `0.34 / 0.48 / 0.64` black
scrim, which is what `ArtworkBackdrop` draws. `MeshBackdrop` still exists in `Components.swift` for
the artwork-tinted surfaces.

**Two columns above 900 pt.** `LandscapePlayer.kt` already defines a 1100 pt, two-column desktop
arrangement; the player reuses it so the sleeve never moves when the page turns.

**No crossfade yet.** `settings.crossfadeSeconds` is stored and shown in Settings with a note that
the engine plays one stream at a time. Implementing it means a second `AVPlayer` and a scheduled
hand-off; the setting is there so the UI doesn't have to change later.

## 3. Fidelity checklist

Kept 1:1 from the phone:

- colours `#000000` / `#0D0D0F` / `#1C1C1E` / `#8E8E93` / `#2C2C2E` and their light counterparts;
- SF Pro Display with `Bold→Semibold`, `Semibold→Medium`, `Medium→Regular` weight substitution;
- type scale (34/30/22/20/16/16/14/12/11) with the same tracking;
- 16 pt page gutter, 150 pt shelf cards with 12 pt corners and 14 pt gaps, 26 pt block bottom;
- 440 pt floating tab bar, 4 pt inset, 6 pt tab gap, capsule indicator at 14 % white;
- 56 pt mini player, 40 pt artwork at 8 pt corner, 8 pt above the bar;
- player: 560 pt content cap (1100 pt in two-column), 30 pt gutters, 8 pt artwork corner, 0.86
  paused shrink, 7/12 pt scrubber with no thumb, 74/92 play, 53/53 skips at `scaleY 0.85`;
- lyrics: 34 sp lead line, falloff alpha `1 / .80 / .70 / .58 / .46`, blur up to 2.4 pt.

Changed for a pointer-driven desktop: hover states on cards and rows, a kebab that appears on
hover, a real `NSVisualEffectView` blur, scroll-wheel lists, menu-bar commands and keyboard
shortcuts, and a 980 × 640 minimum window.

## 3.1 Desktop additions (not on the phone)

- **Right-hand now-playing column** (`NowPlayingRail.swift`) — the phone peeks at the player with a
  sheet; a desktop window has room to keep the lyrics beside the library. Same lyrics component,
  narrower type, tap-to-seek, and it disappears under 1120 pt.
- **Spotify Canvas** (`Canvas.swift`) — the community manifest the Android build already uses, plus
  a local file cache: the host answers range requests with the whole file, which AVPlayer refuses
  to stream, so the clip is fetched once and played from disk.
- **Downloads** (`Downloads.swift`) and **crossfade/gapless** (`PlayerEngine`), both absent from the
  earlier macOS build.

## 3.1.1 Liquid Glass

`Glass.swift` wraps Apple's own APIs from the Landmarks sample — `.glassEffect(_:in:)`,
`GlassEffectContainer`, `.buttonStyle(.glass)` and `.glassEffectID(_:in:)` — behind `#available(macOS 26)`,
so the bars, the player and the right-hand column are real Liquid Glass on 26+ and the previous
`NSVisualEffectView` blur below it. The build compiles against the macOS 26 SDK with a 14.0 deployment
target; `scripts/build.sh` probes for an SDK whose SwiftUI carries the glass symbols and falls back to
15.4 if the toolchain can't build it.

## 3.2 Backup import

`Backup.swift` reads the JSON the Android app exports (`app`, `version`, `settings[].value`,
`listening[]`). It maps the six settings this build shares — `theme_mode`, `crossfade_seconds`,
`lyrics_source_order`, `lyrics_sources`, `translation_language` (→ pt-BR) and `search_history` —
and rebuilds `LibraryStore.history` plus `listeningMonths` from the archive. Everything else is
named in the import report as Android-only instead of being dropped silently. The backup carries
no tokens, cookies or playlists; Replay is built entirely from `listening[]`.

## 3.3 Spotify Canvas status

`SpotifyCanvas.swift` ports the phone's chain: the `sp_dc` cookie is stored in the app's preferences
(not the Keychain — an ad-hoc signed build makes macOS prompt for authorisation on every read and
write, which meant a dialog per canvas), a hidden `WKWebView` loads the web player and hooks
`/api/token` to harvest a bearer, `clienttoken.spotify.com` mints the `Client-Token` header, and
`canvaz-cache` is asked for the clip with the phone's own protobuf body.

Verified with a real account: the bearer is minted and the client token is granted. What does **not**
work from here is the catalogue lookup that has to come before it — `api.spotify.com/v1/search`
answers **429** and the `pathfinder` query answers **403** (stale persisted-query hash for this web
player build). Without a Spotify track URI there is no canvas to ask for, so the app falls back to the
community manifest, which needs no account. Fixing this means keeping the pathfinder hash resolver
the phone has (`SpotifyCanvasQuery.queryHashes`), which is the next step if Spotify canvases are
wanted for tracks the community manifest doesn't cover.

## 4. Where to continue

1. **Opus decoding** — a WebM demuxer plus `AudioConverter` with `kAudioFormatOpus` would unlock
   the higher-bitrate WebM renditions and remove the MP4 ceiling.
2. **Accounts** — Google sign-in would use `ASWebAuthenticationSession` and the same cookie jar the
   `URLSession` already keeps; everything downstream (liked songs, library shelves) is InnerTube.
3. **Remaining phone features** — Discord Rich Presence, Last.fm/ListenBrainz, Listen Together,
   equalizer, Automix and Spotify sign-in are still Android-only; `spec/03` lists what each needs.
