//
// Standalone tests for DrinkChoiceParser. Run from the repo root:
//   xcrun swiftc \
//     HermesGlasses/Services/EmoDrink/EmoDrinkLanguage.swift \
//     HermesGlasses/Services/EmoDrink/DrinkChoiceParser.swift \
//     tests/emodrink-choice/main.swift -o /tmp/ed-choice && /tmp/ed-choice
//
import Foundation

var failures = 0
func expect(_ got: Int?, _ want: Int?, _ label: String) {
    if got == want { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label): got \(got.map(String.init) ?? "nil"), want \(want.map(String.init) ?? "nil")") }
}

let three = [
    ChoiceOption(name: "Asahi Rokujo Mugicha", nameJa: "アサヒ 六条麦茶"),
    ChoiceOption(name: "Calpis Water", nameJa: "カルピスウォーター"),
    ChoiceOption(name: "Wilkinson Tansan", nameJa: "ウィルキンソン タンサン"),
]
func pick(_ text: String, _ options: [ChoiceOption] = three, _ language: Language = .en) -> Int? {
    DrinkChoiceParser.index(for: text, options: options, language: language)
}

// English numbers and ordinals.
expect(pick("one"), 0, "one")
expect(pick("Two."), 1, "Two. with punctuation")
expect(pick("three"), 2, "three")
expect(pick("first"), 0, "first")
expect(pick("the second one"), 1, "the second one")
expect(pick("number three"), 2, "number three")
expect(pick("Third, please"), 2, "third please")
expect(pick("2"), 1, "bare digit")
expect(pick("2nd"), 1, "2nd")
expect(pick("four"), nil, "out of range ordinal")
expect(pick("4"), nil, "out of range digit")
expect(pick("two", Array(three.prefix(2))), 1, "two of two")
expect(pick("three", Array(three.prefix(2))), nil, "three of two is out of range")

// The lens button submits its own label.
expect(pick("1 Asahi Rokujo Mugicha"), 0, "tap label, English")
expect(pick("3 ウィルキンソン タンサン", three, .ja), 2, "tap label, Japanese")

// Japanese ordinals, with and without particles.
expect(pick("一番目", three, .ja), 0, "一番目")
expect(pick("二番目", three, .ja), 1, "二番目")
expect(pick("三番目", three, .ja), 2, "三番目")
expect(pick("二", three, .ja), 1, "二")
expect(pick("最初の", three, .ja), 0, "最初の")
expect(pick("二つ目", three, .ja), 1, "二つ目")
expect(pick("二番目にする", three, .ja), 1, "二番目にする")
expect(pick("二番目で。", three, .ja), 1, "二番目で。")
expect(pick("2番目", three, .ja), 1, "2番目 with an ASCII digit")
expect(pick("２番目", three, .ja), 1, "full-width digit")
expect(pick("最後", three, .ja), 2, "最後")
expect(pick("じゃあ三つ目をください", three, .ja), 2, "lead and tail particles")
expect(pick("second", three, .ja), 1, "English ordinal while Japanese is active")
expect(pick("二番目", three, .en), 1, "Japanese ordinal while English is active")

// Names: a distinctive token in either script.
expect(pick("Calpis"), 1, "calpis")
expect(pick("mugicha"), 0, "mugicha")
expect(pick("Wilkinson please"), 2, "wilkinson please")
expect(pick("the rokujo one"), 0, "the rokujo one")
expect(pick("カルピス", three, .ja), 1, "カルピス (part of one Japanese name)")
expect(pick("六条麦茶", three, .ja), 0, "六条麦茶")
expect(pick("ウィルキンソンで", three, .ja), 2, "ウィルキンソンで")

// Ambiguity: a token shared by two options never decides.
let waters = [
    ChoiceOption(name: "Calpis Water", nameJa: "カルピスウォーター"),
    ChoiceOption(name: "Alkaline Water", nameJa: "アルカリイオンの水"),
    ChoiceOption(name: "Dodekamin", nameJa: "ドデカミン"),
]
expect(pick("water", waters), nil, "ambiguous token: water is in two names")
expect(pick("calpis", waters), 0, "distinctive token: calpis")
expect(pick("alkaline water", waters), 1, "a distinctive word beside a shared one")
let asahis = [
    ChoiceOption(name: "Asahi Rokujo Mugicha", nameJa: "アサヒ 六条麦茶"),
    ChoiceOption(name: "Asahi Super H2O", nameJa: "アサヒ スーパーH2O"),
    ChoiceOption(name: "Asahi Juroku-cha", nameJa: "アサヒ 十六茶"),
]
expect(pick("asahi", asahis), nil, "asahi is in every name")
expect(pick("アサヒ", asahis, .ja), nil, "アサヒ is in every name")
expect(pick("super", asahis), 1, "super")
expect(pick("h2o", asahis), 1, "h2o keeps its digit")
expect(pick("juroku", asahis), 2, "juroku from a hyphenated name")
let calpises = [
    ChoiceOption(name: "Calpis Water", nameJa: "カルピスウォーター"),
    ChoiceOption(name: "Calpis Soda", nameJa: "カルピスソーダ"),
    ChoiceOption(name: "Wonda Kin no Bito Black", nameJa: "ワンダ 金の微糖 ブラック"),
]
expect(pick("calpis", calpises), nil, "calpis is in two names")
expect(pick("カルピス", calpises, .ja), nil, "カルピス is inside two Japanese names")
expect(pick("soda", calpises), 1, "soda")
expect(pick("no", calpises), nil, "short words never match")
expect(pick("black", calpises), 2, "black")

// Not a choice.
expect(pick(""), nil, "empty")
expect(pick("hello"), nil, "unrelated word")
expect(pick("what should I drink"), nil, "a command is not a choice")
expect(pick("is calpis water sweet or more like a soda"), nil, "a question that names a drink is not a choice")
expect(pick("カルピスウォーターは甘いですか、それともさっぱりしていますか", three, .ja), nil, "a long Japanese question is not a choice")
expect(pick("two", [], .en), nil, "no options")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
