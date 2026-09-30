//
// Standalone tests for AlertPolicy. Build + run:
//   xcrun swiftc \
//     HermesGlasses/Services/BuildCheck/BuildCheckJSON.swift \
//     HermesGlasses/Services/BuildCheck/Procedure.swift \
//     HermesGlasses/Services/BuildCheck/BuildCheckPrompt.swift \
//     HermesGlasses/Services/BuildCheck/AlertPolicy.swift \
//     tests/buildcheck-alerts/main.swift -o /tmp/bc-alerts && /tmp/bc-alerts
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}
func r(_ v: CheckVerdict, _ c: Double, _ issue: String = "I see three bolts, the procedure says four") -> CheckResult {
    CheckResult(verdict: v, confidence: c, observed: "", issue: issue)
}
let t0 = Date(timeIntervalSince1970: 1_000_000)
let speak = AlertDecision(level: .speak, askToConfirm: false)
let chime = AlertDecision(level: .chime, askToConfirm: false)

// The table (baseDecision)
typealias P = AlertPolicy
expect(P.baseDecision(result: r(.mismatch, 0.8), kind: .full, critical: true) == speak, "confident mismatch, critical → speak")
expect(P.baseDecision(result: r(.mismatch, 0.8), kind: .full, critical: false) == chime, "confident mismatch, non-critical → chime")
expect(P.baseDecision(result: r(.mismatch, 0.6), kind: .full, critical: true) == chime, "mid mismatch, critical → chime")
expect(P.baseDecision(result: r(.mismatch, 0.6), kind: .full, critical: false) == .log, "mid mismatch, non-critical → log")
expect(P.baseDecision(result: r(.mismatch, 0.4), kind: .full, critical: true) == .log, "low mismatch → log")
expect(P.baseDecision(result: r(.unclear, 0), kind: .full, critical: true)
       == AlertDecision(level: .chime, askToConfirm: true), "unclear full on critical → chime + ask")
expect(P.baseDecision(result: r(.unclear, 0), kind: .quick, critical: true) == .log, "unclear quick → log")
expect(P.baseDecision(result: r(.unclear, 0), kind: .full, critical: false) == .log, "unclear full non-critical → log")
expect(P.baseDecision(result: r(.match, 0.99), kind: .full, critical: true) == .log, "match → log")
expect(P.baseDecision(result: r(.mismatch, 0.75), kind: .full, critical: true) == speak, "0.75 boundary is high")
expect(P.baseDecision(result: r(.mismatch, 0.5), kind: .full, critical: true) == chime, "0.5 boundary is low")

// Two consecutive quick mismatches before escalating
var p = AlertPolicy()
expect(p.decide(result: r(.mismatch, 0.9), kind: .quick, step: 2, critical: true, now: t0) == .log, "first quick mismatch held")
expect(p.decide(result: r(.mismatch, 0.9), kind: .quick, step: 2, critical: true, now: t0 + 20) == speak, "second consecutive → speak")

var q = AlertPolicy()
_ = q.decide(result: r(.mismatch, 0.9), kind: .quick, step: 2, critical: true, now: t0)
_ = q.decide(result: r(.match, 0.9), kind: .quick, step: 2, critical: true, now: t0 + 20)
expect(q.decide(result: r(.mismatch, 0.9), kind: .quick, step: 2, critical: true, now: t0 + 40) == .log, "a match in between resets the streak")

var s = AlertPolicy()
_ = s.decide(result: r(.mismatch, 0.9), kind: .quick, step: 2, critical: true, now: t0)
s.stepChanged()
expect(s.decide(result: r(.mismatch, 0.9), kind: .quick, step: 3, critical: true, now: t0 + 20) == .log, "new step resets the streak")

// Full checks escalate on their own
var f = AlertPolicy()
expect(f.decide(result: r(.mismatch, 0.9), kind: .full, step: 4, critical: true, now: t0) == speak, "full escalates alone")

// 120 s suppression for quick checks, similar issue, same step
var d = AlertPolicy()
_ = d.decide(result: r(.mismatch, 0.9), kind: .quick, step: 1, critical: true, now: t0)
expect(d.decide(result: r(.mismatch, 0.9), kind: .quick, step: 1, critical: true, now: t0 + 15) == speak, "raised once")
expect(d.decide(result: r(.mismatch, 0.9, "I see 3 bolts, the procedure says four bolts"), kind: .quick, step: 1, critical: true, now: t0 + 30) == .log, "similar issue within 120 s → log")
expect(d.decide(result: r(.mismatch, 0.9, "The bracket is upside down"), kind: .quick, step: 1, critical: true, now: t0 + 45) == speak, "different issue → raised")
expect(d.decide(result: r(.mismatch, 0.9), kind: .quick, step: 1, critical: true, now: t0 + 140) == speak, "after 120 s → raised again")

// "fixed" → re-check (full) must be heard even inside the window
var fx = AlertPolicy()
_ = fx.decide(result: r(.mismatch, 0.9), kind: .full, step: 5, critical: true, now: t0)
expect(fx.decide(result: r(.mismatch, 0.9), kind: .full, step: 5, critical: true, now: t0 + 10) == speak, "full re-check bypasses suppression")

// similarity
expect(AlertPolicy.similar("I see three bolts, the procedure says four", "I see 3 bolts; procedure says four bolts"), "similar wording")
expect(!AlertPolicy.similar("three bolts missing", "bracket upside down"), "different wording")
expect(AlertPolicy.similar("", ""), "two empty issues are similar")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
