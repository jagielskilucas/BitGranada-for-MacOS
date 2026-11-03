# 03 — Data sources, stream selection, lyrics, settings

Extracted from BitChord 1.9 (Android, Kotlin). Every claim is cited as `path:line` relative to `BitChord-1.9/`. Nothing is inferred from naming conventions;
where the code guesses, this document says so.

## 0. Where the code actually lives

The brief assumed `app/src/main/java/com/music/bitchord/data/remote/` holds the InnerTube client. **It does not in 1.9** — that package is a local/remote *file*
library (`RemoteSong`, `RemoteListing`, `EmbeddedArt`, `RemoteArtwork`; see `app/.../data/remote/RemoteSong.kt:5-40`). The client is
`shared/src/jvmSharedMain/kotlin/com/music/bitchord/data/innertube/Innertube.kt`; parsing is `InnertubeParser.kt` beside it; stream resolution is
`{StreamResolver,InnerTubeXResolver,PlayerClient}.kt`; the repository is `.../data/YtMusicRepository.kt`; lyrics are `.../data/lyrics/*.kt`; settings are
`app/.../data/settings/AppSettings.kt` + `shared/.../data/settings/{PlayerEnums,LibraryEnums}.kt`; platform glue (PoToken, quality ceiling) is
`app/.../data/innertube/{AndroidStreamHooks,PlaybackTracker}.kt` and `.../innertube/potoken/PoTokenWebView.kt`.

The files the brief names are not format selectors: `StreamChoice.kt:50-101` memoises which server fills a cache entry, `QualityUpgrade.kt` is the mid-play swap
(§2.6), `PlaybackFallback.kt:19-51` the "give up on the substitute" escape, `MusicLink.kt:119-164` deep-link parsing.

---

## 1. InnerTube (YouTube Music)

### 1.1 Endpoint, identity, headers

Base `https://music.youtube.com/youtubei/v1` (`Innertube.kt:88`), origins `https://music.youtube.com` and `https://www.youtube.com` (`:89-90`). Every request is
`POST {base}/{endpoint}?prettyPrint=false&hl={hl}` (`:1130-1135`).

- `X-YouTube-Client-Name: 67` (`WEB_REMIX_CLIENT_ID`, `:99`, sent `:1142`).
- `X-YouTube-Client-Version`: the *live* `INNERTUBE_CLIENT_VERSION` scraped from the music.youtube.com shell, else `"1.20250101.01.00"` (`:98`, `:353-354`,
  `:460`).
- User-Agent, fixed (`:462-464`): `Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36`.
- Plus `Accept-Language`, `X-Origin`, `Origin`, `Referer: https://music.youtube.com/`, optional `X-Goog-Visitor-Id`, `Cookie`, `X-Goog-AuthUser`, `X-Goog-PageId`,
  `Authorization: SAPISIDHASH {ts}_{sha1}` (`:1134-1153`).
- `SAPISIDHASH` = `sha1("{unixSeconds} {sapisid} {origin}")` (`:1280-1286`); secret from the first of `SAPISID`, `__Secure-3PAPISID`, `__Secure-1PAPISID` in the
  cookie jar (`:1277-1278`).
- Timeouts 30/15/20 s (request/connect/socket); retry 3× on `IOException` only (500 ms then 1000 ms) — timeouts and cancellation are rethrown (`:468-525`).

### 1.2 Context object (top of every body)

`Innertube.kt:1156-1174`:

```json
{"context":{"client":{"clientName":"WEB_REMIX","clientVersion":"<live>","hl":"<lang>",
  "gl":"<region|omitted>","visitorData":"<omitted until known>"},
 "user":{"lockedSafetyMode":false,"onBehalfOfUser":"<dataSyncId|omitted>"},
 "request":{"useSsl":true}}, …endpoint body…}
```

`hl` = `LocaleTags.ytHl` (`:75-76`), `gl` = `LocaleTags.ytGl` (`:78-79`); search uses `ytSearchGl`, which may be null so YouTube places the request (`:82-83`).

### 1.3 visitorData

Minted deliberately, never hoped for (`Innertube.kt:122-193`): from the signed-in shell's `"VISITOR_DATA"\s*:\s*"([^"]+)"` (marked session-bound, `:445-450`,
`:459`); else `GET https://www.youtube.com/sw.js_data`, body stripped of the anti-hijack first line, parsed as JSON, scanned depth-first for the first string
matching `Cg[A-Za-z0-9_%-]{40,}` (`:178-193`); also read back from `responseContext.visitorData` while unknown (`:1181-1184`). Session-bound outranks anonymous
and is never replaced by it (`:140-170`). Skipping it is silently fatal: `player` then returns URLs that serve one byte and 403 every real read (`:122-136`).

### 1.4 Request bodies

| Endpoint | Body | Cite |
|---|---|---|
| `browse` | `{"browseId": id}` + optional `"params"` | `:529-533` |
| `browse` continuation | `{"continuation": t}` + query `ctoken={t}&continuation={t}&type=next` | `:541-548` |
| `search` | `{"query": q}` + optional `"params"`; anonymous by default | `:629-640` |
| `search` continuation | `{"continuation": t}` + same query triple | `:643-649` |
| `music/get_search_suggestions` | `{"input": text}` | `:660-663` |
| `next` | `{"videoId": v, "playlistId": "RDAMVM{v}", "isAudioOnly": true}`; playlist radio adds `params` | `:603-620` |
| `get_transcript` | `{"params": base64(0x0A,len,videoId)}` — 2-byte protobuf | `:623-627` |
| `player` | `videoId`, `contentCheckOk`, `racyCheckOk`, `playbackContext.contentPlaybackContext{html5Preference:"HTML5_PREF_WANTS", referer, signatureTimestamp}` | `:715-731` |
| `account/account_menu`, `account/accounts_list` | `{}` | `:551-561` |
| `like/like|dislike|removelike` | `{"target":{"videoId"|"playlistId"}}` | `:882-928` |
| `subscription/subscribe|unsubscribe` | `{"channelIds":[id]}`; `feedback` → `{"feedbackTokens":[token]}` | `:941-964` |
| `playlist/create` | `title`, `description`, `privacyStatus`, `videoIds[]` | `:973-994` |
| `playlist/delete`, `browse/edit_playlist` | `{"playlistId"}` (VL stripped); edit adds `actions[]` = `ACTION_ADD_VIDEO` / `ACTION_REMOVE_VIDEO` / `ACTION_MOVE_VIDEO_BEFORE` / `ACTION_SET_PLAYLIST_NAME` | `:996-1105` |

Search filter `params`, hardcoded base64 (`Models.kt:391-399`): `ALL=null`, `SONGS=EgWKAQIIAWoKEAkQChAFEAMQBA==`, `VIDEOS=EgWKAQIQAWoKEAkQChAFEAMQBA==`,
`ALBUMS=EgWKAQIYAWoKEAkQChAFEAMQBA==`, `ARTISTS=EgWKAQIgAWoKEAkQChAFEAMQBA==`, `PLAYLISTS=EgWKAQIoAWoKEAkQChAFEAMQBA==`. `postMusicAnonymous` (`:1195-1236`) is
the same minus `Cookie`/`Authorization`/`onBehalfOfUser`, so typeahead keystrokes never enter account search history (`:665-679`).

### 1.5 JSON paths for a track

From `InnertubeParser.parseResponsiveListItem` (`InnertubeParser.kt:678-774`):

| Field | Path | Cite |
|---|---|---|
| videoId | `playlistItemData.videoId`, else `overlay.musicItemThumbnailOverlayRenderer.content.musicPlayButtonRenderer.playNavigationEndpoint.watchEndpoint.videoId` | `:683-688` |
| title | `flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs[].text` joined | `:692-695` |
| subtitle | `flexColumns[1]…text.runs[]` joined, split on `" • "` | `:697-700` |
| duration | last subtitle segment matching `\d+:\d{2}`, else the first `fixedColumns[].musicResponsiveListItemFixedColumnRenderer.text.runs` matching it | `:710-714` |
| row type | first segment in `{song,video,album,single,ep,artist,playlist,podcast,episode}` | `:717`, `:1753-1756` |
| artist | `artistNamesFromRuns(runs)` → linked artist credit → show → first non-type segment → page credit → `"Unknown artist"` | `:741-753`, `:1047-1068` |
| artists[] / album | runs whose `navigationEndpoint.browseEndpoint.browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType` contains `ARTIST` / `ALBUM` | `:1017-1040` |
| thumbnails | `thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[]`, take the **last** entry's `url` | `:738-739`, `:1826` |
| isVideo | rowType `video`, or last thumbnail w/h outside 0.85–1.15 | `:769`, `:1833-1839` |
| explicit / setVideoId | any value equal to `MUSIC_EXPLICIT_BADGE`; `playlistItemData.playlistSetVideoId` | `:1720-1728`, `:763` |

Durations parse centrally: `M:SS` or `H:MM:SS` → ms, else 0 (`Models.kt:291-300`). Album/artist/playlist rows carry `navigationEndpoint.browseEndpoint.browseId`
+ `pageType` (`:162-195`); two-row cards use `title.runs` and `navigationEndpoint.watchEndpoint.videoId`, with a browseId `MPED<videoId>` stripped back to a
videoId (`:1648-1694`); podcast episodes (`musicMultiRowListItemRenderer`) use `onTap.watchEndpoint.videoId`, `secondTitle.runs` and
`playbackProgress.musicPlaybackProgressRenderer.durationText` parsed from "2 hr 43 min" (`:790-840`).

### 1.6 Home feed, browse ids, shelf order

Home = `browse("FEmusic_home")` (`YtMusicRepository.kt:79`), continuation for more shelves (`:105-113`). Appended in parallel: `FEmusic_new_releases`, then
`FEmusic_explore` (`:91-94`). Prepended when signed in: a locally derived `"Recents"` shelf (history, max 20, newest first) (`:84`, `:126-165`, `:288`,
`MainViewModel.kt:1708-1765`). Other ids: `FEmusic_history`, `FEmusic_moods_and_genres`, `FEmusic_liked_videos`, `FEmusic_liked_playlists`,
`FEmusic_liked_albums`, `FEmusic_library_corpus_track_artists`, `FEmusic_library_corpus_artists`, `FEmusic_library_non_music_audio_list`,
`FEmusic_mixed_for_you` (`YtMusicRepository.kt:288-1193`).

Shelves come from `contents.singleColumnBrowseResultsRenderer.tabs[0].tabRenderer.content.sectionListRenderer.contents[]`, each a `musicCarouselShelfRenderer`
or `musicShelfRenderer` (`InnertubeParser.kt:199-209`). Section title = `header.musicCarouselShelfBasicHeaderRenderer.title.runs` or
`musicShelfRenderer.title.runs`; strapline = `header.strapline.runs`; blank titles render as `"For you"`; a title matching `\bvideos?\b` keeps only playable
video items (`:283-317`). Continuations: `continuationItemRenderer.continuationEndpoint.continuationCommand.token`, else
`commandExecutorCommand.commands[].continuationCommand.token`, else `nextContinuationData.continuation` (`:661-670`). Shelf "More" target:
`header.title.runs[].navigationEndpoint.browseEndpoint` (browseId + params), with `moreContentButton`, `endIcons[]`, `header.navigationEndpoint` as fallbacks
(`:357-370`). A catalogue album's full track list lives in the playlist named by the header play button (`watchPlaylistEndpoint.playlistId` /
`watchEndpoint.playlistId`), else `microformat.microformatDataRenderer.urlCanonical`'s `list=` (`:1162-1190`).

---

## 2. Stream selection

### 2.1 Quality ladder

`AudioQuality` (`PlayerEnums.kt:17-28`) is both the tier and the per-connection ceiling:

| Enum | maxKbps | Detail | Budget |
|---|---|---|---|
| `LOW` | 64 | ~64 kbps · smallest download | 29 MB/hr |
| `MEDIUM` | MAX | Best available · ~171 kbps Opus | 77 MB/hr |
| `HIGH` | MAX | JioSaavn up to 320 kbps, YouTube fallback | 144 MB/hr |
| `LOSSLESS` | MAX | Your addons + JioSaavn, bit-exact | 300+ MB/hr |

Which *sources* a rung admits (`AppSettings.kt:38-46`): `LOSSLESS` → all; `HIGH` → everything that cannot serve lossless; `MEDIUM`/`LOW` → YouTube only. On
YouTube the ceiling is the only difference. Effective ceiling = metered vs unmetered setting, lowered by any temporary override (`AppSettings.kt:843-864`).
Sources are ordered by `SourceKind.rank` — user addons 0 (among themselves by drag order), `CUSTOM_MODULE` 0, `MODULE` 1, `JIOSAAVN` 2, `YOUTUBE` 3
(`app/.../data/sources/SourceKind.kt:56-160`) — then filtered by `permits` (`SourceRegistry.kt:270-273`).

### 2.2 YouTube: two-stage resolver

`StreamResolver.resolve(videoId)` (`StreamResolver.kt:262-282`): cached URL if under `URL_TTL_MS` = 20 min / 32 entries (`:1221-1235`); a "permanently
unplayable" verdict (10 min TTL) throws without a request (`:335-349`, `:367`); concurrent resolves for one id coalesce (`:391-421`); stage 1, then stage 2 on
null (`:438-441`). Live URLs (`live=1` / `source=yt_live_broadcast`) are replaced by their HLS playlist (`:436`, `:1033-1064`).

**Stage 1 — InnerTubeX** (`InnerTubeXResolver.kt:226-263`) walks a live-benchmarked client catalog with cipher tiers and PoTokens. Capabilities per extract:
`allowHls=false, allowSabr=false, allowBoundedRange=true` (`:236-247`), so the answer is always a **progressive, ranged** stream. Quality mapping is coarse by
design (`:241-245`):

| App request | InnerTubeX tier |
|---|---|
| `requireM4a` (download) | `AudioQuality.MP4` — best AAC-in-MP4 |
| `maxKbps <= 64` | `AudioQuality.LOW` |
| otherwise | `AudioQuality.AUTO` — best Opus |

**There is no itag list in this app.** Itags appear only as prose: 140 ≈ 128 kbps AAC, 141 ≈ 256 kbps AAC, 251 Opus (`SourceResolver.kt:1417-1418`,
`AudioCache.kt:519`). Selection = highest rung at or under the ceiling, and if everything is over it, the cheapest (`StreamResolver.kt:754-759`); three
attempts, each skipping the client that minted an unusable URL (`:588`, `:497-535`).

Client identities used to dress media fetches (`PlayerClient.kt:52-110`): `IOS 21.26.4`, `IOS 21.29.1`, `ANDROID 21.26.364`, `ANDROID_MUSIC 8.39.42`,
`ANDROID_VR 1.65.10`, `ANDROID_VR 1.43.32`, `WEB_REMIX 1.20260707.12.00`, `WEB 2.20260708.00.00`, `TVHTML5 7.20260707.07.00`, `VISIONOS`. The minting client is
recovered from the URL's `c`/`cver`, and its `User-Agent` (plus `Origin`/`Referer` for browser-shaped clients) **must** accompany the media request or
googlevideo throttles or 403s (`:120-156`, `:38-42`); range size is 1 MiB, or 512 KiB for `ANDROID_VR`/`TVHTML5_SIMPLY` (`:147-159`).

**PoToken** comes from a hidden WebView (`app/.../innertube/potoken/PoTokenWebView.kt:50-70`, `AndroidStreamHooks.kt:54-80`); with no provider,
PoToken-requiring clients are dropped from the catalog (`InnerTubeXResolver.kt:142-153`). Remote cipher/player config comes from
`https://raw.githubusercontent.com/ZemerTeam/zemer-cipher/master/library/src/main/assets/player_configs.json`, cached in prefs (`:175-191`, `:400-401`).

**Stage 2 — NewPipe** (`StreamResolver.kt:1132-1164`) scrapes `https://www.youtube.com/watch?v={id}`, takes `extractor.audioStreams`, keeps `deliveryMethod ==
PROGRESSIVE_HTTP` with non-blank `content`, and applies the same ceiling; signature cipher and `n` are already resolved by the extractor (`:1155-1157`).
Serialised behind one mutex (`:1130-1135`), 5 s call timeout, own connection pool (`:218-252`); `next` is answered from a stub so it never blocks (`:72-104`); 3
attempts with 1 s/2 s backoff (`:1104-1107`).

### 2.3 How a playable URL is derived

No signatureCipher handling of our own: InnerTubeX's cipher service and NewPipe both return a ready `audioUrl`/`content` (`InnerTubeXResolver.kt:236-259`,
`StreamResolver.kt:1155-1162`). No poToken is appended here — it is a property of the minting client (`pot` is read only for logging, `StreamResolver.kt:898`).
Playable URL = plain googlevideo HTTPS URL, fetched with `Range` and the minting client's headers (`:585-586`).

### 2.4 Nothing is played before it is probed

`probe(url)` (`StreamResolver.kt:841-888`) issues a ranged GET with `Range: bytes={start}-{end}`, `start = 1 MiB` when `clen > 1 MiB + 16 KiB` (else 0), window
= the client's range size (`:842-853`):

- 403/404/410 → `REFUSED`; other non-2xx except 416 → `UNREACHABLE` (`:861-863`, `:890`).
- `Content-Type` not `audio/*` → `REFUSED` (a consent page dressed as success, `:866`).
- Fewer than 16 KiB delivered, or any exception → `UNREACHABLE` (`:871`, `:884-887`); 6 s ceiling (`:916`).

On `REFUSED`: skip that client and retry; if signed in and this was the first attempt, re-ask as the user's own upload (`:522-532`).

### 2.5 When playback fails

`PlaybackService.recoverFrom` (`PlaybackService.kt:3967+`):

1. `ERROR_CODE_IO_FILE_NOT_FOUND` on a local file → rebuild without the local URI (`:3996-4000`); `ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED` → replay as a manifest
   (`:4006-4010`).
2. A failed substitute (addon/JioSaavn, or a `q=hifi*` item) → rebuild as an explicit YouTube request: `direct_youtube=1`, `q=original`, mime cleared (`:4016`;
   `PlaybackFallback.kt:19-51`, `:68-86`).
3. Forget the choice and the upgrade, wait 350 ms, discard the cache entry (keeping complete ones on a network fault), re-prepare (`:4120-4121`, `:9567`).
4. Budget `MAX_RECOVERIES = 2` (`:9544`); a resolver verdict exhausts it at once (`:4040-4041`). Skip forward only if the track never made a sound, and stop
   skipping after `MAX_CONSECUTIVE_SKIPS = 4` (`:4386-4394`, `:9552`).
5. A substitute that died is refused for 10 min (`StreamChoice.kt:172-203`) and excluded from mid-song upgrades. Permanent reasons carry user-facing text: age
   restriction (with/without sign-in), geo-block, paid content, Premium-only, private, terminated channel (`StreamResolver.kt:1080-1101`).

### 2.6 Mid-playback upgrade

A track that started below the request is marked pending (`QualityUpgrade.kt:196-228`) and a second look runs while it plays (`:439-562`). The swap happens only
if the candidate is the same recording within ±`upgradeLengthSlackSeconds` (default 5 s — `AppSettings.kt:200`, `:2119`) **and** `worthSwapping` agrees
(`SourceResolver.kt:819-833`): lossless or Atmos always wins, a lossy candidate must gain ≥ 96 kbps (`:1437`). The item URI is re-pointed with `&q=hifi[-n]` and
the stream parked so every re-open reaches the same bytes (`QualityUpgrade.kt:796-857`). Cross-source ranking is Atmos → lossless (bit depth, then sample rate)
→ kbps (`SourceResolver.kt:1307-1332`).

---

## 3. Lyrics

### 3.1 Repository behaviour

`LyricsRepository.lyrics(...)` (`LyricsRepository.kt:87-179`): sequence = user order, then any source the saved order forgot, ∩ enabled set, hidden removed
(`:107-109`). All enabled sources start **at once**; answers are consumed in priority order, so a fast low-priority answer never preempts a pending higher one
(`:131-171`), and losers are cancelled at the end (`:176`). The first answer with any word-synced line wins outright; otherwise the first line-synced answer,
unless `prioritizeSyllableSync` is on, in which case a line-synced answer is only a fallback (`:160-172`). `Genius` starts `LAZY` and is skipped once anything
line-synced exists (`:132`, `:163`). Before the race, one 2.5 s `BiniLyrics.identify` resolves the recording to an ISRC, cached per videoId (100 entries)
(`:120-126`, `:238`, `:248-285`).

Query cleaning strips `(feat. X)`, `[ft. X]`, `(Official Video)`, `(Lyrics)`, `(Audio)`, `(MV)` but deliberately keeps version words (`Remix`, `Live`,
`Acoustic`, `Remastered`, `Sped Up`) (`LyricsQuery.kt:26-59`); `" - Topic"` is trimmed off the artist (`:41-42`). Every winning document gets
`withBackgroundVocals()` (`:227-228`). HTTP is 6 s call / 3 s connect, 15 s/10 s for authenticated PaxSenix, UA `BitChord (https://github.com/bitchord)`
(`LyricsHttp.kt:17-30`, `:19`).

### 3.2 Providers, in default priority order

Declaration order *is* the default priority (`LyricsSource.kt:25-130`); `hidden` entries never run.

| # | Source | Endpoint + params | Shape |
|---|---|---|---|
| 1 | lrc.red | `GET https://lrc.red/s/{ISRC}.ttml`, else `https://lrc.red/search.json?q={title artist}` | `{hits:[{isrc,title,artist,album,year,duration}],next}` → TTML |
| 2 | BiniLyrics | `GET https://lyrics-api.binimum.org/?isrc=` or `?track=&artist=&album=&duration=` | `{results:[{track_name,artist_name,album_name,duration,isrc,timing_type,lyricsUrl}]}`, then GET `lyricsUrl` (TTML) |
| 3 | BetterLyrics | `GET https://lyrics-api.boidu.dev/getLyrics?s=&a=&d=&al=` | TTML / enhanced LRC / plain, sniffed |
| 4 | BetterLyrics Portato | `GET https://lyrics-api.boidu.dev/qq/getLyrics?s=&a=&d=&al=` | QQ karaoke `[start,dur]text(start,dur,0)…` |
| 5 | PaxSenix | id from `https://amp-api.music.apple.com/v1/catalog/us/search?term=&types=songs&limit=10&l=en-US` (scraped bearer), then `GET https://lyrics.paxsenix.org/apple-music/lyrics?id=&ttml=true` | Apple TTML |
| 6 | PaxSenix: Spotify | `GET https://api.paxsenix.org/lyrics/spotify?id=` (Bearer = user key); fallback `lyrics/lrcget?q=` | candidate array, best metadata score |
| 7 | PaxSenix: Musixmatch | `GET https://api.paxsenix.org/lyrics/musixmatch?t=&a=&d=` (Bearer key) | same fallback |
| 8 | LyricsPlus | `GET {mirror}/v2/lyrics/get?title=&artist=&duration=&album=&isrc=` (6 mirrors) | `{lyrics:[{time,duration,text,syllabus:[{time,duration,text}],element}],metadata.agents}` |
| 9 | SimpMusic *(hidden)* | `GET https://api-lyrics.simpmusic.org/v1/{videoId}` | `{success,data:[{duration,richSyncLyrics,syncedLyrics}]}` |
| 10 | Unison | `GET https://unison.boidu.dev/lyrics?song=&artist=&album=&duration=` | `{success,data:{lyrics,format,syncType}}`; `format=ttml`→TTML, `syncType=plain`→plain, else enhanced→plain LRC |
| 11 | YouTube captions | `POST /youtubei/v1/get_transcript` | `transcriptCueRenderer.startOffsetMs` + `cue` |
| 12 | YouTube Music | `next(videoId)` → Lyrics tab `browseEndpoint` → `browse(id, params)` → `musicDescriptionShelfRenderer.description` | plain text |
| 13 | Megalobiz *(hidden)* | `GET https://www.megalobiz.com/searchall?qry={artist title}` → `/lrc/maker/download/…` → `#lrc_*_details` | HTML-stripped LRC |
| 14 | KuGou | `mobileservice.kugou.com/api/v3/search/song?version=9108&plat=0&pagesize=8&showtype=0&keyword=`, then `lyrics.kugou.com/search?ver=1&man=yes&client=pc&hash=`, then `…/download?fmt=lrc&charset=utf8&client=pc&ver=1&id=&accesskey=` | base64 → LRC |
| 15 | LRCLIB | `GET https://lrclib.net/api/get?track_name=&artist_name=&duration=`, fallback `/api/search?…` | `{syncedLyrics}`; fuzzy hit = closest `duration` |
| 16 | Musixmatch | `apic.musixmatch.com/ws/1.1/track.search?app_id=mobile-app-v1.0&format=json&q_track=&q_artist=&f_has_lyrics=1&s_track_rating=desc&quorum_factor=1&page_size=10&page=1&usertoken=`, then `track.richsync.get?track_id=` or `track.subtitle.get` | HMAC-signed, rotating secret scraped from `musixmatch.com/search` |
| 17 | Genius | `GET https://genius.com/api/search/multi?q=` → song page HTML | `response.sections[type=song].hits[].result`, scored on title/artist |

LyricsPlus races its mirrors and remembers the last good one (`LyricsPlus.kt:33-77`); KuGou keeps only candidates within ±8 s of runtime before choosing a hash
(`KuGou.kt:24`, `:61`); Musixmatch prefers rich-sync when `hasRichSync != 0` (`Musixmatch.kt:59-72`); SimpMusic allows ±10 s because one video can hold several
cuts (`SimpMusicLyrics.kt:27`, `:38`).

### 3.3 LRC parsing rules

**Line-synced** (`LrcLib.parseLrc`, `LrcLib.kt:91-131`): stamp `\[(\d{1,2}):(\d{2})[.:](\d{2,3})]`, where a 2-digit fraction is centiseconds (×10) and 3 digits
are milliseconds (`:96-100`, `:202`). Text follows the stamp; `<mm:ss.xx>` word stamps are stripped from display text (`:110`). Empty-text stamps are
instrumental gaps, kept only if the next line starts ≥ `MIN_GAP_MS` = 4000 ms later or if it is the last line (`:116-121`, `LyricGaps.kt:4`); a synthetic gap at
t=0 is inserted when the first line starts ≥ 4 s in (`:126-130`). Sorted by time.

**Enhanced / A2** (`EnhancedLrc.kt:14-62`): line `^\[m:ss.xx]`, then `<m:ss.xx>text` runs. Only starts are written, so each word runs until the next stamp and
the last until the next line; a final word with no successor gets `TAIL_MS = 800 ms` (`:44-46`, `:94`). A run with no trailing space is a syllable of a word
continuing into the next run — spacing is the word boundary (`:47-54`). No word stamps at all ⇒ return empty so the caller falls back (`:34`).

**Karaoke (QRC/YRC)** (`ProviderLyrics.kt:76-127`): lines `^\[startMs,durationMs]text`, word runs prefixed `(s,d[,0])text` or suffixed `text(s,d[,0])`; the
variant covering more characters wins (`:107`).

**TTML / Apple** (`TtmlLyrics.kt:20-70`): one `<p begin end ttm:agent>` per line, one `<span begin end>` per syllable. Whitespace, not the span boundary,
separates words, so adjacent spans with no gap are one word. `ttm:agent="x-bg"` is carried as background vocal; `x-translation` and `x-roman` roles are
**skipped** as duplicate renderings (`:38-52`). The document's own `<audio lyricOffset>` is ignored (`LrcRed.kt:26-28`).

**Plain text**: each non-empty line, `timeMs = 0` (`Unison.kt:75-79`). Two singers: `lineAlignments` assigns each line a side from agent/voice metadata
(`TtmlLyrics.kt:70-79`, `LyricsPlus.kt:130-143`).

### 3.4 Translation / romanisation

Google's unofficial endpoint, batched with private-use markers (`LyricsTranslation.kt:68-76`, `:334-373`):

- Translate: `POST https://translate.googleapis.com/translate_a/single`, form `client=dict-chrome-ex&sl={auto|src}&tl={target}&dt=t&q={batch}`.
- Romanise: same URL, `dt=rm` (`:376-388`).
- Latin-script retry: `POST https://inputtools.google.com/request` with `text`, `itc={src}-t-i0-und`, `num=1`, `cp=0`, `cs=1`, `ie=utf-8`, `oe=utf-8`
  (`:425-440`).
- Batches ≤ 3500 chars, ≤ 2 parallel requests, disk cache 2 MB (`:68-76`).

---

## 4. Settings

`AppSettings` is a `SharedPreferences` object (`"bitchord_settings"`, `AppSettings.kt:883`) exposed as `MutableStateFlow`s; names below are the Kotlin property
names.

### 4.1 Playback / quality

| Name | Type | Default | Allowed |
|---|---|---|---|
| `audioQualityWifi` | `AudioQuality` | `LOSSLESS` | LOW, MEDIUM, HIGH, LOSSLESS (`:196`) |
| `audioQualityCellular` | `AudioQuality` | `LOSSLESS` | same (`:197`) |
| `downloadQuality` | `DownloadQuality` | `LOSSLESS` | STANDARD(128k), HIGH(best), LOSSLESS(bit-exact) (`:104-123`, `:219`) |
| `wifiOnlyDownloads` | Bool | `true` | (`:236`) |
| `exportDownloads`, `syncDownloadedPlaylists`, `showCacheFolder` | Bool | `false` | (`:244`, `:251`, `:619`) |
| `upgradeLengthSlackSeconds` | Int | `5` | seconds, used as ± (`:200`, `:2119`) |
| `crossfadeSeconds` | Int | `0` (off) | (`:263`) |
| `smartFadeEnabled` | Bool | `false` | Automix timing replaces the fixed window (`:275`) |
| `skipSilence` | Bool | `false` | (`:279`) |
| `playbackSpeed` | Float | `1.0` | (`:410`) |
| `loudnessNormalization` | Bool | `true` | (`:324`) |
| `loudnessOffOnSpeaker` | Bool | `true` | (`:327`) |
| `dolbyAtmos` | Bool | `true` | (`:351`) |
| `spatialAudio`, `directSourceStream` | Bool | `false` | (`:370`, `:362`) |
| `automixPerformanceMode` | enum | `BALANCED` | EFFICIENT(1), BALANCED(2), PERFORMANCE(4) (`:278`) |
| `autoplay` | Bool | `true` | (`:415`) |
| `shuffleEnabled`, `dontRepeatSuggestions` | Bool | `false` | (`:418`, `:463`) |
| `repeatMode` | Int (Media3) | `REPEAT_MODE_OFF` | OFF/ALL/ONE (`:421`) |
| `smartVersionAlignment` | Bool | `true` | (`:466`) |
| `audioCacheLimitBytes` | Long | 512 MiB | ≥512 MiB; above max ⇒ unlimited (`:611`, `:2110-2118`) |

### 4.2 Audio output (Android-specific)

`outputPcmMode` = `PCM_16` | `FLOAT_32` (`:282`, `:56-59`); `preferUsbDac` = false (`:285`); `bitPerfectMode` = `OFF` | `USB_DIRECT` | `DAP_EXCLUSIVE` |
`USB_ANDROID` (`:288`, `:72-86`); `usbAllowFixedVolume` = false (`:295`); `convertForLimitedDac` = false (`:302`); `equalizerEnabled` = false (`:381`);
`equalizerMode` = `DYNAMIC` | `MANUAL` (`:384`); `equalizerToneX/Y` = 0; `equalizerFocused` = false; `equalizerBalance` = 0f; `equalizerBands` =
`EqualizerPreset.FLAT.bands`; `equalizerPreset` = `FLAT` (`:387-408`).

### 4.3 Appearance

| Name | Type | Default | Allowed |
|---|---|---|---|
| `themeMode` | `ThemeMode` | `DARK` | SYSTEM, LIGHT, DARK (`:411`, `:125-127`) |
| `appFont` | `AppFont` | `DEFAULT` | DEFAULT, LEGACY (`:412`, `:134`) |
| `reduceAnimation`, `reduceDynamicBlur`, `legacyMeshGradient` | Bool | `false` | (`:430`, `:469`, `:567`) |
| `liquidGlass`, `progressiveBlur` | Bool | `false` | blur; progressive needs liquidGlass (`:472`, `:480`) |
| `fullBleedArtwork` | Bool | `true` | (`:550`) |
| `hideVolumeBar`, `hideStatusBarInPlayer`, `hideSongStatus` | Bool | `false` | (`:449-455`) |
| `highPerformanceMode` | Bool | `false` | (`:440`) |
| `performanceRefreshRate` | Int | `120` | clamped 50..240 (`:443`, `:2123-2126`) |
| `showNerdStats`, `showQueueHistory`, `swipeToPlayNext` | Bool | `false` | (`:424`, `:457`, `:460`) |
| `lastPlayerScreen` | enum | `MAIN` | MAIN, LYRICS, QUEUE (`:570`, `:31-35`) |
| `onboardingComplete` | Bool | `false` | (`:437`) |
| `stopOnTaskRemoved` | Bool | `true` | (`:446`) |

### 4.4 Lyrics

| Name | Type | Default | Allowed |
|---|---|---|---|
| `syncedLyrics` | Bool | `true` | (`:579`) |
| `lyricsSources` | `Set<LyricsSource>` | all `offered` (15 of the 17 — 2 are `hidden`) | §3.2 (`:582`) |
| `lyricsSourceOrder` | `List<LyricsSource>` | `offered` order | any permutation (`:592`) |
| `prioritizeSyllableSync` | Bool | `false` | (`:602`) |
| `lyricsBlur` | Bool | `true` | (`:483`) |
| `lyricsOffsetMs` | Int | `0` | positive delays lyrics (`:486`) |
| `translationLanguage` | String | `""` = app language | BCP-47 tag (`:497`) |
| `paxSenixApiKey` | String | `""` | required by api.paxsenix.org (`:605`) |

### 4.5 Library, media, integrations (abridged)

`filterNonMusicAudio` = true (`:638`); `localMusicSort` / `downloadedMusicSort` = `TITLE_ASC` (`:640-641`); the two view types = `LIST` (`:642-643`,
`LibraryEnums.kt:16-19`); `librarySort` = `DEFAULT` (DEFAULT/TITLE_ASC/TITLE_DESC, `LibraryEnums.kt:8-14`); `detailSongSorts` = `{}`; `localMusicFolderUri`,
`webdav*` and `smb*` = `""`; `lastfmEnabled` / `lastfmScrobbleEnabled` / `lastfmNowPlaying` = false with `scrobbleMinDuration` = `30` s, `scrobbleDelayPercent`
= `0.5`, `scrobbleDelaySeconds` = `180`; `listenBrainzEnabled` = false; `discordRpcEnabled` / `discordShowAudioQuality` = true (`:706-767`); `animatedCanvas` =
true, `canvasOverCellular` = false (`:508`, `:524`); `replayGenres` = true (`:633`). `streamCeilingOverride` (`:840`) is *not* persisted — a runtime cap used
while another device holds the music.

---

## 5. Swift client notes

**Implement first — this is the whole product:**

1. InnerTube client: `POST https://music.youtube.com/youtubei/v1/{endpoint}`, `WEB_REMIX` + client name 67 + the live `INNERTUBE_CLIENT_VERSION` (pin the fallback,
   refresh lazily by scraping `music.youtube.com`). Guest browsing needs no cookie and no SAPISIDHASH.
2. `visitorData` from `GET https://www.youtube.com/sw.js_data` (regex `Cg[A-Za-z0-9_%-]{40,}`). Do not skip it — without one the `player` endpoint returns URLs
   that 403 after the first read.
3. `browse("FEmusic_home")` + continuation, anonymous `search`, `next` (`RDAMVM{videoId}`) for radio. Three renderers cover home, search, library and playlists:
   `musicResponsiveListItemRenderer`, `musicTwoRowItemRenderer`, `musicCarouselShelfRenderer`.
4. Stream: `player` as `WEB_REMIX` (or `IOS`), read `streamingData.adaptiveFormats`/`formats`, prefer AAC-in-MP4 then Opus-in-WebM, highest `bitrate` under the
   ceiling, and resolve `signatureCipher`/`n` with an embedded JS runtime. **Probe the URL with a ranged GET expecting `audio/*` and ≥16 KiB before handing it to
   AVPlayer** — that one step separates "fails" from "fails instantly".
5. Lyrics: LRCLIB (keyless, line-synced, always up) + lrc.red/TTML for word timing
   + YouTube Music's Lyrics tab as plain text. That is most of the value of 17 providers.
6. Settings: theme (DARK), font, `audioQualityWifi`/`Cellular`, crossfade (0), skip silence, playback speed, lyrics on/off + source order, download quality.

**Droppable for a 1.0:** InnerTubeX's benchmarked client catalog, cipher tiers, EJS player cache and remote player config (one well-chosen client plus a
signature solver covers most tracks); PoToken/BotGuard, needed only for age-restricted playback — degrade to "sign in"; addons, JioSaavn, module indexes, the
lossless upgrade ladder, `q=hifi` re-pointing and StreamChoice's cache-corruption machinery, all of which exist to make *substitution* safe and none of which
applies with YouTube alone; 10 of the 17 lyric providers (PaxSenix ×3, Musixmatch, KuGou, Genius, Megalobiz, Unison, SimpMusic, LyricsPlus mirrors), each a
scraper that will rot — keep the chain generic so they can return later; translation/romanisation, bit-perfect USB output, Automix, Replay, Discord/SMB/WebDAV,
watch/TV surfaces.

**Keep the invariants, not the code:** never play an unprobed URL; cap quality by the *connection's* ceiling rather than globally; treat a line-synced match as
an answer and only chase word timing when asked; and keep "skip a track that never made a sound, but stop after 4 in a row" (`PlaybackService.kt:4386-4394`) —
that is the difference between a skip and a queue that eats itself while offline.
