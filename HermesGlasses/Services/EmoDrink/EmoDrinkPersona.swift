//
// EmoDrinkPersona.swift
//
// The system prompt for the drink moment, and the fixed spoken lines used
// when the AI is unavailable. Everything the model may say about the body
// is in the prompt as numbers; it is told to suggest, never to diagnose or
// name a feeling. Foundation only; tested in tests/emodrink-persona.
//

import Foundation

enum EmoDrinkPersona {
    /// Words the prompt itself must never contain (the test checks). The
    /// model is told the rule in plain terms instead.
    static let emotionDenylist = ["anxious", "anxiety", "depress", "angry", "sad", "happy", "nervous", "panic"]

    static let whyQuestion = "Why do you suggest this drink for me right now?"

    static let firstLineRequest = """
        Write the one sentence you will say out loud to offer the pick. Name the drink, then the one or two \
        body facts it follows from, in plain words. No greeting, no emoji, no second sentence.
        """

    /// The last line of the prompt: how to sound, and in which language.
    static func languageRule(_ language: Language) -> String {
        language == .ja
            ? "Reply only in Japanese, in plain spoken form (です・ます), one or two short sentences, warm, like a friend at the machine. No lists, no bullet points."
            : "Sound like a friend standing at the machine, one or two short sentences, no lists."
    }

    /// Step A: offer the three options in one spoken sentence.
    static func choicesRequest(options: [Drink]) -> String {
        "Offer these drinks in one short spoken sentence, in this order, naming each once and nothing else: "
            + options.map { "\($0.name) (\($0.nameJa))" }.joined(separator: ", ") + "."
    }

    /// Step B: the wearer chose one; one warm sentence about why it fits.
    static func chosenRequest(pick: Drink, language: Language) -> String {
        "The wearer chose \(pick.name) (\(pick.nameJa)). Say one warm sentence about why it fits, in \(language == .ja ? "Japanese" : "English")."
    }

    static func systemPrompt(snapshot: PhysiologySnapshot, pick: Drink, recommendation: Recommendation,
                             catalog: DrinkCatalog, sourceLabel: String, language: Language = .en) -> String {
        let alternates = recommendation.ranked.filter { $0 != pick }.prefix(2)
        let list = catalog.drinks.map { "\($0.name) (\($0.nameJa)): \($0.kind), \(functionList($0)), caffeine \($0.caffeineMg) mg, sugar \($0.sugar.rawValue)" }
        return """
        You are the drink assistant on the wearer's smart glasses, standing with them at a beverage vending machine. \
        Your answers are spoken aloud: one or two short sentences, plain and friendly.

        Today's body data (source: \(sourceLabel)): \(summary(of: snapshot))

        An on-device rule picked the drink; you did not. Current pick: \(pick.name) (\(pick.nameJa)), a \(pick.kind). \
        The rule's reasons: \(recommendation.reasons.joined(separator: "; ")). \
        Next best: \(alternates.map(\.name).joined(separator: ", ")).

        Rules you follow:
        - Ground every claim in the numbers above. Say what the data suggests and what it looks like; it is never a diagnosis, \
        and you never name a feeling or a mental state.
        - No medical or health claims. A drink is a small, pleasant choice, not a treatment.
        - If asked for beer or any alcohol, say this app only knows soft drinks and offer the pick again.
        - If asked for something else, choose only from the catalogue below and say why in one sentence.
        - Keep to the pick unless the wearer asks; do not list the whole catalogue aloud.

        Catalogue:
        \(list.joined(separator: "\n"))

        \(languageRule(language))
        """
    }

    /// "slept 6.4 h, sleep score 63, HRV 36 ms against a usual 52 ms, resting heart rate 61 against a usual 54, 4000 steps, stress 71 of 100".
    static func summary(of s: PhysiologySnapshot) -> String {
        var parts = ["slept \(String(format: "%.1f", s.sleep.hours)) h"]
        if let score = s.sleep.score { parts.append("sleep score \(score)") }
        if let hrv = s.hrvMs {
            if let base = s.hrvBaselineMs { parts.append("HRV \(Int(hrv.rounded())) ms against a usual \(Int(base.rounded())) ms") }
            else { parts.append("HRV \(Int(hrv.rounded())) ms") }
        }
        if let hr = s.restingHR {
            if let base = s.restingHRBaseline { parts.append("resting heart rate \(Int(hr.rounded())) against a usual \(Int(base.rounded()))") }
            else { parts.append("resting heart rate \(Int(hr.rounded()))") }
        }
        if let steps = s.steps { parts.append("\(steps) steps so far") }
        if let stress = s.stress { parts.append("stress \(stress) of 100") }
        return parts.joined(separator: ", ")
    }

    /// Spoken when the AI cannot phrase the first line.
    static func fallbackLine(pick: Drink, recommendation: Recommendation) -> String {
        let reasons = recommendation.reasons.prefix(2).joined(separator: ", ")
        let sentence = reasons.isEmpty ? "" : " " + String(reasons.prefix(1)).uppercased() + String(reasons.dropFirst()) + "."
        return "Try \(article(for: pick.name)) \(pick.name).\(sentence)"
    }

    static func alternateLine(pick: Drink) -> String {
        "How about \(article(for: pick.name)) \(pick.name)?"
    }

    /// Spoken for "why" when there is no AI to answer.
    static func whyFallback(recommendation: Recommendation) -> String {
        guard let first = recommendation.reasons.first else { return "Because it fits how you slept." }
        let rest = Array(recommendation.reasons.dropFirst().prefix(2))
        let afterCutoff = "it is after 3 pm"
        let nounish = rest.filter { $0 != afterCutoff }
        var sentence = "Because you \(first)"
        if !nounish.isEmpty { sentence += ", with " + joinedWithAnd(nounish) }
        if rest.contains(afterCutoff) { sentence += ", and \(afterCutoff)" }
        return sentence + "."
    }

    /// "a", "a and b", "a, b and c".
    private static func joinedWithAnd(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    private static func functionList(_ d: Drink) -> String {
        d.functions.map(\.rawValue).joined(separator: "/")
    }

    private static func article(for name: String) -> String {
        guard let first = name.lowercased().first else { return "a" }
        return "aeiou".contains(first) ? "an" : "a"
    }
}
