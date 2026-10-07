//
// VendingMachineGate.swift
//
// Which drink-mode frames are worth a vision check. Wraps Build Check's
// ChangeGate (settled + changed + spacing + hourly budget) and adds the one
// rule drink mode needs on top: after a pick is shown, nothing is sent for
// two minutes, so the wearer is not re-offered a drink while deciding.
// Foundation only; tested in tests/emodrink-detector.
//

import Foundation

struct VendingMachineGate {
    enum Decision: Equatable { case send, unsettled, unchanged, tooSoon, overBudget, coolingDown }

    static let cooldownSeconds: TimeInterval = 120
    static let defaultConfig = ChangeGate.Config(
        changeThreshold: 0.35, settleThreshold: 0.12, minInterval: 8, budgetPerHour: 150)

    private var gate: ChangeGate
    private(set) var cooldownUntil: Date?

    init(config: ChangeGate.Config = VendingMachineGate.defaultConfig) {
        gate = ChangeGate(config: config)
    }

    func budgetUsed(now: Date) -> Int { gate.budgetUsed(now: now) }

    /// When the budget is exhausted, the moment it frees. Nil otherwise.
    func restingUntil(now: Date) -> Date? {
        guard gate.budgetUsed(now: now) >= gate.config.budgetPerHour,
              let oldest = gate.oldestSent(now: now) else { return nil }
        return oldest.addingTimeInterval(3600)
    }

    mutating func evaluate(distanceFromChecked: Float?, distanceFromPrevious: Float?, now: Date) -> Decision {
        if let until = cooldownUntil {
            if now < until { return .coolingDown }
            cooldownUntil = nil
        }
        switch gate.evaluate(distanceFromChecked: distanceFromChecked, distanceFromPrevious: distanceFromPrevious, now: now) {
        case .send: return .send
        case .unsettled: return .unsettled
        case .unchanged: return .unchanged
        case .tooSoon: return .tooSoon
        case .overBudget: return .overBudget
        }
    }

    mutating func recordSent(at date: Date) { gate.recordSent(at: date) }

    mutating func startCooldown(at now: Date) {
        cooldownUntil = now.addingTimeInterval(Self.cooldownSeconds)
    }
}
