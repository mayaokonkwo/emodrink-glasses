//
// Standalone tests for EmoDrinkCommands. Run from the repo root:
//   xcrun swiftc \
//     HermesGlasses/Services/EmoDrink/Intents.swift \
//     HermesGlasses/Services/EmoDrink/IntentDetector.swift \
//     HermesGlasses/Services/ChoiceDetector.swift \
//     HermesGlasses/Services/EmoDrink/EmoDrinkLanguage.swift \
//     HermesGlasses/Services/EmoDrink/EmoDrinkCommands.swift \
//     tests/emodrink-commands/main.swift -o /tmp/ed-commands && /tmp/ed-commands
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

// English.
expect(EmoDrinkCommands.spoken("why") == .why, "why")
expect(EmoDrinkCommands.spoken("Why?") == .why, "Why? with punctuation")
expect(EmoDrinkCommands.spoken("why this one") == .why, "why this one")
expect(EmoDrinkCommands.spoken("something else") == .somethingElse, "something else")
expect(EmoDrinkCommands.spoken("next") == .somethingElse, "next")
expect(EmoDrinkCommands.spoken("thanks") == .thanks, "thanks")
expect(EmoDrinkCommands.spoken("Thank you!") == .thanks, "thank you")
expect(EmoDrinkCommands.spoken("back") == .back, "back")
expect(EmoDrinkCommands.spoken("Go back.") == .back, "go back")
expect(EmoDrinkCommands.spoken("Stop.") == .stop, "stop")
expect(EmoDrinkCommands.spoken("is there caffeine in it") == nil, "a question is not a command")
expect(EmoDrinkCommands.spoken("Why do you suggest this drink for me right now?") == nil, "the generated why question is NOT re-claimed")
expect(EmoDrinkCommands.spoken("") == nil, "empty")

// Japanese, with punctuation, whole utterance only.
expect(EmoDrinkCommands.spoken("なぜ？") == .why, "なぜ？")
expect(EmoDrinkCommands.spoken("どうして") == .why, "どうして")
expect(EmoDrinkCommands.spoken("理由は？") == .why, "理由は？")
expect(EmoDrinkCommands.spoken("他には？") == .somethingElse, "他には？")
expect(EmoDrinkCommands.spoken("別のもの") == .somethingElse, "別のもの")
expect(EmoDrinkCommands.spoken("次") == .somethingElse, "次")
expect(EmoDrinkCommands.spoken("ありがとう。") == .thanks, "ありがとう。")
expect(EmoDrinkCommands.spoken("どうも") == .thanks, "どうも")
expect(EmoDrinkCommands.spoken("オッケー") == .thanks, "オッケー")
expect(EmoDrinkCommands.spoken("戻る") == .back, "戻る")
expect(EmoDrinkCommands.spoken("停止") == .stop, "停止")
for phrase in ["ありがとうございました", "ありがとうございます", "ありがとうね", "サンキュー"] {
    expect(EmoDrinkCommands.spoken(phrase) == .thanks, "\(phrase) is thanks")
    expect(EmoDrinkCommands.spoken(phrase + "。") == .thanks, "\(phrase)。 is thanks")
}
for phrase in ["なんで", "何で"] {
    expect(EmoDrinkCommands.spoken(phrase) == .why, "\(phrase) is why")
    expect(EmoDrinkCommands.spoken(phrase + "？") == .why, "\(phrase)？ is why")
}
expect(EmoDrinkCommands.spoken("なぜか分からない") == nil, "なぜ inside a sentence is not a command")
expect(EmoDrinkCommands.spoken("ありがとう、でもカフェインは入ってる？") == nil, "thanks inside a question is not a command")

// The card's buttons: tapping one submits its label, which the claimer reads back.
for language in Language.allCases {
    let choices = EmoDrinkCommands.cardChoices(for: language)
    expect(choices.count == 2, "\(language): two buttons on the chosen drink")
    expect(choices.map { EmoDrinkCommands.spoken($0.reply) } == [.why, .thanks], "\(language): Why and Thanks buttons are claimed as why and thanks")
    expect(Set(choices.map(\.id)).count == 2, "\(language): choice ids are distinct")
}
expect(EmoDrinkCommands.cardChoices(for: .ja).map(\.label) == ["なぜ？", "ありがとう"], "Japanese button labels")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
