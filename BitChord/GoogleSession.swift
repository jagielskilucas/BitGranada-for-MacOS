//
//  GoogleSession.swift
//  BitGranada
//
//  The YouTube Music session, built from the cookies the web player already has.
//  Google's own OAuth needs a registered client and a browser round trip per
//  hour; the cookie + SAPISIDHASH pair is what the web client itself sends, and
//  it does not expire while the session lasts.
//

import Foundation
import CryptoKit

enum GoogleSession {
    /// The raw cookie header, pasted in Settings ("SAPISID=…; __Secure-3PAPISID=…").
    static var cookie: String? {
        let value = UserDefaults.standard.string(forKey: "google.cookie")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    static var isSignedIn: Bool { cookie != nil }

    struct Authorization {
        var header: String
        var cookie: String
    }

    /// `SAPISIDHASH <seconds>_<sha1(seconds + " " + SAPISID + " " + origin)>`
    static var authorization: Authorization? {
        guard let cookie else { return nil }
        guard let sapisid = value(of: "SAPISID", in: cookie)
            ?? value(of: "__Secure-3PAPISID", in: cookie),
              let sapisid3 = value(of: "__Secure-3PAPISID", in: cookie) ?? Optional(sapisid)
        else { return nil }

        let origin = "https://music.youtube.com"
        let seconds = Int(Date().timeIntervalSince1970)
        let material = "\(seconds) \(sapisid) \(origin)"
        let digest = Insecure.SHA1.hash(data: Data(material.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return Authorization(header: "SAPISIDHASH \(seconds)_\(hex)",
                             cookie: cookie)
    }

    private static func value(of name: String, in cookie: String) -> String? {
        for part in cookie.split(separator: ";") {
            let pieces = part.split(separator: "=", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            if pieces[0].trimmingCharacters(in: .whitespaces) == name {
                return String(pieces[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
