//
// Standalone tests for BuildCheckPrompt / CheckResult. Build + run:
//   xcrun swiftc \
//     HermesGlasses/Services/BuildCheck/BuildCheckJSON.swift \
//     HermesGlasses/Services/BuildCheck/Procedure.swift \
//     HermesGlasses/Services/BuildCheck/BuildCheckPrompt.swift \
//     tests/buildcheck-verdict/main.swift -o /tmp/bc-verdict && /tmp/bc-verdict
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

let ok = BuildCheckPrompt.parseVerdict(#"{"verdict":"mismatch","confidence":0.82,"observed":"three bolts","issue":"I see three bolts, the procedure says four"}"#)
expect(ok == CheckResult(verdict: .mismatch, confidence: 0.82, observed: "three bolts",
                         issue: "I see three bolts, the procedure says four"), "clean reply")
expect(ok.isConfidentMismatch, "0.82 mismatch is confident")

let fenced = BuildCheckPrompt.parseVerdict("```json\n{\"verdict\":\"match\",\"confidence\":0.9,\"observed\":\"ok\",\"issue\":\"\"}\n```")
expect(fenced.verdict == .match && fenced.confidence == 0.9, "fenced reply")

let prose = BuildCheckPrompt.parseVerdict("Looks good to me! {\"verdict\":\"MATCH\",\"confidence\":1} Anything else?")
expect(prose.verdict == .match && prose.observed == "" && prose.issue == "", "prose + uppercase + missing strings")

expect(BuildCheckPrompt.parseVerdict(#"{"verdict":"mismatch","confidence":1.7}"#).confidence == 1.0, "confidence clamped to 1")
expect(BuildCheckPrompt.parseVerdict(#"{"verdict":"mismatch","confidence":-2}"#).confidence == 0.0, "confidence clamped to 0")
expect(BuildCheckPrompt.parseVerdict(#"{"verdict":"mismatch","confidence":"0.8"}"#).confidence == 0.8, "string confidence")
let noConf = BuildCheckPrompt.parseVerdict(#"{"verdict":"mismatch"}"#)
expect(noConf.confidence == 0 && !noConf.isConfidentMismatch, "missing confidence → 0, never a confident alarm")

let bad = BuildCheckPrompt.parseVerdict("I cannot see the part.")
expect(bad.verdict == .unclear && bad.confidence == 0, "no JSON → unclear")
expect(BuildCheckPrompt.parseVerdict(#"{"verdict":"probably fine"}"#).verdict == .unclear, "unknown verdict → unclear")
expect(!CheckResult(verdict: .mismatch, confidence: 0.74, observed: "", issue: "").isConfidentMismatch, "0.74 not confident")
expect(!CheckResult(verdict: .unclear, confidence: 0.99, observed: "", issue: "").isConfidentMismatch, "unclear never confident mismatch")

let step = ProcedureStep(text: "Torque 4 bolts to 9 Nm", critical: true, expectedLook: "4 bolt heads with torque stripes")
let quick = BuildCheckPrompt.quickPrompt(step: step, number: 3, total: 7)
expect(quick.contains("Step 3 of 7 (CRITICAL): Torque 4 bolts to 9 Nm"), "quick prompt names the step")
expect(quick.contains("4 bolt heads with torque stripes"), "quick prompt carries expected look")
let plain = BuildCheckPrompt.quickPrompt(step: ProcedureStep(text: "Fit cover"), number: 1, total: 2)
expect(!plain.contains("CRITICAL") && !plain.contains("looks like"), "no critical tag / empty look omitted")
let full = BuildCheckPrompt.fullPrompt(step: step, number: 3, total: 7, tileLabels: ["REFERENCE 1", "NOW -4s"])
expect(full.contains("REFERENCE 1, NOW -4s"), "full prompt lists tiles")
expect(BuildCheckPrompt.systemPrompt.contains("\"unclear\""), "system prompt defines unclear")

let enc = JSONEncoder(), dec = JSONDecoder()
expect((try? dec.decode(CheckResult.self, from: try! enc.encode(ok))) == ok, "CheckResult round trip")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
