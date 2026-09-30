//
// BuildRunTracker.swift
//
// Which step the wearer is on, and the critical-step gate. The wearer
// always advances ("step done", a glasses button); the AI never moves the
// step by itself. A critical step waits for its end-of-step check, and a
// confident mismatch blocks it until a re-check passes ("fixed") or the
// wearer overrides. Foundation only; tested in tests/buildcheck-tracker.
//

import Foundation

struct BuildRunTracker: Equatable {
    enum Phase: Equatable { case working, checking, blocked, finished }
    enum Outcome: Equatable { case advanced(to: Int), finished, awaitingCheck, refused }

    let stepCount: Int
    let criticalSteps: Set<Int>
    private(set) var current = 0
    private(set) var phase: Phase = .working

    init(stepCount: Int, criticalSteps: Set<Int>) {
        self.stepCount = stepCount
        self.criticalSteps = criticalSteps
        if stepCount == 0 { phase = .finished }
    }

    var isCurrentCritical: Bool { criticalSteps.contains(current) }

    mutating func stepDone() -> Outcome {
        guard phase == .working else { return .refused }
        if isCurrentCritical {
            phase = .checking
            return .awaitingCheck
        }
        return advance()
    }

    /// `blocking` = the check was a confident mismatch.
    mutating func criticalCheckFinished(step: Int, blocking: Bool) -> Outcome {
        guard phase == .checking, step == current else { return .refused }
        if blocking {
            phase = .blocked
            return .refused
        }
        return advance()
    }

    /// "fixed" on a blocked step: the caller runs a fresh critical check.
    mutating func fixed() -> Bool {
        guard phase == .blocked else { return false }
        phase = .checking
        return true
    }

    /// "override": the wearer takes responsibility; logged by the caller.
    mutating func override() -> Outcome {
        guard phase == .blocked else { return .refused }
        return advance()
    }

    mutating func finish() { phase = .finished }

    /// Whether an end-of-step check holds a critical step. The first check
    /// blocks only on a confident mismatch (an unsure answer must not stop
    /// work); a re-check of a BLOCKED step unblocks only on a match. `nil`
    /// = no result at all (no camera frame, the call failed).
    static func blocks(result: CheckResult?, isRecheckOfBlockedStep: Bool) -> Bool {
        if isRecheckOfBlockedStep { return result?.verdict != .match }
        return result?.isConfidentMismatch ?? false
    }

    private mutating func advance() -> Outcome {
        if current + 1 >= stepCount {
            phase = .finished
            return .finished
        }
        current += 1
        phase = .working
        return .advanced(to: current)
    }
}
