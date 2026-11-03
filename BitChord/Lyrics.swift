//
//  Lyrics.swift
//  BitChord for macOS
//
//  Lyrics, from every provider the phone knows that answers without an
//  account: LyricsPlus, LRCLIB, lrc.red (through BiniLyrics' ISRC), KuGou,
//  Unison — plus PaxSenix and BetterLyrics when a key is supplied.
//
//  Android counterpart: sharedUi data/lyrics/*.kt, where the same set is raced
//  concurrently and consumed in priority order.
//

import Foundation

// MARK: - Providers

enum LyricsSource: String, CaseIterable, Identifiable {
    case lyricsPlus = "lyricsplus"
    case lrcLib = "lrclib"
    case youtubeMusic = "ytmusic"
    case lrcRed = "lrcred"
    case biniLyrics = "binilyrics"
    case kuGou = "kugou"
    case unison = "unison"
    /// Last resort: plain text only, no timings. Carries songs the timed
    /// catalogues miss entirely.
    case ovh = "ovh"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .youtubeMusic: return "YouTube Music"
        case .lyricsPlus: return "LyricsPlus"
        case .lrcLib: return "LRCLIB"
        case .lrcRed: return "lrc.red"
        case .biniLyrics: return "BiniLyrics"
        case .kuGou: return "KuGou"
        case .unison: return "Unison"
        case .ovh: return "Lyrics.ovh"
        }
    }

    var detail: String {
        switch self {
        case .youtubeMusic: return "The service's own Lyrics tab"
        case .lyricsPlus: return "Word-level, Apple Music catalogue"
        case .lrcLib: return "Open LRC database, plain or synced"
        case .lrcRed: return "Apple Music TTML, word-level"
        case .biniLyrics: return "ISRC lookup for lrc.red"
        case .kuGou: return "Chinese catalogue, LRC"
        case .unison: return "Community synced lyrics"
        case .ovh: return "Texto completo, sem sincronia"
        }
    }


    /// The order the phone ships with: word-level sources first, then the ones
    /// that only have line timings.
    /// Timing first: word-level (karaoke) sources, then line-synced ones, then
    /// the plain-text providers. YouTube Music's own Lyrics tab is a last
    /// resort — it has the words for almost everything, but untimed.
    static let defaultOrder: [String] = [
        lrcRed.rawValue, biniLyrics.rawValue, lyricsPlus.rawValue,
        unison.rawValue, kuGou.rawValue, lrcLib.rawValue,
        youtubeMusic.rawValue, ovh.rawValue,
    ]
}

// MARK: - Store

@MainActor
final class LyricsStore: ObservableObject {
    @Published private(set) var lyrics: Lyrics = .empty
    @Published private(set) var isLoading = false
    @Published private(set) var loadedFor: String?
    @Published private(set) var failed = false
    @Published private(set) var attempts: [String] = []
    /// Provider being queried right now, for "Buscando em …" in the panels.
    @Published private(set) var currentProvider: String?

    private var task: Task<Void, Never>?

    func load(
        for song: Song,
        order: [String] = LyricsSource.defaultOrder,
        keys: [String: String] = [:],
        force: Bool = false
    ) {
        // A miss is not a verdict: reopen the player and it tries again, which
        // matters when a provider was slow or offline the first time.
        if !force, loadedFor == song.id, !lyrics.isEmpty { return }
        task?.cancel()
        loadedFor = song.id
        lyrics = .empty
        failed = false
        isLoading = true
        attempts = []

        task = Task { [weak self] in
            guard let self else { return }
            let result = await LyricsService.shared.find(
                song: song, order: order, keys: keys
            ) { provider in
                Task { @MainActor in
                    self.attempts.append(provider)
                    self.currentProvider = LyricsSource(rawValue: provider)?.label ?? provider
                }
            }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.lyrics = result ?? .empty
                self.isLoading = false
                self.failed = result == nil
                self.currentProvider = nil
            }
        }
    }

    #if SNAPSHOT
    func previewSet(_ value: Lyrics) {
        lyrics = value
        isLoading = false
        failed = false
        loadedFor = "preview"
    }
    #endif

    func clear() {
        task?.cancel()
        lyrics = .empty
        loadedFor = nil
        failed = false
        isLoading = false
        attempts = []
    }
}

// MARK: - Service

actor LyricsService {
    static let shared = LyricsService()

    private let session: URLSession
    private var cache: [String: Lyrics] = [:]

    func clearCache() {
        cache.removeAll()
        misses.removeAll()
    }
    private var misses: [String: Date] = [:]

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        session = URLSession(configuration: config)
    }

    static let agent = "BitChord-macOS/1.0 (https://github.com/kushagrasinghx/BitChord)"

    /// Walks the provider list in priority order and stops at the first one
    /// that answers — the phone's behaviour: no lyrics in lrc.red, try
    /// BiniLyrics, then BetterLyrics, and so on.
    ///
    /// Each provider gets its own short budget so one that hangs doesn't hold
    /// the screen while the next has the answer.
    func find(
        song: Song,
        order: [String],
        keys: [String: String],
        onAttempt: @escaping @Sendable (String) -> Void
    ) async -> Lyrics? {
        let key = "\(song.videoId)|\(song.title)|\(song.artist)"
        if let cached = cache[key] { return cached }
        // A miss is retried after a couple of minutes: providers time out, and
        // caching "nothing" for the whole session left songs without lyrics
        // until the app was restarted.
        if let missedAt = misses[key], Date().timeIntervalSince(missedAt) < 120 { return nil }

        // A source added after the user's order was saved still gets a turn, at
        // the end — otherwise upgrading never enables the new provider.
        var sequence = order.compactMap(LyricsSource.init(rawValue:))
        for source in LyricsSource.allCases where !sequence.contains(source) {
            sequence.append(source)
        }
        let providers = sequence
        guard !providers.isEmpty else { return nil }

        // Karaoke and video titles carry junk the lyric catalogues do not index
        // ("(Made Popular By …)", "[Instrumental Version]", "(Official Video)"),
        // so the providers are asked about the cleaned title as well.
        let queries = Self.lyricQueries(for: song)
        // Best unsynced answer, kept in case no provider has usable timings.
        var fallback: Lyrics?
        for provider in providers {
            onAttempt(provider.rawValue)
            for query in queries {
                let result = await withBudget(seconds: 3.5) {
                    await self.fetch(provider, song: query, key: keys[provider.rawValue])
                }
                // "Answered" is not the same as "has words": a provider that
                // returns a file of empty lines (an instrumental TTML, an
                // untimed stub) would stop the chain and leave the panel blank.
                if var result = result, Self.hasWords(result) {
                    // Timings that cannot belong to this recording are worse
                    // than no timings: the panel would scroll on its own clock.
                    // Ask the next provider instead of settling for a file whose
                    // clock is for another edit.
                    if result.synced, !Self.timingFits(result, duration: song.duration ?? 0) {
                        print("lyrics: \(provider.label) fora de tempo para \(query.title); tentando outra fonte")
                        // Keep the words, drop the clock: mistimed timings are
                        // worse than none, and the panel can still show the text.
                        result.synced = false
                        result.wordSynced = false
                        result.lines = result.lines.map { line in
                            var copy = line
                            copy.start = 0
                            copy.duration = nil
                            copy.words = nil
                            return copy
                        }
                        if fallback == nil { fallback = result }
                        continue
                    }
                    print("lyrics: \(provider.label) answered for \(query.title)")
                    cache[key] = result
                    return result
                }
            }
            print("lyrics: \(provider.label) had nothing for \(song.title)")
        }

        if let fallback {
            // Nothing carried trustworthy timings, but the words themselves are
            // still worth showing — untimed, and labelled as such.
            cache[key] = fallback
            return fallback
        }
        misses[key] = Date()
        return nil
    }

    /// Whether the line timings can belong to a track of this length. A karaoke
    /// LRC for another edit, or a file that ends at 20 s in a 4-minute song,
    /// would otherwise highlight the wrong line for the whole track.
    static func timingFits(_ lyrics: Lyrics, duration: TimeInterval) -> Bool {
        guard duration > 20, !lyrics.lines.isEmpty else { return true }
        let starts = lyrics.lines.map(\.start)
        guard let first = starts.first, let last = starts.last, last > first else { return false }
        guard lyrics.lines.count >= 3 else { return false }
        // The last sung line has to land near the end of the track: a file for a
        // longer edit finishes far too early, and one for a shorter edit runs
        // past the song. Both scroll on the wrong line for the whole track.
        // A real lyric sheet finishes inside the outro — normally within half a
        // minute of the end — and starts near the top. The windows are generous
        // enough for long instrumental outros, tight enough to reject a file for
        // a shorter edit of the same song.
        // Generous on the tail: a sheet that stops at the last chorus (before a
        // long outro) is still this song's lyrics, and the panel syncs fine.
        guard last >= duration * 0.5, last <= duration + 6 else { return false }
        guard first <= 30 else { return false }
        // A stub whose lines all sit inside ten seconds is not a lyric sheet.
        return (last - first) >= min(40, duration * 0.2)
    }

    /// Lines that actually carry text, which is what the panel draws.
    static func hasWords(_ lyrics: Lyrics) -> Bool {
        if !lyrics.instrumental,
           let plain = lyrics.plain?.trimmingCharacters(in: .whitespacesAndNewlines),
           !plain.isEmpty { return true }
        return lyrics.lines.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The song as the lyric catalogues know it: the original first, then a
    /// cleaned version without bracketed noise, then the title alone.
    static func lyricQueries(for song: Song) -> [Song] {
        var cleaned = song
        var title = song.title
        var artist = song.artist

        // "Song (Made Popular By X)" → artist X, title Song.
        if let range = title.range(of: "(Made Popular By", options: .caseInsensitive) {
            let tail = title[range.upperBound...]
            let make = tail.components(separatedBy: ")").first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !make.isEmpty { artist = make }
            title = String(title[..<range.lowerBound])
        }
        title = title.replacingOccurrences(of: "\\s*[\\(\\[][^\\)\\]]*[\\)\\]]", with: "",
                                           options: .regularExpression)
        title = title.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        artist = artist.components(separatedBy: ",").first?
            .replacingOccurrences(of: "feat.", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces) ?? artist
        guard !title.isEmpty else { return [song] }

        cleaned.title = title
        cleaned.artist = artist
        var titleOnly = cleaned
        titleOnly.artist = ""
        return [song, cleaned, titleOnly]
    }

    /// Runs `work` but gives up after `seconds`, so a dead provider costs one
    /// unit of patience instead of the whole lookup. Kept short on purpose: the
    /// chain is sequential, so this is multiplied by the number of providers
    /// that have nothing.
    private func withBudget(seconds: Double, _ work: @escaping () async -> Lyrics?) async -> Lyrics? {
        await withTaskGroup(of: Lyrics?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func fetch(_ source: LyricsSource, song: Song, key: String?) async -> Lyrics? {
        switch source {
        case .youtubeMusic: return await youtubeMusic(song)
        case .lyricsPlus: return await lyricsPlus(song)
        case .lrcLib: return await lrcLib(song)
        case .lrcRed: return await lrcRed(song)
        case .biniLyrics: return await lrcRed(song)
        case .kuGou: return await kuGou(song)
        case .unison: return await unison(song)
        case .ovh: return await ovh(song)
        }
    }

    /// Plain lyrics from lyrics.ovh: no timings, but it knows songs the timed
    /// databases do not. Only reached when everything else failed.
    private func ovh(_ song: Song) async -> Lyrics? {
        func clean(_ value: String) -> String {
            value.replacingOccurrences(of: "/", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Credited artists are often a list ("Lady Gaga e Dochii"); the service
        // only indexes the lead act, so both forms are tried.
        var artists = [clean(song.artist)]
        for separator in [" e ", ", ", " & ", " feat", " featuring ", " x "] {
            if let first = song.artist.components(separatedBy: separator).first,
               !first.isEmpty, first != song.artist {
                artists.append(clean(first))
            }
        }
        var text: String?
        for artist in artists {
            guard let encodedArtist = artist.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let encodedTitle = clean(song.title).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            else { continue }
            guard let url = URL(string: "https://api.lyrics.ovh/v1/\(encodedArtist)/\(encodedTitle)")
            else { continue }
            var request = URLRequest(url: url)
            request.setValue("BitGranada/2.0", forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let found = object["lyrics"] as? String, !found.isEmpty else { continue }
            text = found
            break
        }
        guard let text else { return nil }
        let lines = text.split(separator: "\n").enumerated().map { index, line in
            LyricLine(index: index, start: 0, text: String(line))
        }
        guard lines.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return nil }
        return Lyrics(lines: lines, plain: text, synced: false,
                      source: LyricsSource.ovh.label, instrumental: false)
    }

    /// YouTube Music's own Lyrics tab — the text the service shows for the exact
    /// video that is playing, which is why it answers for tracks the external
    /// databases do not carry. Same two calls as the phone: `next` to find the
    /// Lyrics tab, then `browse` its endpoint.
    private func youtubeMusic(_ song: Song) async -> Lyrics? {
        guard let lines = await InnerTubeClient.shared.musicLyrics(videoId: song.videoId),
              !lines.isEmpty else { return nil }
        let text = lines.joined(separator: "\n")
        let parsed = lines.enumerated().map { index, line in
            LyricLine(index: index, start: 0, text: line)
        }
        return Lyrics(lines: parsed, plain: text, synced: false,
                      source: LyricsSource.youtubeMusic.rawValue)
    }

    // MARK: HTTP

    private func get(_ url: String, headers: [String: String] = [:]) async -> Data? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else { return nil }
        return data
    }

    private static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private static func artist(_ song: Song) -> String {
        primaryArtist(song.artist)
    }

    private static func seconds(_ song: Song) -> Int {
        Int(song.duration ?? 0)
    }

    // MARK: Providers

    /// LyricsPlus — word-level lines from the Apple Music catalogue. Several
    /// volunteer mirrors; the first that answers with usable JSON wins.
    private func lyricsPlus(_ song: Song) async -> Lyrics? {
        let mirrors = [
            "https://lyricsplus.binimum.org",
            "https://lyricsplus.prjktla.my.id",
            "https://lyricsplus.atomix.one",
            "https://lyricsplus.prjktla.workers.dev",
        ]
        let query = "title=\(Self.encoded(song.title))&artist=\(Self.encoded(Self.artist(song)))"
            + (song.album.map { "&album=\(Self.encoded($0))" } ?? "")
            + (song.duration.map { "&duration=\(Int($0))" } ?? "")

        for mirror in mirrors {
            guard let data = await get("\(mirror)/v2/lyrics/get?\(query)"),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawLines = object["lyrics"] as? [[String: Any]], !rawLines.isEmpty else { continue }

            var lines: [LyricLine] = []
            var wordSynced = false
            for (index, raw) in rawLines.enumerated() {
                guard let text = raw["text"] as? String else { continue }
                let start = (raw["time"] as? Double ?? 0) / 1000
                let duration = (raw["duration"] as? Double ?? 0) / 1000
                var words: [LyricWord]?
                if let syllables = raw["syllabus"] as? [[String: Any]], !syllables.isEmpty {
                    wordSynced = true
                    words = syllables.compactMap { syllable in
                        guard let text = syllable["text"] as? String else { return nil }
                        let start = (syllable["time"] as? Double ?? 0) / 1000
                        let length = (syllable["duration"] as? Double ?? 0) / 1000
                        return LyricWord(text: text, start: start, end: start + length)
                    }
                }
                lines.append(LyricLine(index: index, start: start, text: text, words: words, duration: duration))
            }
            guard !lines.isEmpty else { continue }
            let instrumental = lines.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            if instrumental {
                return Lyrics(lines: [], plain: nil, synced: true, source: "LyricsPlus", instrumental: true)
            }
            return Lyrics(lines: lines, plain: lines.map(\.text).joined(separator: "\n"),
                          synced: true, source: "LyricsPlus", wordSynced: wordSynced)
        }
        return nil
    }

    /// LRCLIB — the open database. `get` is an exact match; `search` covers the
    /// cases where the metadata differs from how the track was filed.
    private func lrcLib(_ song: Song) async -> Lyrics? {
        var query = "artist_name=\(Self.encoded(Self.artist(song)))&track_name=\(Self.encoded(song.title))"
        if let album = song.album { query += "&album_name=\(Self.encoded(album))" }
        if let duration = song.duration { query += "&duration=\(Int(duration))" }

        if let data = await get("https://lrclib.net/api/get?\(query)"),
           let object = try? JSONSerialization.jsonObject(with: data) {
            if let lyrics = Self.parseLrcLib(JSON(object)) { return lyrics }
        }
        let search = "https://lrclib.net/api/search?q=\(Self.encoded("\(Self.artist(song)) \(song.title)"))"
        guard let data = await get(search),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        for raw in array.prefix(4) {
            if let lyrics = Self.parseLrcLib(JSON(raw)) { return lyrics }
        }
        return nil
    }

    private static func parseLrcLib(_ object: JSON) -> Lyrics? {
        if object["instrumental"].value as? Bool == true {
            return Lyrics(lines: [], plain: nil, synced: true, source: "LRCLIB", instrumental: true)
        }
        if let synced = object["syncedLyrics"].string, !synced.isEmpty {
            let lines = parseLRC(synced)
            if !lines.isEmpty {
                return Lyrics(lines: lines, plain: object["plainLyrics"].string,
                              synced: true, source: "LRCLIB")
            }
        }
        if let plain = object["plainLyrics"].string, !plain.isEmpty {
            return Lyrics(lines: [], plain: plain, synced: false, source: "LRCLIB")
        }
        return nil
    }

    /// lrc.red — a TTML document per ISRC. The ISRC comes from BiniLyrics,
    /// which is exactly what the phone does.
    private func lrcRed(_ song: Song) async -> Lyrics? {
        guard let isrc = await biniLookup(song) else { return nil }
        guard let data = await get("https://lrc.red/s/\(isrc).ttml"),
              let ttml = String(data: data, encoding: .utf8) else { return nil }
        let lines = Self.parseTTML(ttml)
        guard !lines.isEmpty else { return nil }
        return Lyrics(
            lines: lines,
            plain: lines.map(\.text).joined(separator: "\n"),
            synced: true, source: "lrc.red",
            wordSynced: lines.contains { !($0.words ?? []).isEmpty }
        )
    }

    private func biniLookup(_ song: Song) async -> String? {
        guard let data = await get("https://lyrics-api.binimum.org/?track=\(Self.encoded(song.title))"
                                   + "&artist=\(Self.encoded(Self.artist(song)))"
                                   + (song.album.map { "&album=\(Self.encoded($0))" } ?? "")
                                   + (song.duration.map { "&duration=\(Int($0))" } ?? "")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { return nil }
        return results.first?["isrc"] as? String
    }

    /// KuGou — search by hash, then the LRC download endpoint (base64).
    private func kuGou(_ song: Song) async -> Lyrics? {
        let keyword = Self.encoded("\(Self.artist(song)) \(song.title)")
        guard let searchData = await get(
            "https://mobileservice.kugou.com/api/v3/search/song?version=9108&plat=0&pagesize=8&showtype=0&keyword=\(keyword)"
        ),
        let searchObject = try? JSONSerialization.jsonObject(with: searchData) as? [String: Any],
        let data = searchObject["data"] as? [String: Any],
        let info = data["info"] as? [[String: Any]], !info.isEmpty else { return nil }

        let wanted = Self.seconds(song)
        let ranked = info
            .filter { item in
                guard wanted > 0, let duration = item["duration"] as? Int else { return true }
                return abs(duration - wanted) <= 5
            }
            .sorted { lhs, rhs in
                abs((lhs["duration"] as? Int ?? 0) - wanted) < abs((rhs["duration"] as? Int ?? 0) - wanted)
            }
        guard let hash = ranked.first?["hash"] as? String ?? info.first?["hash"] as? String else { return nil }

        guard let lyricSearch = await get(
            "https://lyrics.kugou.com/search?ver=1&man=yes&client=pc&hash=\(hash)"
        ),
        let searchJSON = try? JSONSerialization.jsonObject(with: lyricSearch) as? [String: Any],
        let candidates = searchJSON["candidates"] as? [[String: Any]],
        let candidate = candidates.first else { return nil }

        let id: String
        if let number = candidate["id"] as? Int { id = String(number) }
        else if let text = candidate["id"] as? String { id = text }
        else { return nil }
        guard let accessKey = candidate["accesskey"] as? String else { return nil }

        guard let download = await get(
            "https://lyrics.kugou.com/download?fmt=lrc&charset=utf8&client=pc&ver=1&id=\(id)&accesskey=\(Self.encoded(accessKey))"
        ),
        let downloadJSON = try? JSONSerialization.jsonObject(with: download) as? [String: Any],
        let content = downloadJSON["content"] as? String,
        let decoded = Data(base64Encoded: content),
        let text = String(data: decoded, encoding: .utf8) else { return nil }

        let lines = Self.parseLRC(text)
        guard !lines.isEmpty else { return nil }
        return Lyrics(lines: lines, plain: lines.map(\.text).joined(separator: "\n"),
                      synced: true, source: "KuGou")
    }

    /// Unison — community database; JSON with a lines array when it has a hit.
    private func unison(_ song: Song) async -> Lyrics? {
        var url = "https://unison.boidu.dev/lyrics?song=\(Self.encoded(song.title))"
            + "&artist=\(Self.encoded(Self.artist(song)))"
        if let album = song.album { url += "&album=\(Self.encoded(album))" }
        if let duration = song.duration { url += "&duration=\(Int(duration))" }
        guard let data = await get(url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let rawLines = (object["lyrics"] as? [[String: Any]])
            ?? ((object["data"] as? [String: Any])?["lyrics"] as? [[String: Any]])
            ?? (object["lines"] as? [[String: Any]])
        guard let rawLines else { return nil }

        var lines: [LyricLine] = []
        for (index, raw) in rawLines.enumerated() {
            guard let text = raw["text"] as? String ?? raw["line"] as? String else { continue }
            var start = 0.0
            if let ms = raw["time"] as? Double { start = ms / 1000 }
            else if let ms = raw["start"] as? Double { start = ms / 1000 }
            else if let stamp = raw["startTime"] as? Double { start = stamp }
            lines.append(LyricLine(index: index, start: start, text: text, words: nil, duration: nil))
        }
        guard !lines.isEmpty else { return nil }
        return Lyrics(lines: lines, plain: lines.map(\.text).joined(separator: "\n"),
                      synced: true, source: "Unison")
    }

    // MARK: Parsing

    /// `[mm:ss.xx]` lines, including several stamps on one line and
    /// word-level `<mm:ss.xx>` tags.
    static func parseLRC(_ text: String) -> [LyricLine] {
        struct Raw { var time: TimeInterval; var text: String }
        var raws: [Raw] = []
        let stampPattern = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#)

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let regex = stampPattern else { continue }
            let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
            guard !matches.isEmpty else { continue }
            let lastEnd = matches.map { $0.range.upperBound }.max() ?? 0
            let content = String(line[line.index(line.startIndex, offsetBy: lastEnd)...])
                .trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let minutesRange = Range(match.range(at: 1), in: line),
                      let secondsRange = Range(match.range(at: 2), in: line) else { continue }
                let minutes = Double(line[minutesRange]) ?? 0
                let seconds = Double(line[secondsRange]) ?? 0
                var fraction = 0.0
                if let fractionRange = Range(match.range(at: 3), in: line) {
                    let digits = String(line[fractionRange])
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                raws.append(Raw(time: minutes * 60 + seconds + fraction, text: content))
            }
        }
        raws.sort { $0.time < $1.time }

        return raws.enumerated().map { index, raw in
            LyricLine(index: index, start: raw.time, text: raw.text, words: nil, duration: nil)
        }
    }

    /// Apple Music TTML: `<p begin="…" end="…">` lines, `<span begin end>` words.
    static func parseTTML(_ xml: String) -> [LyricLine] {
        let delegate = TTMLDelegate()
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.lines.enumerated().map { index, line in
            LyricLine(index: index, start: line.start,
                      text: line.text.trimmingCharacters(in: .whitespacesAndNewlines),
                      words: line.words.isEmpty ? nil : line.words,
                      duration: line.end > line.start ? line.end - line.start : nil)
        }
    }

    final class TTMLDelegate: NSObject, XMLParserDelegate {
        struct Line { var start: TimeInterval = 0; var end: TimeInterval = 0; var text = ""; var words: [LyricWord] = [] }
        var lines: [Line] = []
        private var current: Line?
        private var inSpan = false
        private var spanBuffer = ""
        private var spanStart: TimeInterval = 0
        private var spanEnd: TimeInterval = 0

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            switch elementName {
            case "p":
                current = Line(start: Self.time(attributeDict["begin"]),
                               end: Self.time(attributeDict["end"]), text: "", words: [])
            case "span":
                inSpan = true
                spanBuffer = ""
                spanStart = Self.time(attributeDict["begin"])
                spanEnd = Self.time(attributeDict["end"])
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inSpan {
                spanBuffer += string
            } else if current != nil {
                current?.text += string
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            if elementName == "span" {
                inSpan = false
                let word = spanBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !word.isEmpty, current != nil {
                    current?.words.append(LyricWord(text: word + " ", start: spanStart, end: spanEnd))
                }
                spanBuffer = ""
            } else if elementName == "p" {
                if var line = current {
                    if line.text.isEmpty { line.text = line.words.map(\.text).joined() }
                    lines.append(line)
                }
                current = nil
            }
        }

        static func time(_ value: String?) -> TimeInterval {
            guard let value else { return 0 }
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.replacingOccurrences(of: "s", with: "").split(separator: ":")
            var seconds = 0.0
            for part in parts { seconds = seconds * 60 + (Double(part) ?? 0) }
            return seconds
        }
    }

    // MARK: Song text helpers

    /// "Daft Punk, Pharrell Williams & Nile Rodgers" → "Daft Punk"
    static func primaryArtist(_ artist: String) -> String {
        var name = artist
        for separator in [",", "&", " feat.", " featuring", " x ", " X "] {
            if let range = name.range(of: separator) {
                name = String(name[..<range.lowerBound])
            }
        }
        return name.trimmingCharacters(in: .whitespaces)
    }
}
