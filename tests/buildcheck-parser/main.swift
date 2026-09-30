//
// Standalone tests for ProcedureParser. Build + run:
//   xcrun swiftc \
//     HermesGlasses/Services/BuildCheck/BuildCheckJSON.swift \
//     HermesGlasses/Services/BuildCheck/Procedure.swift \
//     HermesGlasses/Services/BuildCheck/ProcedureParser.swift \
//     tests/buildcheck-parser/main.swift -o /tmp/bc-parser && /tmp/bc-parser
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

// validate
do { _ = try ProcedureParser.validate("   \n "); expect(false, "blank throws") }
catch { expect(error as? ProcedureParser.ParseError == .empty, "blank throws .empty") }
let huge = String(repeating: "a", count: ProcedureParser.maxCharacters + 1)
do { _ = try ProcedureParser.validate(huge); expect(false, "too long throws") }
catch { expect(error as? ProcedureParser.ParseError == .tooLong(characters: 60_001), "too long throws with count") }
expect((try? ProcedureParser.validate("  hi \n")) == "hi", "validate trims")

// numbered lists
let styles = """
Bracket B install
1. Fit bracket B to the rail
2) Insert four M6 bolts
Step 3: Torque bolts to 9 Nm
4 - Fit the cover
"""
expect(ProcedureParser.numberedSteps(in: styles) == [
    "Fit bracket B to the rail", "Insert four M6 bolts", "Torque bolts to 9 Nm", "Fit the cover",
], "mixed numbering styles, preamble ignored")

let continuation = """
1. Fit the bracket
   using the 2.5 mm hex key
2. Check alignment
"""
expect(ProcedureParser.numberedSteps(in: continuation) == [
    "Fit the bracket using the 2.5 mm hex key", "Check alignment",
], "2.5 mm is a continuation line, not step 2")

expect(ProcedureParser.numberedSteps(in: "1. a\n2. b\n1. c\n2. d") == nil, "restarted numbering → nil (AI split)")
expect(ProcedureParser.numberedSteps(in: "1. a\n3. b") == nil, "skipped number → nil")
expect(ProcedureParser.numberedSteps(in: "1. only one") == nil, "single step → nil")
expect(ProcedureParser.numberedSteps(in: "Fit the bracket then torque it") == nil, "prose → nil")
expect(ProcedureParser.numberedSteps(in: "STEP 1. a\nstep 2. b") == ["a", "b"], "case-insensitive Step")

// critical suggestions
expect(ProcedureParser.suggestsCritical("Torque bolts to 9 Nm"), "torque")
expect(ProcedureParser.suggestsCritical("Tighten to 25 in-lb"), "in-lb value")
expect(ProcedureParser.suggestsCritical("Install safety wire on bolts"), "safety wire")
expect(ProcedureParser.suggestsCritical("Verify connector P3 is seated"), "verify / connector")
expect(ProcedureParser.suggestsCritical("CAUTION: fluid under pressure"), "caution")
expect(!ProcedureParser.suggestsCritical("Fit the cover"), "plain step not critical")
expect(!ProcedureParser.suggestsCritical("Wipe with a 2 m cloth"), "2 m is not a torque unit")

let fromList = ProcedureParser.steps(fromNumbered: ["Fit the cover", "Torque to 9 Nm"])
expect(fromList.map(\.critical) == [false, true], "steps(fromNumbered:) suggests critical")

// AI split format
let reply = """
```json
{"title": "Bracket B", "steps": [
  {"text": "Fit bracket B", "critical": false, "expected_look": "bracket flush on rail"},
  {"text": "Torque to 9 Nm", "critical": true, "expected_look": "4 bolt heads, torque stripes"},
  {"text": "   ", "critical": true},
  {"text": "Fit cover"}
]}
```
"""
let split = try! ProcedureParser.split(fromAIReply: reply)
expect(split.title == "Bracket B", "title")
expect(split.steps.map(\.text) == ["Fit bracket B", "Torque to 9 Nm", "Fit cover"], "blank step dropped")
expect(split.steps[1].critical && split.steps[1].expectedLook == "4 bolt heads, torque stripes", "fields mapped")
expect(!split.steps[2].critical && split.steps[2].expectedLook == "", "missing fields default (keyword check)")
do { _ = try ProcedureParser.split(fromAIReply: "I can't read that"); expect(false, "prose throws") }
catch { expect(error as? ProcedureParser.ParseError == .unreadableAIReply, "prose → unreadableAIReply") }
do { _ = try ProcedureParser.split(fromAIReply: #"{"steps": []}"#); expect(false, "empty throws") }
catch { expect(error as? ProcedureParser.ParseError == .unreadableAIReply, "no steps → unreadableAIReply") }
expect(ProcedureParser.splitUserPrompt(document: "X").hasSuffix("X"), "user prompt carries the document")
expect(ProcedureParser.splitSystemPrompt.contains("expected_look"), "system prompt names the schema")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
