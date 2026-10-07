//
// Standalone tests for EmoDrinkPersona. Run from the repo root:
//   xcrun swiftc \
//     HermesGlasses/Services/EmoDrink/EmoDrinkLanguage.swift \
//     HermesGlasses/Services/EmoDrink/PhysiologySnapshot.swift \
//     HermesGlasses/Services/EmoDrink/DrinkCatalog.swift \
//     HermesGlasses/Services/EmoDrink/DrinkRecommender.swift \
//     HermesGlasses/Services/EmoDrink/EmoDrinkPersona.swift \
//     tests/emodrink-persona/main.swift -o /tmp/ed-persona && /tmp/ed-persona
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

let catalog = try! DrinkCatalog.decode(FileManager.default.contents(atPath: DrinkCatalog.repoPath)!)
let stressed = PhysiologySnapshot(date: "2026-10-07", source: "sample: stressed", sleep: SleepSummary(hours: 6.4, score: 63),
                                  hrvMs: 36, hrvBaselineMs: 52, restingHR: 61, restingHRBaseline: 54, steps: 4000, stress: 71)
let rec = DrinkRecommender.recommend(snapshot: stressed, catalog: catalog, hour: 9, lowSugar: false)!
let prompt = EmoDrinkPersona.systemPrompt(snapshot: stressed, pick: rec.pick, recommendation: rec, catalog: catalog, sourceLabel: "sample: stressed")

expect(prompt.contains("6.4"), "prompt carries sleep hours")
expect(prompt.contains("63"), "prompt carries sleep score")
expect(prompt.contains("36 ms") && prompt.contains("52 ms"), "prompt carries HRV and baseline")
expect(prompt.contains("Asahi Rokujo Mugicha"), "prompt names the pick")
expect(rec.alternates.allSatisfy { prompt.contains($0.name) }, "prompt names the alternates")
expect(catalog.drinks.allSatisfy { prompt.contains($0.name) }, "prompt lists every catalogue drink")
expect(prompt.contains("1 to 3 spoken sentences"), "guardrail: short spoken answers")
expect(prompt.contains("suggests") && prompt.contains("never a diagnosis"), "guardrail: suggestive, not diagnostic")
expect(prompt.contains("soft drinks"), "guardrail: alcohol answer")
expect(prompt.contains("sample: stressed"), "prompt says where the data came from")
for word in EmoDrinkPersona.emotionDenylist {
    expect(!prompt.lowercased().contains(word), "prompt avoids emotion word '\(word)'")
}

let minimal = PhysiologySnapshot(date: "2026-10-07", source: "manual", sleep: SleepSummary(hours: 7.5),
                                 hrvMs: nil, hrvBaselineMs: nil, restingHR: nil, restingHRBaseline: nil, steps: nil, stress: nil)
let summary = EmoDrinkPersona.summary(of: minimal)
expect(summary.contains("7.5 h") && !summary.lowercased().contains("hrv") && !summary.lowercased().contains("heart"),
       "summary without baselines mentions only sleep: \(summary)")

expect(EmoDrinkPersona.fallbackLine(pick: rec.pick, recommendation: rec) == "Try an Asahi Rokujo Mugicha. Slept 6.4 h, sleep score 63.",
       "fallback line is pick plus first two reasons: \(EmoDrinkPersona.fallbackLine(pick: rec.pick, recommendation: rec))")
expect(EmoDrinkPersona.alternateLine(pick: catalog.drink(id: "wilkinson-tansan")!) == "How about a Wilkinson Tansan?", "alternate line")
expect(EmoDrinkPersona.alternateLine(pick: catalog.drink(id: "oishii-mizu")!) == "How about an Asahi Oishii Mizu Tennensui?", "alternate line uses 'an' before a vowel")
expect(EmoDrinkPersona.whyQuestion == "Why do you suggest this drink for me right now?", "why question is fixed text")
expect(EmoDrinkPersona.whyFallback(recommendation: rec).hasPrefix("Because you slept 6.4 h"), "why fallback reads the reasons: \(EmoDrinkPersona.whyFallback(recommendation: rec))")
expect(EmoDrinkPersona.whyFallback(recommendation: rec) == "Because you slept 6.4 h, with sleep score 63 and HRV 16 ms under your usual.", "why fallback is one grammatical sentence: \(EmoDrinkPersona.whyFallback(recommendation: rec))")
let lateRec = DrinkRecommender.recommend(snapshot: stressed, catalog: catalog, hour: 19, lowSugar: false)!
expect(EmoDrinkPersona.whyFallback(recommendation: lateRec).hasPrefix("Because you slept 6.4 h, with sleep score 63"), "late why fallback keeps the list form: \(EmoDrinkPersona.whyFallback(recommendation: lateRec))")
expect(EmoDrinkPersona.firstLineRequest.contains("one sentence"), "first line request asks for one sentence")

// Language (spec section 6): the prompt ENDS with the language rule.
let promptJa = EmoDrinkPersona.systemPrompt(snapshot: stressed, pick: rec.pick, recommendation: rec, catalog: catalog,
                                            sourceLabel: "sample: stressed", language: .ja)
expect(promptJa.hasSuffix("Reply only in Japanese, in plain spoken form (です・ます), one or two short sentences, warm, like a friend at the machine. No lists, no bullet points."), "ja prompt ends with the Japanese rule")
expect(prompt.hasSuffix("Sound like a friend standing at the machine, one or two short sentences, no lists."), "en prompt ends with the English rule")
expect(promptJa.contains("Asahi Rokujo Mugicha (アサヒ 六条麦茶)"), "drink names in both scripts")
expect(promptJa.contains("slept 6.4 h"), "the snapshot summary stays English inside the prompt")
for word in EmoDrinkPersona.emotionDenylist {
    expect(!promptJa.lowercased().contains(word), "ja prompt avoids emotion word '\(word)'")
}
expect(EmoDrinkPersona.chosenRequest(pick: rec.pick, language: .ja) == "The wearer chose Asahi Rokujo Mugicha (アサヒ 六条麦茶). Say one warm sentence about why it fits, in Japanese.", "chosen request, ja")
expect(EmoDrinkPersona.chosenRequest(pick: rec.pick, language: .en).hasSuffix("in English."), "chosen request, en")
let three = Array(rec.ranked.prefix(3))
let choicesRequest = EmoDrinkPersona.choicesRequest(options: three)
expect(three.allSatisfy { choicesRequest.contains($0.name) && choicesRequest.contains($0.nameJa) }, "choices request names all three in both scripts")
expect(choicesRequest.range(of: three[0].name)!.lowerBound < choicesRequest.range(of: three[2].name)!.lowerBound, "choices request keeps the rank order")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
