//
// ProcedureParser.swift
//
// Text → procedure steps. A clean numbered list is split here, with no AI
// and no cost; anything else goes to the AI once (BuildChecker) and its
// JSON reply is decoded here. Either way a person reviews the result before
// it can be run. Foundation only; tested in tests/buildcheck-parser.
//

import Foundation

enum ProcedureParser {
    static let maxCharacters = 60_000

    enum ParseError: Error, Equatable {
        case empty
        case tooLong(characters: Int)
        case unreadableAIReply
    }

    /// Trimmed text, or an error. Over the cap is an error, never a silent
    /// truncation: a cut-off procedure would pass review looking complete.
    static func validate(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }
        guard trimmed.count <= maxCharacters else {
            throw ParseError.tooLong(characters: trimmed.count)
        }
        return trimmed
    }

    // MARK: Numbered lists

    // "1. x", "1) x", "1 - x", "1: x", "Step 1: x". The dot/paren form needs
    // whitespace after it, so "2.5 mm" is a continuation line, not step 2.
    private static let numberedLine = try! NSRegularExpression(
        pattern: #"^(?:step\s+)?(\d{1,3})(?:[.)]\s+|\s*[:\-–]\s+)(\S.*)$"#,
        options: [.caseInsensitive])

    /// The steps of a clean numbered list (≥ 2 steps, numbered 1, 2, 3… with
    /// no gaps or restarts), or nil - in which case the AI splits it.
    /// Lines before step 1 are a preamble and ignored; unnumbered lines after
    /// it continue the step above.
    static func numberedSteps(in text: String) -> [String]? {
        var steps: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let ns = line as NSString
            if let m = numberedLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
               let n = Int(ns.substring(with: m.range(at: 1))) {
                guard n == steps.count + 1 else { return nil }
                steps.append(ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces))
            } else if !steps.isEmpty {
                steps[steps.count - 1] += " " + line
            }
        }
        return steps.count >= 2 ? steps : nil
    }

    static func steps(fromNumbered texts: [String]) -> [ProcedureStep] {
        texts.map { ProcedureStep(text: $0, critical: suggestsCritical($0)) }
    }

    // MARK: Critical suggestion

    static let criticalPhrases = [
        "torque", "safety wire", "safety-wire", "lockwire", "lock wire",
        "orientation", "connector", "fluid", "verify", "caution", "warning",
        "critical",
    ]
    private static let torqueValue = try! NSRegularExpression(
        pattern: #"\d\s*(n\s?·?\s?m|in[-\s]?lbs?|ft[-\s]?lbs?)\b"#, options: [.caseInsensitive])

    /// A suggestion only - the review screen is where it's decided.
    static func suggestsCritical(_ text: String) -> Bool {
        let lower = text.lowercased()
        if criticalPhrases.contains(where: lower.contains) { return true }
        return torqueValue.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    // MARK: AI split

    struct Split {
        var title: String?
        var steps: [ProcedureStep]
    }

    static let splitSystemPrompt = """
    You split assembly work instructions into ordered steps. Reply with ONLY a JSON object, no prose:
    {"title": string, "steps": [{"text": string, "critical": boolean, "expected_look": string}]}
    - text: the instruction, verbatim from the document where possible. One physical action or check per step.
    - critical: true for torque values, safety wire or lockwire, part orientation, connectors, fluids, and anything marked verify, caution or warning.
    - expected_look: one short line describing what the work looks like when this step is done correctly, as seen from the technician's eyes.
    Skip front matter, revision tables, page headers and footers.
    """

    static func splitUserPrompt(document: String) -> String {
        "Work instructions:\n\n" + document
    }

    static func split(fromAIReply reply: String) throws -> Split {
        guard let object = BuildCheckJSON.object(in: reply),
              let raw = object["steps"] as? [[String: Any]] else {
            throw ParseError.unreadableAIReply
        }
        let steps: [ProcedureStep] = raw.compactMap { entry in
            let text = ((entry["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let look = ((entry["expected_look"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return ProcedureStep(text: text,
                                 critical: (entry["critical"] as? Bool) ?? suggestsCritical(text),
                                 expectedLook: look)
        }
        guard !steps.isEmpty else { throw ParseError.unreadableAIReply }
        let title = ((object["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Split(title: title.isEmpty ? nil : title, steps: steps)
    }
}
