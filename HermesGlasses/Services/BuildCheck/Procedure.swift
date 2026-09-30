//
// Procedure.swift
//
// A written assembly procedure as Build Check uses it: ordered steps, each
// with the instruction text, whether it is critical (a confident mismatch
// holds the run on it), what "done" looks like, and up to three reference
// photos. Editing bumps the version and sends it back to draft - only a
// procedure a person has reviewed (`ready`) can start a run.
// Foundation only; tested in tests/buildcheck-procedure.
//

import Foundation

struct ProcedureStep: Codable, Equatable, Identifiable {
    var id: UUID
    var text: String
    var critical: Bool
    var expectedLook: String
    var referencePhotoFilenames: [String]

    init(id: UUID = UUID(), text: String, critical: Bool = false,
         expectedLook: String = "", referencePhotoFilenames: [String] = []) {
        self.id = id
        self.text = text
        self.critical = critical
        self.expectedLook = expectedLook
        self.referencePhotoFilenames = referencePhotoFilenames
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        critical = try c.decodeIfPresent(Bool.self, forKey: .critical) ?? false
        expectedLook = try c.decodeIfPresent(String.self, forKey: .expectedLook) ?? ""
        referencePhotoFilenames = try c.decodeIfPresent([String].self, forKey: .referencePhotoFilenames) ?? []
    }
}

struct Procedure: Codable, Equatable, Identifiable {
    static let maxReferencePhotos = 3

    var id: UUID
    var title: String
    var version: Int
    var steps: [ProcedureStep]
    /// Set only by `markReady` after review; any edit clears it.
    var ready: Bool
    /// The imported document, kept next to the procedure (ProcedureStore).
    var sourceFilename: String?
    var updatedAt: Date

    init(id: UUID = UUID(), title: String, steps: [ProcedureStep],
         sourceFilename: String? = nil, now: Date = Date()) {
        self.id = id
        self.title = title
        self.version = 1
        self.steps = steps
        self.ready = false
        self.sourceFilename = sourceFilename
        self.updatedAt = now
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        steps = try c.decodeIfPresent([ProcedureStep].self, forKey: .steps) ?? []
        ready = try c.decodeIfPresent(Bool.self, forKey: .ready) ?? false
        sourceFilename = try c.decodeIfPresent(String.self, forKey: .sourceFilename)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
    }

    /// Every change goes through here: new version, back to draft.
    mutating func edit(now: Date = Date(), _ change: (inout Procedure) -> Void) {
        change(&self)
        version += 1
        ready = false
        updatedAt = now
    }

    var canBeReady: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !steps.isEmpty
            && steps.allSatisfy { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The review screen's "Mark ready". False (and unchanged) when incomplete.
    @discardableResult
    mutating func markReady(now: Date = Date()) -> Bool {
        guard canBeReady else { return false }
        ready = true
        updatedAt = now
        return true
    }

    var criticalStepIndices: Set<Int> {
        Set(steps.indices.filter { steps[$0].critical })
    }
}
