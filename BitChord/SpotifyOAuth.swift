//
//  SpotifyOAuth.swift
//  BitGranada
//
//  Authorization Code + PKCE against a Spotify app the listener creates.
//
//  The web player's token (what the canvas uses) is scoped for streaming, so
//  /v1/me/top/* answers 403 with it. Reading taste requires the `user-top-read`
//  scope, and that needs an app of the listener's own — no client secret, which
//  is exactly what PKCE exists for.
//

import Foundation
import CryptoKit
import Network
import AppKit

@MainActor
final class SpotifyOAuth: ObservableObject {
    static let shared = SpotifyOAuth()

    @Published private(set) var status: String?

    private let defaults = UserDefaults.standard
    private var listener: NWListener?

    var clientID: String {
        get { defaults.string(forKey: "spotify.clientID") ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                           forKey: "spotify.clientID") }
    }

    var isConnected: Bool { defaults.string(forKey: "spotify.refreshToken") != nil }

    func disconnect() {
        defaults.removeObject(forKey: "spotify.refreshToken")
        defaults.removeObject(forKey: "spotify.accessToken")
        defaults.removeObject(forKey: "spotify.expiresAt")
        status = nil
    }

    /// A bearer with `user-top-read`, refreshed when needed.
    func accessToken() async -> String? {
        if let token = defaults.string(forKey: "spotify.accessToken"),
           let expiry = defaults.object(forKey: "spotify.expiresAt") as? Date,
           Date() < expiry.addingTimeInterval(-60) {
            return token
        }
        guard let refresh = defaults.string(forKey: "spotify.refreshToken") else { return nil }
        return await refreshToken(refresh)
    }

    // MARK: Authorization

    /// Opens the browser and waits for the redirect on 127.0.0.1.
    func authorize() async -> Bool {
        let id = clientID
        guard !id.isEmpty else {
            status = "Informe o Client ID do seu app Spotify."
            return false
        }
        // Fixed port: Spotify only redirects to a URI registered verbatim in the
        // app's dashboard, so a random one would always be refused.
        let port = Self.callbackPort
        let redirect = "http://127.0.0.1:\(port)/callback"
        let verifier = Self.verifier()
        let challenge = Self.challenge(for: verifier)
        let state = UUID().uuidString

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: id),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: "user-top-read"),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else { return false }

        status = "Aguardando a autorização no navegador…"
        let code = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            startListener(port: port, expectedState: state) { code in
                continuation.resume(returning: code)
            }
            NSWorkspace.shared.open(url)
        }
        stopListener()
        guard let code else {
            status = "Autorização não concluída."
            return false
        }
        return await exchange(code: code, verifier: verifier, redirect: redirect)
    }

    private func exchange(code: String, verifier: String, redirect: String) async -> Bool {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "grant_type=authorization_code",
            "code=\(code)",
            "redirect_uri=\(redirect)",
            "client_id=\(clientID)",
            "code_verifier=\(verifier)",
        ].joined(separator: "&")
        request.httpBody = Data(form.utf8)

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            status = "O Spotify recusou a troca do código."
            return false
        }
        store(access: access, json: json)
        status = "Conectado ao Spotify."
        return true
    }

    private func refreshToken(_ token: String) async -> String? {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data([
            "grant_type=refresh_token",
            "refresh_token=\(token)",
            "client_id=\(clientID)",
        ].joined(separator: "&").utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else { return nil }
        store(access: access, json: json)
        return access
    }

    private func store(access: String, json: [String: Any]) {
        defaults.set(access, forKey: "spotify.accessToken")
        if let refresh = json["refresh_token"] as? String {
            defaults.set(refresh, forKey: "spotify.refreshToken")
        }
        let seconds = (json["expires_in"] as? Double) ?? 3600
        defaults.set(Date().addingTimeInterval(seconds), forKey: "spotify.expiresAt")
    }

    // MARK: Local redirect

    private func startListener(port: UInt16, expectedState: String,
                               completion: @escaping (String?) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: .tcp, on: nwPort) else {
            completion(nil)
            return
        }
        self.listener = listener
        var finished = false
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                guard !finished, let data, let line = String(data: data, encoding: .utf8)?
                    .split(separator: "\r\n").first else { return }
                finished = true
                // "GET /callback?code=…&state=… HTTP/1.1"
                let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let items = URLComponents(string: "http://x" + path)?.queryItems ?? []
                let code = items.first { $0.name == "code" }?.value
                let state = items.first { $0.name == "state" }?.value
                let body = "<html><body style='font-family:-apple-system;padding:40px'>"
                    + "<h2>BitGranada</h2><p>Spotify conectado. Pode fechar esta aba.</p></body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                connection.send(content: Data(response.utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
                completion(state == expectedState ? code : nil)
            }
        }
        listener.start(queue: .global())
    }

    private func stopListener() {
        listener?.cancel()
        listener = nil
    }

    // MARK: PKCE helpers

    private static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncoded()
    }

    /// Must match the redirect URI shown in the settings row.
    static let callbackPort: UInt16 = 8888
    static var redirectURI: String { "http://127.0.0.1:\(callbackPort)/callback" }

    private static func freePort() -> UInt16? {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return nil }
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, size)
            }
        }
        guard bound == 0 else { return nil }
        var result = sockaddr_in()
        var resultSize = size
        let named = withUnsafeMutablePointer(to: &result) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &resultSize)
            }
        }
        guard named == 0 else { return nil }
        return UInt16(bigEndian: result.sin_port)
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
