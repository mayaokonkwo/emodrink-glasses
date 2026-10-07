//
// Standalone tests for LensContent. Run from the repo root:
//   xcrun swiftc \
//     HermesGlasses/Services/ChoiceDetector.swift \
//     HermesGlasses/Services/LensContent.swift \
//     tests/lens-content/main.swift -o /tmp/lens-content-tests \
//     && /tmp/lens-content-tests
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)") }
}
func expectEqual(_ got: String?, _ want: String?, _ label: String) {
    expect(got == want, "\(label) (got \(got ?? "nil"), want \(want ?? "nil"))")
}

// MARK: - blank, listening, thinking

expect(LensContent.blank.isBlank, "blank is blank")
expectEqual(LensContent.blank.body, "", "blank body is empty")
expectEqual(LensContent.blank.label, nil, "blank has no label")
expectEqual(LensContent.blank.statusLine, nil, "blank has no status line")
expect(!LensContent.blank.isLive, "blank is not live")
let listening = LensContent.listening(partial: "what should I drink")
expectEqual(listening.label, "LISTENING", "listening label")
expectEqual(listening.body, "what should I drink", "listening body is the partial")
expectEqual(listening.statusLine, "listening", "listening status line")
expect(listening.isLive, "listening is live")
let thinking = LensContent.thinking(query: "is there caffeine in it")
expectEqual(thinking.label, nil, "thinking has no label")
expectEqual(thinking.body, "is there caffeine in it", "thinking body is the query")
expectEqual(thinking.statusLine, "thinking…", "thinking status line")

// MARK: - reply

let speaking = LensContent.reply(text: "It has no caffeine.", speaking: true)
let spoken = LensContent.reply(text: "It has no caffeine.", speaking: false)
expectEqual(speaking.statusLine, "speaking", "reply shows speaking while TTS plays")
expectEqual(spoken.statusLine, nil, "reply drops the status line after speech")
expect(speaking != spoken, "speaking flag participates in equality")
let withChoices = LensContent.reply(text: "A) Hot, B) Cold", speaking: false,
                                    choices: ChoiceDetector.choices(in: "A) Hot, B) Cold"))
expectEqual(withChoices.statusLine, "2 options - tap one", "a reply with options advertises them")

// MARK: - flashes

expectEqual(LensContent.photoCaptured.body, "Photo captured", "photo flash body")
expectEqual(LensContent.newConversation.body, "New conversation", "new chat flash body")
expect(!LensContent.photoCaptured.isLive && !LensContent.newConversation.isLive, "flashes are not live")

// MARK: - EmoDrink chosen drink (step B)

let buttons = [ReplyChoice(key: "w", label: "Why"), ReplyChoice(key: "t", label: "Thanks")]
let card = LensContent.emoDrink(title: "Asahi Rokujo Mugicha", subtitle: "アサヒ 六条麦茶", reason: "slept 6.4 h, HRV 16 ms under your usual", source: "sample: stressed", choices: buttons)
expectEqual(card.label, nil, "the chosen drink has no English label; its name is the heading")
expect(card.body == "Asahi Rokujo Mugicha", "emoDrink body is the drink name")
expect(card.statusLine == "slept 6.4 h, HRV 16 ms under your usual · sample: stressed", "emoDrink status is reason and source")
expect(card.choices == buttons, "emoDrink exposes its buttons")
expect(card.isLive, "emoDrink keeps the live dot")
expect(LensContent.blank.choices.isEmpty, "blank has no choices")

// MARK: - EmoDrink three drinks (step A)

let options = [
    LensDrinkOption(title: "アサヒ 六条麦茶", subtitle: "Asahi Rokujo Mugicha", reason: "睡眠5.1時間, 睡眠スコア48"),
    LensDrinkOption(title: "カルピスウォーター", subtitle: "Calpis Water", reason: "睡眠5.1時間"),
    LensDrinkOption(title: "ウィルキンソン タンサン", subtitle: "Wilkinson Tansan", reason: "睡眠5.1時間"),
]
let pickOne = LensContent.emoDrinkChoices(heading: "どれにする？", options: options, source: "sample: short night")
expectEqual(pickOne.body, "どれにする？", "choices body is the heading")
expectEqual(pickOne.label, nil, "choices have no English label")
expect(pickOne.choices.map(\.label) == ["1 アサヒ 六条麦茶", "2 カルピスウォーター", "3 ウィルキンソン タンサン"], "numbered buttons with the active-language name")
expect(pickOne.choices.map(\.key) == ["1", "2", "3"], "button keys are the numbers")
expect(pickOne.choices.map(\.reply) == pickOne.choices.map(\.label), "a tap submits the label, which the parser reads")
expectEqual(pickOne.statusLine, "睡眠5.1時間, 睡眠スコア48 · sample: short night", "status is the first option's reason and the source")
expect(pickOne.isLive && !pickOne.isBlank, "choices are live")
expectEqual(LensContent.emoDrinkChoices(heading: "Pick one", options: [], source: "feed").statusLine, "feed", "no options: status is the source")
expect(pickOne != LensContent.emoDrinkChoices(heading: "どれにする？", options: Array(options.prefix(2)), source: "sample: short night"), "options participate in equality, so the buttons redraw")

// MARK: - EmoDrink watching, per language

let watchingJa = LensContent.emoDrinkWatching(heading: "ドリンクモード", text: "自販機を探しています", hint: "「何を飲めばいい」といつでもどうぞ")
expectEqual(watchingJa.label, "ドリンクモード", "watching label is the heading")
expectEqual(watchingJa.body, "自販機を探しています", "watching body")
expectEqual(watchingJa.statusLine, "「何を飲めばいい」といつでもどうぞ", "watching hint")
let watchingEn = LensContent.emoDrinkWatching(heading: "Drink mode", text: "Watching for a vending machine", hint: "Say \"what should I drink\" any time")
expectEqual(watchingEn.label, "DRINK MODE", "English heading is upper-cased")
expect(watchingEn.isLive && !watchingEn.isBlank, "watching is live")

// MARK: - every case answers every question

let all: [LensContent] = [
    .blank, .listening(partial: "a"), .thinking(query: "b"), .photoCaptured,
    .reply(text: "c", speaking: true), .newConversation, card, pickOne, watchingEn,
]
for content in all {
    _ = content.label; _ = content.body; _ = content.statusLine; _ = content.isLive; _ = content.isBlank; _ = content.choices
}
expect(all.count == 9, "all 9 cases covered")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
