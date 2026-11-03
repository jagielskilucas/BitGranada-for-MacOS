//
//  SpotifyWebTaste.swift
//  BitGranada
//
//  Taste read from the web player itself, with the session the listener already
//  has. No Spotify app, no Client ID: a hidden WKWebView opens the personalised
//  home page and the visible artist cards are read from the DOM.
//

import Foundation
import WebKit
import AppKit

@MainActor
final class SpotifyWebTaste: NSObject {
    static let shared = SpotifyWebTaste()

    private var webView: WKWebView?
    private var window: NSWindow?
    private var continuation: CheckedContinuation<SpotifyTaste?, Never>?
    private var settleWork: DispatchWorkItem?

    /// Loads the home page and returns the artists/tracks it is showing.
    func load(cookie: String) async -> SpotifyTaste? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            start(cookie: cookie)
        }
    }

    private func start(cookie: String) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900),
                                configuration: configuration)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self

        // Off screen: the page has to render, not be seen.
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 1280, height: 900),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.contentView = webView
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

    /// The scrape: artist links plus the titles the page is displaying.
    private static let script = """
    (function () {
      const artists = [];
      const tracks = [];
      document.querySelectorAll('a[href^="/artist/"]').forEach(function (a) {
        const name = (a.textContent || "").trim();
        if (name && name.length < 80 && !artists.includes(name)) artists.push(name);
      });
      document.querySelectorAll('a[href^="/track/"]').forEach(function (a) {
        const title = (a.textContent || "").trim();
        if (title && title.length < 120 && !tracks.includes(title)) tracks.push(title);
      });
      // Spotify truncates the card text with "…" — drop it, it is not a name.
      const clean = (list) => list.map(function (s) { return s.replace(/…$/, "").trim(); })
                                 .filter(function (s) { return s.length > 1; });
      return JSON.stringify({ artists: clean(artists).slice(0, 40),
                              tracks: clean(tracks).slice(0, 60) });
    })();
    """

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    private func finish(_ taste: SpotifyTaste?) {
        settleWork?.cancel()
        continuation?.resume(returning: taste)
        continuation = nil
        webView?.stopLoading()
        webView = nil
        window?.orderOut(nil)
        window = nil
    }
}

extension SpotifyWebTaste: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The home page fills in after the first paint; give it a moment and
        // then read the cards that made it onto the page.
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            webView.evaluateJavaScript(Self.script) { result, _ in
                guard let json = result as? String,
                      let data = json.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    self.finish(nil)
                    return
                }
                let artists = (object["artists"] as? [String]) ?? []
                let titles = (object["tracks"] as? [String]) ?? []
                let tracks = titles.map { SpotifyTaste.Track(title: $0, artist: "") }
                guard !artists.isEmpty || !tracks.isEmpty else {
                    self.finish(nil)
                    return
                }
                self.finish(SpotifyTaste(artists: artists, tracks: tracks, updatedAt: Date()))
            }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }
}
