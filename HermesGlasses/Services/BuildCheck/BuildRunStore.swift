//
// BuildRunStore.swift
//
// Runs under Application Support/buildruns/<id>/: run.json, frames/,
// reference/ (copies of the procedure's reference photos taken at start,
// so editing or deleting the procedure never changes what a past run was
// checked against). A folder whose run.json won't decode is skipped, not
// fatal. Foundation only; tested in tests/buildcheck-stores.
//

import Foundation

final class BuildRunStore: @unchecked Sendable {
    private let rootURL: URL
    private let fm = FileManager.default

    init(directory: URL? = nil) {
        rootURL = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("buildruns", isDirectory: true)
        try? fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func folderURL(runID: UUID) -> URL {
        rootURL.appendingPathComponent(runID.uuidString, isDirectory: true)
    }

    func frameURL(runID: UUID, filename: String) -> URL {
        folderURL(runID: runID).appendingPathComponent("frames").appendingPathComponent(filename)
    }

    func referenceURL(runID: UUID, filename: String) -> URL {
        folderURL(runID: runID).appendingPathComponent("reference").appendingPathComponent(filename)
    }

    /// Creates the folders, copies reference photos, writes the first run.json.
    func begin(_ run: BuildRun, referencePhoto: (String) -> URL) throws {
        let folder = folderURL(runID: run.id)
        try fm.createDirectory(at: folder.appendingPathComponent("frames"), withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.appendingPathComponent("reference"), withIntermediateDirectories: true)
        for name in run.procedure.steps.flatMap(\.referencePhotoFilenames) {
            let target = referenceURL(runID: run.id, filename: name)
            try? fm.removeItem(at: target)
            try? fm.copyItem(at: referencePhoto(name), to: target)
        }
        try write(run)
    }

    func addFrame(_ jpeg: Data, runID: UUID, at date: Date) throws -> String {
        let name = "f-\(Int(date.timeIntervalSince1970 * 1000)).jpg"
        let framesDir = folderURL(runID: runID).appendingPathComponent("frames", isDirectory: true)
        try fm.createDirectory(at: framesDir, withIntermediateDirectories: true)
        try jpeg.write(to: frameURL(runID: runID, filename: name), options: .atomic)
        return name
    }

    func write(_ run: BuildRun) throws {
        let folder = folderURL(runID: run.id)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(run)
        try data.write(to: folder.appendingPathComponent("run.json"), options: .atomic)
    }

    func all() -> [BuildRun] {
        let folders = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("run.json")) else { return nil }
            return try? Self.decoder.decode(BuildRun.self, from: data)
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    func delete(id: UUID) {
        try? fm.removeItem(at: rootURL.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    func diskSize(runID: UUID) -> Int64 {
        let folder = rootURL.appendingPathComponent(runID.uuidString, isDirectory: true)
        guard let files = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
