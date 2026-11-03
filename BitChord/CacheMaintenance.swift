//
//  CacheMaintenance.swift
//  BitGranada
//
//  Clearing what the app writes to disk: canvas clips, downloaded artwork and
//  the HTTP cache. The library, playlists and settings live in Application
//  Support and are never touched here.
//

import Foundation

@MainActor
enum CacheMaintenance {
    /// Directories the app owns inside Caches.
    static var directories: [URL] {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let base else { return [] }
        return [
            base.appendingPathComponent("BitGranada/Canvas", isDirectory: true),
            base.appendingPathComponent("BitGranada", isDirectory: true),
            base.appendingPathComponent("BitGranada/Canvas", isDirectory: true),
            base.appendingPathComponent("BitGranada", isDirectory: true),
        ]
    }

    static func size() -> Int64 {
        let manager = FileManager.default
        var total: Int64 = 0
        for directory in directories where manager.fileExists(atPath: directory.path) {
            let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            while let file = enumerator?.nextObject() as? URL {
                total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return total
    }

    /// Deletes every cached file and empties the in-memory caches, returning how
    /// many bytes were freed.
    @discardableResult
    static func clear() async -> Int64 {
        let freed = size()
        let manager = FileManager.default
        for directory in directories where manager.fileExists(atPath: directory.path) {
            if let contents = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for item in contents { try? manager.removeItem(at: item) }
            }
        }
        URLCache.shared.removeAllCachedResponses()
        ArtworkLoader.shared.clearMemory()
        PaletteExtractor.clearCache()
        await LyricsService.shared.clearCache()
        return freed
    }

    static func formatted(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
