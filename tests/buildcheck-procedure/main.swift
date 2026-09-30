//
// Standalone tests for Procedure + BuildCheckJSON. Build + run:
//   xcrun swiftc \
//     HermesGlasses/Services/BuildCheck/BuildCheckJSON.swift \
//     HermesGlasses/Services/BuildCheck/Procedure.swift \
//     tests/buildcheck-procedure/main.swift -o /tmp/bc-procedure && /tmp/bc-procedure
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

let t0 = Date(timeIntervalSince1970: 1_000_000)

// BuildCheckJSON
expect(BuildCheckJSON.object(in: #"{"a":1}"#)?["a"] as? Int == 1, "bare object")
expect(BuildCheckJSON.object(in: "```json\n{\"a\":2}\n```")?["a"] as? Int == 2, "fenced object")
expect(BuildCheckJSON.object(in: "Sure! Here it is: {\"a\":3} Hope that helps.")?["a"] as? Int == 3, "prose around")
expect(BuildCheckJSON.object(in: "no json here") == nil, "no braces → nil")
expect(BuildCheckJSON.object(in: "{not json}") == nil, "invalid → nil")
expect(BuildCheckJSON.object(in: "} backwards {") == nil, "close before open → nil")

// Procedure lifecycle
var p = Procedure(title: "Bracket B", steps: [
    ProcedureStep(text: "Fit bracket", critical: false),
    ProcedureStep(text: "Torque bolts to 9 Nm", critical: true),
], now: t0)
expect(p.version == 1 && !p.ready, "new procedure is v1 draft")
expect(p.criticalStepIndices == [1], "critical indices")
expect(p.canBeReady, "complete procedure can be ready")
expect(p.markReady(now: t0) && p.ready, "markReady")
p.edit(now: t0.addingTimeInterval(5)) { $0.steps[0].text = "Fit bracket B" }
expect(p.version == 2, "edit bumps version")
expect(!p.ready, "edit sends it back to draft")
expect(p.updatedAt == t0.addingTimeInterval(5), "edit stamps updatedAt")

var empty = Procedure(title: "E", steps: [], now: t0)
expect(!empty.canBeReady && !empty.markReady(now: t0), "no steps → cannot be ready")
var blankStep = Procedure(title: "B", steps: [ProcedureStep(text: "  ")], now: t0)
expect(!blankStep.markReady(now: t0), "blank step text → cannot be ready")
var untitled = Procedure(title: " ", steps: [ProcedureStep(text: "x")], now: t0)
expect(!untitled.markReady(now: t0), "blank title → cannot be ready")

// Codable round trip + tolerant decode
let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
let back = try! dec.decode(Procedure.self, from: try! enc.encode(p))
expect(back == p, "round trip")
let sparse = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Old","steps":[{"text":"Only text"}]}"#
let old = try! dec.decode(Procedure.self, from: Data(sparse.utf8))
expect(old.version == 1 && !old.ready && old.steps.count == 1, "missing keys default")
expect(old.steps[0].referencePhotoFilenames.isEmpty && !old.steps[0].critical, "step defaults")
expect(Procedure.maxReferencePhotos == 3, "reference photo cap")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
