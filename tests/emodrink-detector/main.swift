//
// Standalone tests for the vending machine gate + detector parser. Run:
//   xcrun swiftc \
//     HermesGlasses/Services/EmoDrink/ChangeGate.swift \
//     HermesGlasses/Services/EmoDrink/VendingMachineGate.swift \
//     HermesGlasses/Services/EmoDrink/VendingMachineDetector.swift \
//     tests/emodrink-detector/main.swift -o /tmp/ed-detector && /tmp/ed-detector
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

// Parser: only a leading YES counts.
expect(VendingMachineDetector.isYes("YES"), "YES")
expect(VendingMachineDetector.isYes("yes."), "yes.")
expect(VendingMachineDetector.isYes("Yes, there is a vending machine"), "Yes, there is")
expect(VendingMachineDetector.isYes("  \nYES\n"), "whitespace around YES")
expect(!VendingMachineDetector.isYes("NO"), "NO")
expect(!VendingMachineDetector.isYes("No. But yes there is a fridge"), "a later yes does not count")
expect(!VendingMachineDetector.isYes("Yesterday's photo"), "YESTERDAY is not YES")
expect(!VendingMachineDetector.isYes(""), "empty")
expect(!VendingMachineDetector.isYes("I cannot see the image"), "refusal")
expect(VendingMachineDetector.userText.contains("YES or NO"), "prompt asks for one word")
expect(VendingMachineDetector.systemPrompt.contains("one word"), "system prompt asks for one word")

// Gate defaults from the spec.
expect(VendingMachineGate.defaultConfig.minInterval == 8 && VendingMachineGate.defaultConfig.budgetPerHour == 150, "8 s / 150 per hour")
expect(VendingMachineGate.cooldownSeconds == 120, "120 s cooldown")

let t0 = Date(timeIntervalSince1970: 1_700_000_000)
var gate = VendingMachineGate()
expect(gate.evaluate(distanceFromChecked: nil, distanceFromPrevious: nil, now: t0) == .unsettled, "first frame is unsettled")
expect(gate.evaluate(distanceFromChecked: nil, distanceFromPrevious: 0.05, now: t0) == .send, "settled and never checked sends")
gate.recordSent(at: t0)
expect(gate.evaluate(distanceFromChecked: 0.1, distanceFromPrevious: 0.05, now: t0 + 9) == .unchanged, "same scene is unchanged")
expect(gate.evaluate(distanceFromChecked: 0.5, distanceFromPrevious: 0.05, now: t0 + 4) == .tooSoon, "changed but inside minInterval is tooSoon")
expect(gate.evaluate(distanceFromChecked: 0.5, distanceFromPrevious: 0.05, now: t0 + 9) == .send, "changed after minInterval sends")

// Cooldown wins over everything.
gate.startCooldown(at: t0 + 10)
expect(gate.cooldownUntil == t0 + 130, "cooldown ends 120 s later")
expect(gate.evaluate(distanceFromChecked: 0.9, distanceFromPrevious: 0.01, now: t0 + 60) == .coolingDown, "inside cooldown nothing is sent")
expect(gate.evaluate(distanceFromChecked: 0.9, distanceFromPrevious: 0.01, now: t0 + 131) == .send, "after cooldown sending resumes")

// Budget.
var busy = VendingMachineGate(config: ChangeGate.Config(changeThreshold: 0.35, settleThreshold: 0.12, minInterval: 0, budgetPerHour: 2))
busy.recordSent(at: t0)
busy.recordSent(at: t0 + 1)
expect(busy.budgetUsed(now: t0 + 2) == 2, "budget counts the hour")
expect(busy.evaluate(distanceFromChecked: 0.9, distanceFromPrevious: 0.01, now: t0 + 2) == .overBudget, "over budget")
expect(busy.restingUntil(now: t0 + 2) == t0 + 3600, "resting until the oldest send ages out")
expect(busy.evaluate(distanceFromChecked: 0.9, distanceFromPrevious: 0.01, now: t0 + 3601) == .send, "budget frees after an hour")
expect(busy.restingUntil(now: t0 + 3601) == nil, "not resting when under budget")

// ChangeGate addition.
var cg = ChangeGate()
expect(cg.oldestSent(now: t0) == nil, "no sends: nil")
cg.recordSent(at: t0); cg.recordSent(at: t0 + 10)
expect(cg.oldestSent(now: t0 + 20) == t0, "oldest in window")
expect(cg.oldestSent(now: t0 + 3605) == t0 + 10, "aged-out sends are ignored")

// isYes skips leading non-letters.
expect(VendingMachineDetector.isYes("**YES**"), "markdown bold YES is YES")
expect(VendingMachineDetector.isYes("\"Yes, a machine\""), "quoted Yes is YES")
expect(VendingMachineDetector.isYes("- YES"), "bulleted YES is YES")
expect(!VendingMachineDetector.isYes("1. Yesterday"), "numbered Yesterday is NO")
expect(!VendingMachineDetector.isYes("**NO**"), "markdown bold NO is NO")

// Check now: bypasses the change gate and the cooldown, never the budget.
var checkGate = VendingMachineGate(config: ChangeGate.Config(changeThreshold: 0.35, settleThreshold: 0.12, minInterval: 8, budgetPerHour: 2))
let c0 = Date(timeIntervalSince1970: 1_800_000_000)
expect(checkGate.canCheckNow(now: c0), "check now allowed with budget left")
checkGate.startCooldown(at: c0)
expect(checkGate.canCheckNow(now: c0 + 1), "check now ignores the post-pick cooldown")
checkGate.recordSent(at: c0 + 1)
checkGate.recordSent(at: c0 + 2)
expect(!checkGate.canCheckNow(now: c0 + 3), "check now refused when the hour's budget is spent")
expect(checkGate.canCheckNow(now: c0 + 3602), "the budget frees an hour after the oldest send")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
