//
// PhysiologySnapshot.swift
//
// One day's body data, as the remote JSON document or a mock profile
// describes it, plus the coarse BodyState the recommender reads. Mirrors
// EmoDrink's arousal-valence framing: two axes, three levels each, never
// a named emotion. Foundation only; tested in tests/emodrink-snapshot.
//

import Foundation

struct SleepSummary: Codable, Equatable {
    var hours: Double
    var score: Int?
}

struct PhysiologySnapshot: Codable, Equatable {
    /// "yyyy-MM-dd" in the wearer's local calendar.
    var date: String
    /// Where the numbers came from ("Garmin Venu 3S", "sample: short night").
    var source: String
    var sleep: SleepSummary
    var hrvMs: Double?
    var hrvBaselineMs: Double?
    var restingHR: Double?
    var restingHRBaseline: Double?
    var steps: Int?
    /// 0 to 100, the watch's own stress figure when it has one.
    var stress: Int?

    enum CodingKeys: String, CodingKey {
        case date, source, sleep, steps, stress
        case hrvMs = "hrv_ms"
        case hrvBaselineMs = "hrv_baseline_ms"
        case restingHR = "resting_hr"
        case restingHRBaseline = "resting_hr_baseline"
    }

    static func decode(_ data: Data) throws -> PhysiologySnapshot {
        try JSONDecoder().decode(PhysiologySnapshot.self, from: data)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// HRV minus the wearer's usual, in ms. Nil without both figures.
    var hrvDelta: Double? {
        guard let hrvMs, let hrvBaselineMs else { return nil }
        return hrvMs - hrvBaselineMs
    }

    /// Resting heart rate minus the wearer's usual, in bpm. Nil without both.
    var restingHRDelta: Double? {
        guard let restingHR, let restingHRBaseline else { return nil }
        return restingHR - restingHRBaseline
    }

    var bodyState: BodyState { BodyState(snapshot: self) }

    func isToday(_ dayString: String) -> Bool { date == dayString }
}

enum BodyLevel: Int, Comparable, Equatable {
    case low = 0, mid, high

    static func < (a: BodyLevel, b: BodyLevel) -> Bool { a.rawValue < b.rawValue }

    var up: BodyLevel { BodyLevel(rawValue: min(2, rawValue + 1)) ?? self }
    var down: BodyLevel { BodyLevel(rawValue: max(0, rawValue - 1)) ?? self }
}

/// Spec section 5, step 1. Thresholds are the spec's; change them there first.
struct BodyState: Equatable {
    let recovery: BodyLevel
    let arousal: BodyLevel

    init(recovery: BodyLevel, arousal: BodyLevel) {
        self.recovery = recovery
        self.arousal = arousal
    }

    init(snapshot s: PhysiologySnapshot) {
        var recovery: BodyLevel
        if s.sleep.hours < 6 { recovery = .low }
        else if s.sleep.hours < 7 { recovery = .mid }
        else { recovery = .high }

        let scoreLow = (s.sleep.score ?? 100) < 50
        let hrvLow = (s.hrvDelta ?? 0) < -10
        if scoreLow || hrvLow { recovery = recovery.down }

        let scoreHigh = (s.sleep.score ?? 0) >= 80
        let hrvAtOrAbove = (s.hrvDelta ?? -1) >= 0
        if scoreHigh && hrvAtOrAbove { recovery = recovery.up }

        var arousal: BodyLevel = .mid
        if let delta = s.restingHRDelta {
            if delta >= 5 { arousal = .high }
            else if delta <= -5 { arousal = .low }
        }
        if let stress = s.stress {
            if stress >= 65 { arousal = .high }
            else if stress <= 25, recovery == .low { arousal = .low }
        }

        self.recovery = recovery
        self.arousal = arousal
    }
}

/// The day string the snapshot carries, in the wearer's calendar.
enum EmoDrinkDay {
    static func string(for date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
