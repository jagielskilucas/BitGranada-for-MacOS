//
//  YouTubeWebHighlights.swift
//  BitGranada
//
//  The signed-in YouTube Music home, read from the page the site itself renders.
//
//  Hand-rolling SAPISIDHASH was fragile: the API answered 401 for a session that
//  works in the browser. A hidden WKWebView lets the site authenticate with its
//  own JavaScript, and the sections are then read from the DOM — the same trick
//  the Spotify taste reader uses.
//

import Foundation
import WebKit
import AppKit

@MainActor
final class YouTubeWebHighlights: NSObject {
    static let shared = YouTubeWebHighlights()

    private var webView: WKWebView?
    private var window: NSWindow?
    private var continuation: CheckedContinuation<[Shelf], Never>?
    private var settleWork: DispatchWorkItem?

    /// Loads music.youtube.com with the stored cookies and returns its shelves.
    func load(cookie: String) async -> [Shelf] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            start(cookie: cookie)
        }
    }

    private func start(cookie: String) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1400, height: 1000),
                                configuration: configuration)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self

        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1400, height: 1000),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.contentView = webView
        window.orderFrontRegardless()
        self.webView = webView
        self.window = window

        // Cookies come as one header string: "A=1; B=2".
        let pairs = cookie.split(separator: ";").compactMap { part -> (String, String)? in
            let pieces = part.split(separator: "=", maxSplits: 1)
            guard pieces.count == 2 else { return nil }
            return (pieces[0].trimmingCharacters(in: .whitespaces),
                    String(pieces[1]).trimmingCharacters(in: .whitespaces))
        }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let group = DispatchGroup()
        for (name, value) in pairs {
            let properties: [HTTPCookiePropertyKey: Any] = [
                .domain: ".youtube.com",
                .path: "/",
                .name: name,
                .value: value,
                .secure: "TRUE",
                .expires: Date().addingTimeInterval(60 * 60 * 24 * 180),
            ]
            if let httpCookie = HTTPCookie(properties: properties) {
                group.enter()
                store.setCookie(httpCookie) { group.leave() }
            }
        }
        group.notify(queue: .main) { [weak webView] in
            webView?.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))
        }
    }

    private static let script = """
    (function () {
      const out = [];
      const shelfs = document.querySelectorAll(
        'ytmusic-carousel-shelf-renderer, ytmusic-shelf-renderer, ytmusic-grid-renderer');
      shelfs.forEach(function (shelf) {
        const header = shelf.querySelector('h2, .title, yt-formatted-string.title');
        const name = header ? (header.textContent || '').trim() : '';
        const items = [];
        const cards = shelf.querySelectorAll(
          'ytmusic-two-row-item-renderer, ytmusic-responsive-list-item-renderer, ytmusic-grid-item-renderer, a[href*="watch?"]');
        cards.forEach(function (card) {
          const link = card.tagName === 'A' ? card : card.querySelector('a[href]');
          if (!link) return;
          const href = link.getAttribute('href') || '';
          const titleEl = card.querySelector('#title, .title, yt-formatted-string.title') || link;
          const title = (titleEl.textContent || '').trim();
          if (!title || title.length > 140) return;
          const subEl = card.querySelector('#subtitle, .subtitle, .secondary-flex-columns');
          const subtitle = subEl ? (subEl.textContent || '').trim() : '';
          const img = card.querySelector('img');
          items.push({ title: title, subtitle: subtitle, href: href,
                       art: img ? (img.src || '') : '' });
        });
        if (items.length) out.push({ title: name, items: items.slice(0, 24) });
      });
      return JSON.stringify(out);
    })();
    """

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    private func finish(_ shelves: [Shelf]) {
        settleWork?.cancel()
        continuation?.resume(returning: shelves)
        continuation = nil
        webView?.stopLoading()
        webView = nil
        window?.orderOut(nil)
        window = nil
    }
}

extension YouTubeWebHighlights: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            webView.evaluateJavaScript(Self.script) { result, _ in
                guard let json = result as? String,
                      let data = json.data(using: .utf8),
                      let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
                else {
                    self.finish([])
                    return
                }
                let shelves: [Shelf] = raw.compactMap { entry in
                    guard let title = entry["title"] as? String, !title.isEmpty,
                          let items = entry["items"] as? [[String: Any]] else { return nil }
                    let parsed: [ShelfItem] = items.compactMap { item in
                        guard let itemTitle = item["title"] as? String else { return nil }
                        let href = item["href"] as? String ?? ""
                        let art = item["art"] as? String
                        var videoId: String?
                        var playlistId: String?
                        if let range = href.range(of: "v=") {
                            videoId = String(href[range.upperBound...].prefix { $0 != "&" })
                        }
                        if let range = href.range(of: "list=") {
                            playlistId = String(href[range.upperBound...].prefix { $0 != "&" })
                        }
                        return ShelfItem(
                            title: itemTitle,
                            subtitle: item["subtitle"] as? String ?? "",
                            thumbnailURL: art,
                            videoId: videoId,
                            browseId: nil,
                            playlistId: playlistId,
                            duration: nil,
                            pageKind: nil,
                            isVideo: href.contains("watch?v=") && !href.contains("list=")
                        )
                    }
                    guard !parsed.isEmpty else { return nil }
                    return Shelf(title: title, items: parsed)
                }
                self.finish(shelves)
            }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish([])
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish([])
    }
}
