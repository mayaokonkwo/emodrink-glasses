//
// PhysiologyStore.swift
//
// The last good snapshot, kept under Application Support/emodrink so a
// failed fetch can fall back to this morning's numbers. One file, whole
// value, no partial writes. Foundation only; tested in tests/emodrink-source.
//

import Foundation

struct CachedSnapshot: Codable, Equatable {
    let snapshot: PhysiologySnapshot
    let fetchedAt: Date
    /// What the card prints, e.g. "Garmin, 07:12".
    let sourceLabel: String
}

final class PhysiologyStore {
    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("emodrink", isDirectory: true)
        fileURL = base.appendingPathComponent("snapshot.json")
    }

    func load() -> CachedSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CachedSnapshot.self, from: data)
    }

    func save(_ cached: CachedSnapshot) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(cached).write(to: fileURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
