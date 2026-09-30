//
// Standalone tests for BuildRun / SaveThrottle / BuildRunSummary. Build + run:
//   xcrun swiftc \
//     HermesGlasses/Services/BuildCheck/BuildCheckJSON.swift \
//     HermesGlasses/Services/BuildCheck/Procedure.swift \
//     HermesGlasses/Services/BuildCheck/BuildCheckPrompt.swift \
//     HermesGlasses/Services/BuildCheck/AlertPolicy.swift \
//     HermesGlasses/Services/BuildCheck/ChangeGate.swift \
//     HermesGlasses/Services/BuildCheck/BuildRun.swift \
//     tests/buildcheck-run/main.swift -o /tmp/bc-run && /tmp/bc-run
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}
let t0 = Date(timeIntervalSince1970: 1_000_000)
let proc = Procedure(title: "P", steps: [
    ProcedureStep(text: "a"), ProcedureStep(text: "b", critical: true),
    ProcedureStep(text: "c"), ProcedureStep(text: "d"),
], now: t0)
let settings = BuildRunSettings(intervalSeconds: 5, gate: ChangeGate.Config(), checksEnabled: true)
var run = BuildRun(id: UUID(), procedure: proc, operatorName: "Sam", startedAt: t0,
                   endedAt: nil, settings: settings, events: [])

let pass = CheckResult(verdict: .match, confidence: 0.9, observed: "ok", issue: "")
let bad = CheckResult(verdict: .mismatch, confidence: 0.9, observed: "3 bolts", issue: "I see 3 bolts, the procedure says 4")
let c0 = UUID(), c1 = UUID(), c2 = UUID(), a1 = UUID(), a2 = UUID()
run.events = [
    .frame(t: t0, step: 0, filename: "f-1.jpg", sentToAI: true),
    .speech(t: t0 + 1, step: 0, text: "fitting bracket"),
    .check(id: c0, t: t0 + 2, step: 0, kind: .full, frames: ["f-1.jpg"], result: pass, error: nil),
    .stepChange(t: t0 + 3, from: 0, to: 1, via: .voice),
    .check(id: c1, t: t0 + 4, step: 1, kind: .full, frames: [], result: bad, error: nil),
    .alert(id: a1, t: t0 + 4, step: 1, checkID: c1, level: .speak, askedToConfirm: false),
    .reply(t: t0 + 6, step: 1, alertID: a1, reply: .override),
    .stepChange(t: t0 + 6, from: 1, to: 2, via: .override),
    .check(id: c2, t: t0 + 7, step: 2, kind: .quick, frames: [], result: bad, error: nil),
    .alert(id: a2, t: t0 + 7, step: 2, checkID: c2, level: .chime, askedToConfirm: false),
    .reply(t: t0 + 8, step: 2, alertID: a2, reply: .ignore),
]

// Summary
let flags = BuildRunSummary.flags(in: run)
expect(flags.count == 2, "two flags")
expect(flags[0].reply == .override && flags[0].issue == bad.issue && flags[0].level == .speak, "flag carries issue + reply")
expect(flags[1].reply == .ignore, "second flag ignored")
expect(BuildRunSummary.stepStatuses(run) == [.passed, .unresolved, .flagResolved, .unchecked], "step statuses")
expect(BuildRunSummary.spokenSummary(run) == "Run saved. 2 flags, 1 unresolved.", "spoken summary")

var clean = run
clean.events = [.check(id: UUID(), t: t0, step: 0, kind: .full, frames: [], result: pass, error: nil)]
expect(BuildRunSummary.spokenSummary(clean) == "Run saved. No flags.", "no flags")
var oneOpen = run
oneOpen.events = [
    .check(id: c1, t: t0, step: 1, kind: .full, frames: [], result: bad, error: nil),
    .alert(id: a1, t: t0, step: 1, checkID: c1, level: .speak, askedToConfirm: false),
]
expect(BuildRunSummary.flags(in: oneOpen)[0].reply == nil, "unanswered flag has no reply")
expect(BuildRunSummary.stepStatuses(oneOpen)[1] == .unresolved, "unanswered → unresolved")
expect(BuildRunSummary.spokenSummary(oneOpen) == "Run saved. 1 flag, 1 unresolved.", "singular flag")

// Codable round trip, crash recovery, unknown event kinds
let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
let data = try! enc.encode(run)
let back = try! dec.decode(BuildRun.self, from: data)
expect(back == run, "round trip")
expect(back.endedAt == nil, "an unfinished (crashed) run decodes with endedAt nil")

var json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
var events = json["events"] as! [[String: Any]]
events.insert(["kind": "hologram", "t": "2026-10-01T00:00:00Z", "step": 0], at: 1)
json["events"] = events
json.removeValue(forKey: "operatorName")
let tolerant = try! dec.decode(BuildRun.self, from: try! JSONSerialization.data(withJSONObject: json))
expect(tolerant.events.count == run.events.count, "unknown event kind dropped, rest kept")
expect(tolerant.operatorName == "", "missing operatorName defaults to empty")

// SaveThrottle
var th = SaveThrottle()
expect(th.shouldSave(now: t0, force: false), "first save goes through")
expect(!th.shouldSave(now: t0 + 5, force: false), "within 10 s held")
expect(th.shouldSave(now: t0 + 6, force: true), "forced save goes through")
expect(!th.shouldSave(now: t0 + 15, force: false), "window restarts from the forced save")
expect(th.shouldSave(now: t0 + 16, force: false), "10 s after last save")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
