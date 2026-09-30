//
// ProcedureStore.swift
//
// Procedures under Application Support/procedures/: one JSON index,
// reference photos in photos/, imported documents in sources/. Same shape
// as LensSessionStore. Foundation only; tested in tests/buildcheck-stores.
//

import Foundation

final class ProcedureStore: @unchecked Sendable {
    private let lock = NSLock()
    private let rootURL: URL
    private let indexURL: URL
    private let photosURL: URL
    private let sourcesURL: URL

    init(directory: URL? = nil) {
        rootURL = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("procedures", isDirectory: true)
        indexURL = rootURL.appendingPathComponent("procedures.json")
        photosURL = rootURL.appendingPathComponent("photos", isDirectory: true)
        sourcesURL = rootURL.appendingPathComponent("sources", isDirectory: true)
        for dir in [rootURL, photosURL, sourcesURL] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func load() -> [Procedure] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? Self.decoder.decode([Procedure].self, from: data)) ?? []
    }

    private func store(_ procedures: [Procedure]) {
        guard let data = try? Self.encoder.encode(procedures) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    func all() -> [Procedure] {
        lock.withLock { load() }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ procedure: Procedure) {
        lock.withLock {
            var list = load()
            if let i = list.firstIndex(where: { $0.id == procedure.id }) {
                list[i] = procedure
            } else {
                list.append(procedure)
            }
            store(list)
        }
    }

    /// Removes the entry, its reference photos and its source document.
    /// Runs keep their own copies (BuildRunStore.begin), so history survives.
    func delete(id: UUID) {
        lock.withLock {
            var list = load()
            guard let i = list.firstIndex(where: { $0.id == id }) else { return }
            let removed = list.remove(at: i)
            store(list)
            for name in removed.steps.flatMap(\.referencePhotoFilenames) {
                try? FileManager.default.removeItem(at: photoURL(name))
            }
            if let source = removed.sourceFilename {
                try? FileManager.default.removeItem(at: sourceURL(source))
            }
        }
    }

    func addPhoto(_ jpeg: Data) throws -> String {
        let name = "\(UUID().uuidString).jpg"
        try jpeg.write(to: photoURL(name), options: .atomic)
        return name
    }

    func photoURL(_ filename: String) -> URL { photosURL.appendingPathComponent(filename) }

    func addSource(_ data: Data, fileExtension: String) throws -> String {
        let ext = fileExtension.isEmpty ? "bin" : fileExtension.lowercased()
        let name = "\(UUID().uuidString).\(ext)"
        try data.write(to: sourceURL(name), options: .atomic)
        return name
    }

    func sourceURL(_ filename: String) -> URL { sourcesURL.appendingPathComponent(filename) }
}
