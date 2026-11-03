//
//  SpotifyCanvas.swift
//  BitChord for macOS
//
//  Spotify Canvas with the listener's own session. The Android build mints a
//  bearer from the `sp_dc` cookie by loading the real web player offscreen and
//  reading the token it mints for itself; Spotify retired the direct endpoint
//  and signs the replacement with a TOTP, so that is the only door left. This
//  is the same trick with WKWebView.
//
//  Android counterpart: data/canvas/SpotifyToken.kt + SpotifyCanvas.kt.
//

import Foundation
import WebKit
import AppKit

// MARK: - Keychain

enum SpotifySecrets {
    /// The cookie lives in the app's own preferences, not the Keychain.
    ///
    /// It used to go to a `kSecClassGenericPassword` item, which on an ad-hoc
    /// signed build makes macOS ask for authorisation on every write and every
    /// read — a dialog per canvas. A personal `sp_dc` in the app's preferences
    /// is the same exposure as the browser cookie it was copied from, and the
    /// app asks for nothing.
    private static let defaultsKey = "bitchord.spotify.sp_dc"

    static func saveCookie(_ value: String) {
        UserDefaults.standard.set(value, forKey: defaultsKey)
        Task { @MainActor in SpotifyTokenProvider.shared.invalidate() }
    }

    static var cookie: String? {
        guard let value = UserDefaults.standard.string(forKey: defaultsKey),
              !value.isEmpty else { return nil }
        return value
    }

    static func deleteCookie() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        Task { @MainActor in SpotifyTokenProvider.shared.invalidate() }
    }

    static var hasCookie: Bool { cookie != nil }
}

// MARK: - Token provider

@MainActor
final class SpotifyTokenProvider {
    static let shared = SpotifyTokenProvider()

    private var token: String?
    private var clientId: String?
    private var expiresAt = Date.distantPast
    private var inFlight: Task<String?, Never>?
    private var harvester: SpotifyTokenHarvester?

    var isConnected: Bool { SpotifySecrets.hasCookie }

    /// The web player's client id, which the client-token endpoint asks for.
    func clientIdentifier() -> String? { clientId }

    func invalidate() {
        token = nil
        expiresAt = .distantPast
        harvester = nil
    }

    /// A logged-in bearer, minted from the saved cookie. Cached for the life of
    /// the token so a skip through a queue doesn't pay for a web-player load.
    func accessToken(forceRefresh: Bool = false) async -> String? {
        if !forceRefresh, let token, Date() < expiresAt.addingTimeInterval(-60) {
            return token
        }
        if let inFlight { return await inFlight.value }

        guard let cookie = SpotifySecrets.cookie else { return nil }
        let task = Task<String?, Never> { [weak self] in
            guard let self else { return nil }
            let harvester = SpotifyTokenHarvester()
            self.harvester = harvester
            let result = await harvester.harvest(cookie: cookie)
            await MainActor.run {
                self.harvester = nil
                if let result {
                    self.token = result.token
                    self.expiresAt = result.expiresAt
                    self.clientId = result.clientId
                }
            }
            return result?.token
        }
        inFlight = task
        let value = await task.value
        inFlight = nil
        // The harvest web view has done its job; keep the token, drop the web
        // process it needed.
        harvester?.releaseWebView()
        harvester = nil
        return value
    }
}

// MARK: - Harvester

@MainActor
private final class SpotifyTokenHarvester: NSObject, WKScriptMessageHandler {
    struct Token {
        var token: String
        var expiresAt: Date
        var clientId: String?
    }

    private var webView: WKWebView?

    /// Drops the harvest web view once the token is in hand: a live WKWebView
    /// holds a whole web process, which is the single biggest thing the app can
    /// leak between runs.
    func releaseWebView() {
        webView?.stopLoading()
        webView = nil
    }
    private var window: NSWindow?
    private var continuation: CheckedContinuation<Token?, Never>?
    private var finished = false

    /// The hook: the page mints its token through `/api/token`, so both the
    /// fetch and XHR paths are wrapped and the response body is handed back.
    private static let hook = """
    (function () {
      if (window.__bitchordTokenHook) return;
      window.__bitchordTokenHook = true;
      var report = function (body) {
        try { window.webkit.messageHandlers.spotifyToken.postMessage(body); } catch (e) {}
      };
      var isToken = function (u) {
        try { return String(u).indexOf('/api/token') !== -1; } catch (e) { return false; }
      };
      var origFetch = window.fetch;
      if (origFetch) {
        window.fetch = function (input, init) {
          var url = (input && input.url) ? input.url : input;
          var result = origFetch.apply(this, arguments);
          if (isToken(url)) {
            try {
              result.then(function (res) {
                res.clone().text().then(report).catch(function () {});
              }).catch(function () {});
            } catch (e) {}
          }
          return result;
        };
      }
      var origOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__bitchordUrl = url;
        return origOpen.apply(this, arguments);
      };
      var origSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function () {
        var xhr = this;
        try {
          xhr.addEventListener('load', function () {
            if (isToken(xhr.__bitchordUrl)) {
              try { report(xhr.responseText); } catch (e) {}
            }
          });
        } catch (e) {}
        return origSend.apply(this, arguments);
      };
    })();
    """

    func harvest(cookie: String, timeout: TimeInterval = 30) async -> Token? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.finish(nil)
            }
            start(cookie: cookie)
        }
    }

    private func start(cookie: String) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.add(self, name: "spotifyToken")
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.hook, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self

        let window = NSWindow(
            contentRect: NSRect(x: -2400, y: -2400, width: 480, height: 640),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.alphaValue = 0
        window.orderFrontRegardless()

        self.webView = webView
        self.window = window

        let properties: [HTTPCookiePropertyKey: Any] = [
            .domain: ".spotify.com",
            .path: "/",
            .name: "sp_dc",
            .value: cookie,
            .secure: "TRUE",
            .expires: Date().addingTimeInterval(60 * 60 * 24 * 30),
        ]
        if let httpCookie = HTTPCookie(properties: properties) {
            webView.configuration.websiteDataStore.httpCookieStore.setCookie(httpCookie) { [weak webView] in
                webView?.load(URLRequest(url: URL(string: "https://open.spotify.com/")!))
            }
        } else {
            webView.load(URLRequest(url: URL(string: "https://open.spotify.com/")!))
        }
    }

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    private func finish(_ token: Token?) {
        guard !finished else { return }
        finished = true
        continuation?.resume(returning: token)
        continuation = nil
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "spotifyToken")
        webView = nil
        window?.orderOut(nil)
        window = nil
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String, let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["accessToken"] as? String, !accessToken.isEmpty else { return }

        // The player mints an anonymous token before the cookie takes effect;
        // that one can't read canvases.
        let anonymous = object["isAnonymous"] as? Bool ?? false
        if anonymous { return }

        let expirationMs = (object["accessTokenExpirationTimestampMs"] as? NSNumber)?.doubleValue ?? 0
        let expiresAt = expirationMs > 0
            ? Date(timeIntervalSince1970: expirationMs / 1000)
            : Date().addingTimeInterval(3600)
        let clientId = object["clientId"] as? String
        finish(Token(token: accessToken, expiresAt: expiresAt, clientId: clientId))
    }
}

extension SpotifyTokenHarvester: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // The player may have cached the token in storage and skip the
            // request altogether; poking its own token call forces a mint.
            webView.evaluateJavaScript(
                "fetch('/api/token?reason=transport&productType=web_player').catch(function(){})",
                completionHandler: nil
            )
        }
    }
}

// MARK: - Client token

/// The second header Spotify's endpoints demand alongside the bearer: a token
/// minted at `clienttoken.spotify.com` from the web player's own client id,
/// version and device id. Without it both search and canvaz-cache answer 429.
actor SpotifyClientTokenProvider {
    static let shared = SpotifyClientTokenProvider()

    private var token: String?
    private var expiresAt = Date.distantPast
    private var inFlight: Task<String?, Never>?

    func token(cookie: String) async -> String? {
        if let token, Date() < expiresAt.addingTimeInterval(-60) { return token }
        if let inFlight { return await inFlight.value }

        let task = Task<String?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.mint(cookie: cookie)
        }
        inFlight = task
        let value = await task.value
        inFlight = nil
        return value
    }

    private func mint(cookie: String) async -> String? {
        guard let session = await sessionInfo(cookie: cookie),
              let clientId = await SpotifyTokenProvider.shared.clientIdentifier() else {
            print("spotify: no session info or client id for a client token")
            return nil
        }

        let payload: [String: Any] = [
            "client_data": [
                "client_version": session.clientVersion,
                "client_id": clientId,
                "js_sdk_data": [
                    "device_brand": "Apple",
                    "device_model": "Macintosh",
                    "os": "macos",
                    "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
                    "device_id": session.deviceId,
                    "device_type": "computer",
                ],
            ],
        ]
        var request = URLRequest(url: URL(string: "https://clienttoken.spotify.com/v1/clienttoken")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("spotify: clienttoken failed")
            return nil
        }
        let granted = (object["granted_token"] as? [String: Any])?["token"] as? String
        let expiresIn = (object["granted_token"] as? [String: Any])?["refresh_after_seconds"] as? Double
        token = granted
        expiresAt = Date().addingTimeInterval(expiresIn ?? 600)
        print("spotify: client token \(granted == nil ? "missing" : "ok")")
        return granted
    }

    private struct Session {
        var clientVersion: String
        var deviceId: String
    }

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    /// Reads the web player's own `appServerConfig` block for its client
    /// version, and keeps the `sp_t` cookie as the device id.
    private func sessionInfo(cookie: String) async -> Session? {
        var request = URLRequest(url: URL(string: "https://open.spotify.com")!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("sp_dc=\(cookie)", forHTTPHeaderField: "Cookie")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8) else { return nil }

        let deviceId = (response as? HTTPURLResponse)?.allHeaderFields
            .compactMap { key, value -> String? in
                guard let name = key as? String, name.lowercased() == "set-cookie",
                      let text = value as? String else { return nil }
                guard let range = text.range(of: "sp_t=") else { return nil }
                let rest = text[range.upperBound...]
                return String(rest.prefix { $0 != ";" })
            }
            .first ?? UUID().uuidString

        guard let configRange = html.range(of: #"<script id="appServerConfig" type="text/plain">"#, options: .regularExpression),
              let close = html.range(of: "</script>", range: configRange.upperBound..<html.endIndex) else {
            return nil
        }
        let base64 = String(html[configRange.upperBound..<close.lowerBound])
        guard let configData = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let version = config["clientVersion"] as? String else {
            return nil
        }
        return Session(clientVersion: version, deviceId: deviceId)
    }
}

// MARK: - Canvas lookup

actor SpotifyCanvasService {
    static let shared = SpotifyCanvasService()

    private let session: URLSession
    private var cache: [String: URL] = [:]
    private var misses: Set<String> = []

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    private static let appUserAgent = "Spotify/9.0.34.593 iOS/18.4 (iPhone15,3)"
    private static let canvasURL = URL(string: "https://spclient.wg.spotify.com/canvaz-cache/v0/canvases")!
    private static let canvasPattern = try! NSRegularExpression(
        pattern: #"https://[^"'\s\x00-\x1F]+\.cnvs\.mp4"#
    )

    /// Spotify throttles this IP with 429/403 for a while; retrying on every
    /// track only delayed the fallbacks, so the whole service rests.
    private var coolingUntil = Date.distantPast
    private var isCooling: Bool { Date() < coolingUntil }

    func noteThrottled() {
        coolingUntil = Date().addingTimeInterval(10 * 60)
        print("spotify: canvas em espera até \(coolingUntil.formatted(date: .omitted, time: .standard))")
    }

    func clip(for song: Song) async -> CanvasClip? {
        let key = "\(song.title)|\(song.artist)"
        if isCooling { return nil }
        if let hit = cache[key] {
            return CanvasClip(url: hit, song: song.title, artist: song.artist, album: song.album)
        }
        if misses.contains(key) { return nil }

        guard let token = await SpotifyTokenProvider.shared.accessToken() else {
            print("spotify: no access token (cookie \(SpotifySecrets.hasCookie ? "present" : "missing"))")
            misses.insert(key)
            return nil
        }
        print("spotify: token \(token.prefix(12))…")
        let clientToken = await clientTokenForRequests()
        var uri = await trackURI(song: song, token: token, clientToken: clientToken)
        if uri == nil {
            uri = await trackURIviaPathfinder(song: song, token: token, clientToken: clientToken)
        }
        guard let uri else {
            misses.insert(key)
            return nil
        }
        guard let url = await canvasURL(trackURI: uri, token: token, clientToken: clientToken) else {
            misses.insert(key)
            return nil
        }
        cache[key] = url
        return CanvasClip(url: url, song: song.title, artist: song.artist, album: song.album)
    }

    func invalidate() {
        cache.removeAll()
        misses.removeAll()
    }

    // MARK: Search

    private func clientTokenForRequests() async -> String? {
        guard let cookie = SpotifySecrets.cookie else { return nil }
        return await SpotifyClientTokenProvider.shared.token(cookie: cookie)
    }

    private func trackURI(song: Song, token: String, clientToken: String?) async -> String? {
        let query = [song.title, CanvasService.normalize(song.artist)].joined(separator: " ")
        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.appUserAgent, forHTTPHeaderField: "User-Agent")
        if let clientToken { request.setValue(clientToken, forHTTPHeaderField: "Client-Token") }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracks = object["tracks"] as? [String: Any],
              let items = tracks["items"] as? [[String: Any]] else {
            let code = (try? await session.data(for: request)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode } ?? -1
            print("spotify: search failed (http \(code))")
            // 429/403 mean throttling, not a missing canvas: rest the service so
            // the Apple/community fallbacks answer immediately instead of after
            // a doomed request per track.
            if code == 429 || code == 403 { noteThrottled() }
            return nil
        }

        let wantTitle = CanvasService.normalize(song.title)
        let wantArtist = CanvasService.normalize(song.artist)
        for item in items {
            guard let name = item["name"] as? String, let uri = item["uri"] as? String else { continue }
            let artists = (item["artists"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
                .joined(separator: ", ")
            let titleOK = CanvasService.normalize(name).contains(wantTitle)
                || wantTitle.contains(CanvasService.normalize(name))
            let artistOK = CanvasService.normalize(artists).contains(wantArtist.split(separator: ",").first.map(String.init) ?? "")
            if titleOK && artistOK { return uri }
        }
        return nil
    }

    // MARK: Canvas fetch

    /// Pathfinder is the web player's own search and the one this kind of
    /// token is reliably let near; the REST endpoint answers 429 far more
    /// often. The persisted-query hash is the phone's.
    private func trackURIviaPathfinder(song: Song, token: String, clientToken: String?) async -> String? {
        let variables: [String: Any] = [
            "searchTerm": "\(song.title) \(CanvasService.normalize(song.artist))",
            "offset": 0,
            "limit": 10,
            "numberOfTopResults": 5,
            "includeAudiobooks": false,
            "includePreReleases": false,
        ]
        let extensions: [String: Any] = [
            "persistedQuery": [
                "version": 1,
                "sha256Hash": "bc1ca2fcd0ba1013a0fc88e6cc4f190af501851e3dafd3e1ef85840297694428",
            ],
        ]
        func encode(_ object: [String: Any]) -> String {
            (try? JSONSerialization.data(withJSONObject: object))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }
        var components = URLComponents(string: "https://api-partner.spotify.com/pathfinder/v1/query")!
        components.queryItems = [
            URLQueryItem(name: "operationName", value: "searchTracks"),
            URLQueryItem(name: "variables", value: encode(variables)),
            URLQueryItem(name: "extensions", value: encode(extensions)),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.appUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("WebPlayer", forHTTPHeaderField: "App-platform")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let clientToken { request.setValue(clientToken, forHTTPHeaderField: "Client-Token") }

        guard let (data, response) = try? await session.data(for: request) else { return nil }
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            print("spotify: pathfinder http \(code)")
            return nil
        }
        let text = String(decoding: data, as: UTF8.self)
        // The GraphQL shape isn't published; the URI is in the payload verbatim.
        let pattern = try? NSRegularExpression(pattern: #"spotify:track:[A-Za-z0-9]{22}"#)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern?.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else {
            print("spotify: pathfinder had no track uri (\(data.count) bytes)")
            return nil
        }
        print("spotify: pathfinder found a track")
        return String(text[matchRange])
    }

    private func canvasURL(trackURI uri: String, token: String, clientToken: String?) async -> URL? {
        var request = URLRequest(url: Self.canvasURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue("application/protobuf", forHTTPHeaderField: "Accept")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.setValue(Self.appUserAgent, forHTTPHeaderField: "User-Agent")
        if let clientToken { request.setValue(clientToken, forHTTPHeaderField: "Client-Token") }
        request.httpBody = Self.encodeCanvasRequest(trackURI: uri)

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            let code = (try? await session.data(for: request)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode } ?? -1
            print("spotify: canvaz-cache failed (http \(code))")
            return nil
        }
        print("spotify: canvaz-cache \(data.count) bytes")

        // The response is a protobuf whose exact field numbers are not
        // published; the clip URL sits in it as plain UTF-8, so scanning the
        // bytes finds it without depending on a field number.
        let text = String(decoding: data, as: UTF8.self)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = Self.canvasPattern.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else { return nil }
        return URL(string: String(text[matchRange]))
    }

    /// protobuf: `{ 1: { 1: "<track uri>" } }` — the same two fields the phone writes.
    static func encodeCanvasRequest(trackURI: String) -> Data {
        var inner = Data()
        inner.append(0x0A)
        inner.append(contentsOf: varint(UInt64(trackURI.utf8.count)))
        inner.append(contentsOf: trackURI.utf8)

        var outer = Data()
        outer.append(0x0A)
        outer.append(contentsOf: varint(UInt64(inner.count)))
        outer.append(inner)
        return outer
    }

    private static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }
}
