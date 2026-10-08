//
// HermesDisplayLogic.swift
//
// Pure logic for the glasses display HUD: reply truncation, dwell
// times, and partial-transcript send throttling. Foundation-only so it
// unit-tests standalone (tests/display-logic/) without the DAT SDK.
//

import Foundation

enum HermesDisplayLogic {
    /// Replies longer than this are cut with an ellipsis - spoken
    /// replies are 1-3 sentences, so truncation is rare.
    static let replyCharLimit = 300

    /// How long a spoken reply stays on the lens after TTS ends.
    static let spokenDwellSeconds: Double = 8

    /// Minimum interval between partial-transcript sends (BLE budget).
    static let partialMinInterval: TimeInterval = 0.4

    static func truncateReply(
        _ text: String, limit: Int = replyCharLimit
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }

    /// Silent mode: reading time instead of TTS duration.
    static func readingDwellSeconds(charCount: Int) -> Double {
        max(6, (Double(charCount) / 15).rounded(.up))
    }
}

/// Rate limiter for partial-transcript sends. Callers bypass it for
/// finalized utterances (those always send).
struct DisplaySendThrottle {
    private var lastSent: Date?
    let minInterval: TimeInterval

    init(minInterval: TimeInterval = HermesDisplayLogic.partialMinInterval) {
        self.minInterval = minInterval
    }

    mutating func shouldSend(at now: Date = Date()) -> Bool {
        if let lastSent, now.timeIntervalSince(lastSent) < minInterval {
            return false
        }
        lastSent = now
        return true
    }
}

/// What the Developer panel's Display test reports (spec section 8). The
/// session decides what happened; this names it, the same way every time.
enum DisplayTestReport: Equatable {
    case sent
    case noGlasses
    case sessionFailed(String)
    case micInUse

    /// How long the test waits for the display capability to attach.
    static let attachTimeoutSeconds: Double = 5
    /// How long the test card stays before the lens returns to normal.
    static let cardSeconds: Double = 4

    var message: String {
        switch self {
        case .sent: return "Test card sent"
        case .noGlasses: return "No glasses connected"
        case .sessionFailed(let error): return "Display session failed: \(error)"
        case .micInUse:
            return "The glasses microphone is in use, so the glasses show their call screen instead of the HUD. Switch the mic to iPhone and try again."
        }
    }

    var isSuccess: Bool { self == .sent }

    /// What can be known before touching the SDK. Nil = go ahead and attach.
    static func preflight(glassesReachable: Bool, glassesMicActive: Bool) -> DisplayTestReport? {
        if !glassesReachable { return .noGlasses }
        if glassesMicActive { return .micInUse }
        return nil
    }
}
