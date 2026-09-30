//
// Standalone tests for ChangeGate. Build + run:
//   xcrun swiftc HermesGlasses/Services/BuildCheck/ChangeGate.swift \
//     tests/buildcheck-gate/main.swift -o /tmp/bc-gate && /tmp/bc-gate
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}
let t0 = Date(timeIntervalSince1970: 1_000_000)
var g = ChangeGate()
let c = g.config
expect(c.changeThreshold == 0.35 && c.settleThreshold == 0.12 && c.minInterval == 15 && c.budgetPerHour == 120, "defaults")

expect(g.evaluate(distanceFromChecked: nil, distanceFromPrevious: nil, now: t0) == .unsettled, "first frame: no previous → unsettled")
expect(g.evaluate(distanceFromChecked: nil, distanceFromPrevious: 0.05, now: t0) == .send, "nothing checked yet + settled → send")
expect(g.evaluate(distanceFromChecked: 0.9, distanceFromPrevious: 0.3, now: t0) == .unsettled, "moving → unsettled")
expect(g.evaluate(distanceFromChecked: 0.2, distanceFromPrevious: 0.05, now: t0) == .unchanged, "settled but same scene → unchanged")
expect(g.evaluate(distanceFromChecked: 0.35, distanceFromPrevious: 0.05, now: t0) == .unchanged, "change threshold is exclusive")
expect(g.evaluate(distanceFromChecked: 0.5, distanceFromPrevious: 0.12, now: t0) == .unsettled, "settle threshold is exclusive")

g.recordSent(at: t0)
expect(g.evaluate(distanceFromChecked: 0.5, distanceFromPrevious: 0.05, now: t0 + 14) == .tooSoon, "14 s after a send → tooSoon")
expect(g.evaluate(distanceFromChecked: 0.5, distanceFromPrevious: 0.05, now: t0 + 15) == .send, "15 s → send")

var small = ChangeGate(config: .init(changeThreshold: 0.35, settleThreshold: 0.12, minInterval: 0, budgetPerHour: 2))
small.recordSent(at: t0)
small.recordSent(at: t0 + 1)
expect(small.budgetUsed(now: t0 + 2) == 2, "budget used counts sends")
expect(small.evaluate(distanceFromChecked: 0.9, distanceFromPrevious: 0.01, now: t0 + 2) == .overBudget, "budget exhausted")
expect(small.evaluate(distanceFromChecked: 0.9, distanceFromPrevious: 0.01, now: t0 + 3601) == .send, "rolling hour frees budget")
expect(small.budgetUsed(now: t0 + 3601.5) == 0, "both sends aged out")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
