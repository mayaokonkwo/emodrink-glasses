//
// ChangeGate.swift
//
// Which frames are worth a quick AI check. Distances are Vision feature-
// print distances (BuildCheckVision): from the last frame that WAS checked
// (has the scene changed?) and from the previous frame (has it settled, or
// are hands still moving?). Checking only settled, changed scenes is what
// keeps the per-hour cost bounded without missing a new state of the work.
// Thresholds are PROVISIONAL - measure with tools/changegate-probe.swift.
// Foundation only; tested in tests/buildcheck-gate.
//

import Foundation

struct ChangeGate {
    struct Config: Codable, Equatable {
        var changeThreshold: Float = 0.35
        var settleThreshold: Float = 0.12
        var minInterval: TimeInterval = 15
        var budgetPerHour: Int = 120
    }

    enum Decision: Equatable { case send, unsettled, unchanged, tooSoon, overBudget }

    let config: Config
    private var sent: [Date] = []

    init(config: Config = Config()) { self.config = config }

    func budgetUsed(now: Date) -> Int {
        sent.filter { now.timeIntervalSince($0) < 3600 }.count
    }

    /// - Parameters:
    ///   - distanceFromChecked: nil when nothing has been checked yet (counts as changed).
    ///   - distanceFromPrevious: nil on the first frame (counts as unsettled).
    func evaluate(distanceFromChecked: Float?, distanceFromPrevious: Float?, now: Date) -> Decision {
        guard let previous = distanceFromPrevious, previous < config.settleThreshold else { return .unsettled }
        if let checked = distanceFromChecked, checked <= config.changeThreshold { return .unchanged }
        if let last = sent.last, now.timeIntervalSince(last) < config.minInterval { return .tooSoon }
        if budgetUsed(now: now) >= config.budgetPerHour { return .overBudget }
        return .send
    }

    /// Call only when a quick check is actually dispatched.
    mutating func recordSent(at date: Date) {
        sent.append(date)
        sent.removeAll { date.timeIntervalSince($0) >= 3600 }
    }
}
