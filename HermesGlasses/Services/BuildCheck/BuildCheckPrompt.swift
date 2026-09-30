//
// BuildCheckPrompt.swift
//
// What Build Check asks the model and how it reads the answer. The reply
// is untrusted text: anything that isn't a well-formed verdict becomes
// `unclear` with confidence 0, which the alert policy never escalates - a
// garbled reply must never turn into a false alarm.
// Foundation only; tested in tests/buildcheck-verdict.
//

import Foundation

enum CheckKind: String, Codable { case quick, full }

enum CheckVerdict: String, Codable { case match, mismatch, unclear }

struct CheckResult: Codable, Equatable {
    static let highConfidence = 0.75
    static let lowConfidence = 0.5

    var verdict: CheckVerdict
    var confidence: Double
    var observed: String
    var issue: String

    static func unclear(_ why: String) -> CheckResult {
        CheckResult(verdict: .unclear, confidence: 0, observed: "", issue: why)
    }

    /// The only result that holds a critical step (BuildRunTracker).
    var isConfidentMismatch: Bool {
        verdict == .mismatch && confidence >= Self.highConfidence
    }
}

enum BuildCheckPrompt {
    static let systemPrompt = """
    You inspect photos from smart glasses worn by a technician doing assembly work, and judge whether the work matches one step of a written procedure.
    Reply with ONLY a JSON object, no prose:
    {"verdict": "match" | "mismatch" | "unclear", "confidence": number from 0 to 1, "observed": string, "issue": string}
    - observed: what you can actually see that is relevant to the step, in one short sentence.
    - issue: for a mismatch, what differs, phrased as "I see X, the procedure says Y". Empty otherwise.
    - Use "unclear" when the relevant part is out of frame, blurred, blocked by hands or tools, or too small to judge. Never guess a mismatch from a bad view.
    - Judge only this step. Later steps not being done yet is not a mismatch.
    """

    private static func stepBlock(_ step: ProcedureStep, number: Int, total: Int) -> String {
        var s = "Step \(number) of \(total)\(step.critical ? " (CRITICAL)" : ""): \(step.text)"
        let look = step.expectedLook.trimmingCharacters(in: .whitespacesAndNewlines)
        if !look.isEmpty { s += "\nWhen done correctly it looks like: \(look)" }
        return s
    }

    static func quickPrompt(step: ProcedureStep, number: Int, total: Int) -> String {
        stepBlock(step, number: number, total: total)
            + "\n\nThe photo is the technician's current view, part-way through this step. Does what you see match this step so far?"
    }

    static func fullPrompt(step: ProcedureStep, number: Int, total: Int, tileLabels: [String]) -> String {
        stepBlock(step, number: number, total: total)
            + "\n\nThe technician says this step is finished. The image is a grid of labelled tiles: "
            + tileLabels.joined(separator: ", ")
            + "."
            // Only name REFERENCE tiles when there are some: a prompt that
            // describes absent references invites the model to judge them.
            + (tileLabels.contains { $0.hasPrefix("REFERENCE") }
                ? " Tiles labelled REFERENCE show this step done correctly; tiles labelled NOW are the technician's work."
                : " Tiles labelled NOW are the technician's work.")
            + " If no tile labelled NOW is present, answer unclear."
            + " Is the step complete and correct?"
    }

    static func parseVerdict(_ reply: String) -> CheckResult {
        guard let object = BuildCheckJSON.object(in: reply),
              let raw = (object["verdict"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let verdict = CheckVerdict(rawValue: raw) else {
            return .unclear("unreadable reply")
        }
        let confidence: Double
        if let number = object["confidence"] as? Double {
            confidence = number
        } else if let text = object["confidence"] as? String, let number = Double(text) {
            confidence = number
        } else {
            confidence = 0
        }
        return CheckResult(
            verdict: verdict,
            confidence: min(1, max(0, confidence)),
            observed: (object["observed"] as? String) ?? "",
            issue: (object["issue"] as? String) ?? "")
    }
}
