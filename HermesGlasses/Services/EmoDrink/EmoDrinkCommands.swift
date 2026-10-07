//
// EmoDrinkCommands.swift
//
// What the wearer can say or tap while drinks are on the lens, in English
// and Japanese. Whole-utterance matched through
// IntentDetector.normalizeCommand, so "why" inside a real question
// (「なぜか分からない」) is left for the persona to answer. Choosing one of
// the three drinks is DrinkChoiceParser's job, not this file's.
// Foundation only; tested in tests/emodrink-commands.
//

import Foundation

enum EmoDrinkCommands {
    enum Spoken: Equatable { case why, somethingElse, thanks, back, stop }

    static let whyPhrases: Set<String> = [
        "why", "why this", "why this one", "why that", "why that one", "tell me why",
        "なぜ", "どうして", "理由は", "なんで", "なぜこれ",
    ]
    static let somethingElsePhrases: Set<String> = [
        "something else", "another", "another one", "next", "next one", "other options", "what else",
        "something different", "not that one",
        "他には", "ほかには", "別のもの", "次", "他の",
    ]
    static let thanksPhrases: Set<String> = [
        "thanks", "thank you", "cheers", "got it", "perfect", "okay thanks", "ok thanks",
        "ありがとう", "ありがとうございます", "どうも", "オッケー", "おっけー",
    ]
    static let backPhrases: Set<String> = [
        "back", "go back", "show all three", "show me all three", "the three",
        "戻る", "戻って", "もどる",
    ]
    static let stopPhrases: Set<String> = ["stop", "停止", "止めて", "やめて"]

    /// Buttons on the chosen drink's card. Each reply is a phrase above, so
    /// a tap and the spoken word take the same path.
    static func cardChoices(for language: Language) -> [ReplyChoice] {
        let t = EmoDrinkStrings(language: language)
        return [ReplyChoice(key: "w", label: t.whyLabel), ReplyChoice(key: "t", label: t.thanksLabel)]
    }

    static func spoken(_ text: String) -> Spoken? {
        let c = IntentDetector.normalizeCommand(text)
        guard !c.isEmpty else { return nil }
        if whyPhrases.contains(c) { return .why }
        if somethingElsePhrases.contains(c) { return .somethingElse }
        if thanksPhrases.contains(c) { return .thanks }
        if backPhrases.contains(c) { return .back }
        if stopPhrases.contains(c) { return .stop }
        return nil
    }
}
