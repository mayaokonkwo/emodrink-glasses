//
// Standalone tests for EmoDrinkLanguage and EmoDrinkStrings. Run from the repo root:
//   xcrun swiftc \
//     HermesGlasses/Services/EmoDrink/EmoDrinkLanguage.swift \
//     tests/emodrink-language/main.swift -o /tmp/ed-language && /tmp/ed-language
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

// Resolution: the FIRST preferred language decides; region does not matter.
expect(EmoDrinkLanguage.resolve(.auto, preferredLanguages: ["ja-JP", "en-US"]) == .ja, "auto, Japanese first -> ja")
expect(EmoDrinkLanguage.resolve(.auto, preferredLanguages: ["ja"]) == .ja, "auto, bare ja -> ja")
expect(EmoDrinkLanguage.resolve(.auto, preferredLanguages: ["en-JP", "ja-JP"]) == .en, "auto, English (Japan region) first -> en")
expect(EmoDrinkLanguage.resolve(.auto, preferredLanguages: ["en-US", "ja-JP"]) == .en, "auto, Japanese second -> en")
expect(EmoDrinkLanguage.resolve(.auto, preferredLanguages: []) == .en, "auto, nothing -> en")
expect(EmoDrinkLanguage.resolve(.auto, preferredLanguages: ["JA-jp"]) == .ja, "case-insensitive")
expect(EmoDrinkLanguage.resolve(.en, preferredLanguages: ["ja-JP"]) == .en, "manual English wins over the iPhone")
expect(EmoDrinkLanguage.resolve(.ja, preferredLanguages: ["en-US"]) == .ja, "manual Japanese wins over the iPhone")
expect(Language.ja.sttLocale == "ja-JP" && Language.en.sttLocale == "en-US", "STT locales")
expect(Language.ja.ttsLanguage == "ja-JP" && Language.en.ttsLanguage == "en-US", "TTS languages")
expect(Language.ja.other == .en && Language.en.other == .ja, "other")
expect(EmoDrinkLanguage.Setting(rawValue: "auto") == .auto && EmoDrinkLanguage.settingKey == "emodrink_language", "setting key and raw values")

// Setting persistence round trip on a private suite.
let suite = UserDefaults(suiteName: "emodrink-language-test")!
suite.removePersistentDomain(forName: "emodrink-language-test")
expect(EmoDrinkLanguage.setting(in: suite) == .auto, "default setting is auto")
EmoDrinkLanguage.setSetting(.ja, in: suite)
expect(EmoDrinkLanguage.setting(in: suite) == .ja, "setting persists")
suite.set("klingon", forKey: EmoDrinkLanguage.settingKey)
expect(EmoDrinkLanguage.setting(in: suite) == .auto, "garbage reads as auto")

// String tables are complete for both languages.
let hasJapanese: (String) -> Bool = { $0.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) } }
for lang in Language.allCases {
    let t = EmoDrinkStrings(language: lang)
    let all = [t.watchingHeading, t.watchingText, t.watchingHint, t.idleTitle, t.idleHint, t.choiceHeading, t.choiceHint,
               t.cameraLost, t.cameraStopped, t.cameraDidNotOpen, t.noMachine, t.micBlocked, t.enjoy,
               t.whyLabel, t.thanksLabel, t.backLabel, t.voiceInstallHint, t.afterCutoff,
               t.choicesLine(names: ["A", "B", "C"]), t.chosenLine(name: "A", reasons: ["x"]), t.whyLine(reasons: ["x"]),
               t.slept(hours: 5.1), t.sleepScore(48), t.hrvUnder(ms: 14), t.hrvAbove(ms: 6), t.restingHROver(7),
               t.stress(71), t.stepsAlready(8400)]
    expect(all.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, "\(lang): every string is non-empty")
    expect(all.allSatisfy { !$0.contains("\u{2014}") }, "\(lang): no em dashes")
    let fixed = [t.watchingText, t.choiceHeading, t.noMachine, t.cameraLost, t.enjoy, t.whyLabel, t.thanksLabel, t.backLabel]
    if lang == .ja {
        expect(fixed.allSatisfy(hasJapanese), "ja: lens and spoken lines are Japanese")
    } else {
        expect(!fixed.contains(where: hasJapanese), "en: lens and spoken lines are English")
    }
}

// Japanese reason fragments, exactly as the spec writes them.
let ja = EmoDrinkStrings(language: .ja)
expect(ja.slept(hours: 5.1) == "睡眠5.1時間", "ja sleep hours")
expect(ja.sleepScore(48) == "睡眠スコア48", "ja sleep score")
expect(ja.hrvUnder(ms: 14) == "HRVがいつもより14ms低い", "ja HRV under")
expect(ja.hrvAbove(ms: 6) == "HRVがいつもより6ms高い", "ja HRV above")
expect(ja.restingHROver(7) == "安静時心拍がいつもより7高い", "ja resting HR")
expect(ja.stress(71) == "ストレス71", "ja stress")
expect(ja.afterCutoff == "もう15時過ぎ", "ja after cutoff")
expect(ja.stepsAlready(8400) == "すでに8,400歩", "ja steps with a thousands comma")

// English fragments match the pre-existing recommender wording.
let en = EmoDrinkStrings(language: .en)
expect(en.slept(hours: 5.1) == "slept 5.1 h" && en.sleepScore(48) == "sleep score 48", "en sleep")
expect(en.hrvUnder(ms: 9) == "HRV 9 ms under your usual" && en.hrvAbove(ms: 6) == "HRV 6 ms above your usual", "en HRV")
expect(en.restingHROver(7) == "resting heart rate 7 over your usual" && en.stress(71) == "stress 71", "en HR and stress")
expect(en.stepsAlready(8400) == "8,400 steps already" && en.afterCutoff == "it is after 3 pm", "en steps and cutoff")

// Spoken lines.
expect(en.choicesLine(names: ["Rokujo Mugicha", "Calpis Water", "Wilkinson"]) == "How about Rokujo Mugicha, Calpis Water, or Wilkinson?", "en choices line")
expect(en.choicesLine(names: ["A", "B"]) == "How about A or B?", "en choices line with two")
expect(en.choicesLine(names: ["A"]) == "How about A?", "en choices line with one")
expect(ja.choicesLine(names: ["六条麦茶", "カルピスウォーター", "ウィルキンソン"]) == "六条麦茶、カルピスウォーター、ウィルキンソンはどうですか", "ja choices line")
expect(en.chosenLine(name: "Calpis Water", reasons: ["slept 5.1 h", "sleep score 48"]) == "Good choice, Calpis Water. Slept 5.1 h, sleep score 48.", "en chosen line")
expect(en.chosenLine(name: "Calpis Water", reasons: []) == "Good choice, Calpis Water.", "en chosen line without reasons")
expect(ja.chosenLine(name: "カルピスウォーター", reasons: ["睡眠5.1時間", "睡眠スコア48"]) == "カルピスウォーター、いい選択です。睡眠5.1時間、睡眠スコア48なので、ちょうどいいと思います。", "ja chosen line")
expect(ja.chosenLine(name: "カルピスウォーター", reasons: []) == "カルピスウォーター、いい選択です。", "ja chosen line without reasons")
expect(en.whyLine(reasons: ["slept 6.4 h", "sleep score 63", "HRV 16 ms under your usual"]) == "Because you slept 6.4 h, with sleep score 63 and HRV 16 ms under your usual.", "en why line keeps the persona wording")
expect(en.whyLine(reasons: []) == "Because it fits how you slept.", "en why line without reasons")
expect(ja.whyLine(reasons: ["睡眠6.4時間", "睡眠スコア63", "HRVがいつもより16ms低い", "ストレス71"]) == "睡眠6.4時間、睡眠スコア63、HRVがいつもより16ms低いので、これを選びました。", "ja why line uses at most three reasons")
expect(ja.whyLine(reasons: []) == "昨夜の睡眠に合わせて選びました。", "ja why line without reasons")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
