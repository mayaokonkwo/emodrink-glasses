//
// EmoDrinkCommands.swift
//
// What the wearer can say or tap while a drink is on the lens. Whole-
// utterance matched through IntentDetector.normalizeCommand, like every
// other short command, so "why" inside a real question is left for the
// persona to answer. Foundation only; tested in tests/emodrink-commands.
//

import Foundation

enum EmoDrinkCommands {
    enum Spoken: Equatable { case why, somethingElse, thanks }

    static let whyPhrases: Set<String> = ["why", "why this", "why this one", "why that", "why that one", "tell me why"]
    static let somethingElsePhrases: Set<String> = [
        "something else", "another", "another one", "next", "next one", "other options", "what else",
        "something different", "not that one",
    ]
    static let thanksPhrases: Set<String> = ["thanks", "thank you", "cheers", "got it", "perfect", "okay thanks", "ok thanks"]

    /// Lens buttons. The reply of each is a phrase above, so a tap and the
    /// spoken word take the same path.
    static let choices: [ReplyChoice] = [
        ReplyChoice(key: "1", label: "Why"),
        ReplyChoice(key: "2", label: "Something else"),
        ReplyChoice(key: "3", label: "Thanks"),
    ]

    static func spoken(_ text: String) -> Spoken? {
        let c = IntentDetector.normalizeCommand(text)
        guard !c.isEmpty else { return nil }
        if whyPhrases.contains(c) { return .why }
        if somethingElsePhrases.contains(c) { return .somethingElse }
        if thanksPhrases.contains(c) { return .thanks }
        return nil
    }
}
