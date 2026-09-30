//
// AlertPolicy.swift
//
// Verdict → how loudly to tell the wearer. The design goal is that false
// alarms stay rare enough that nobody learns to tune them out:
//   - only a critical step's confident mismatch is spoken at once;
//   - a quick (mid-step) mismatch must repeat on two checks in a row;
//   - the same issue on the same step isn't raised again within 120 s -
//     for quick checks only: a full check is one the wearer asked for
//     ("step done", "fixed"), so its answer is always delivered.
// Foundation only; tested in tests/buildcheck-alerts.
//

import Foundation

enum AlertLevel: String, Codable { case speak, chime, log }

struct AlertDecision: Equatable {
    var level: AlertLevel
    /// "Couldn't verify step N, can you confirm?" instead of a mismatch line.
    var askToConfirm: Bool

    static let log = AlertDecision(level: .log, askToConfirm: false)
}

struct AlertPolicy {
    static let repeatWindow: TimeInterval = 120
    static let similarityThreshold = 0.5

    private var quickStreak: (step: Int, count: Int)?
    private var raised: [(step: Int, issue: String, at: Date)] = []

    static func baseDecision(result: CheckResult, kind: CheckKind, critical: Bool) -> AlertDecision {
        switch result.verdict {
        case .mismatch where result.confidence >= CheckResult.highConfidence:
            return AlertDecision(level: critical ? .speak : .chime, askToConfirm: false)
        case .mismatch where result.confidence >= CheckResult.lowConfidence:
            return critical ? AlertDecision(level: .chime, askToConfirm: false) : .log
        case .unclear where kind == .full && critical:
            return AlertDecision(level: .chime, askToConfirm: true)
        default:
            return .log
        }
    }

    mutating func decide(result: CheckResult, kind: CheckKind, step: Int,
                         critical: Bool, now: Date) -> AlertDecision {
        let decision = Self.baseDecision(result: result, kind: kind, critical: critical)
        raised.removeAll { now.timeIntervalSince($0.at) >= Self.repeatWindow }

        if kind == .quick {
            if result.verdict == .mismatch && result.confidence >= CheckResult.lowConfidence {
                let count = (quickStreak?.step == step ? quickStreak?.count ?? 0 : 0) + 1
                quickStreak = (step, count)
                if count < 2 { return .log }
            } else {
                quickStreak = nil
            }
            guard decision.level != .log else { return decision }
            if raised.contains(where: { $0.step == step && Self.similar($0.issue, result.issue) }) {
                return .log
            }
        }
        if decision.level != .log {
            raised.append((step, result.issue, now))
        }
        return decision
    }

    mutating func stepChanged() {
        quickStreak = nil
    }

    // MARK: Issue similarity

    private static let numberWords = [
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
    ]
    private static let stopWords: Set<String> = [
        "i", "see", "the", "a", "an", "is", "are", "of", "and", "to",
        "procedure", "says", "should", "be", "it", "there",
    ]

    private static func words(_ text: String) -> Set<String> {
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopWords.contains($0) }
            .map { numberWords[$0] ?? $0 }
            .map { $0.hasSuffix("s") && $0.count > 3 ? String($0.dropLast()) : $0 }
        return Set(tokens)
    }

    /// Jaccard overlap of content words (numbers normalised, plurals folded).
    static func similar(_ a: String, _ b: String) -> Bool {
        let x = words(a), y = words(b)
        if x.isEmpty && y.isEmpty { return true }
        let union = x.union(y).count
        return union > 0 && Double(x.intersection(y).count) / Double(union) >= similarityThreshold
    }
}
