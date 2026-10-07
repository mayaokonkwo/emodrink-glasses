//
// DrinkChoiceParser.swift
//
// Spoken or tapped text to one of the offered drinks (index 0..2), or nil.
// Reads ordinals and numbers in English and Japanese ("two", "the second
// one", 「二番目」「二つ目」「最初の」), the lens button's own label ("2 Calpis
// Water"), and a DISTINCTIVE token of a drink's English or Japanese name:
// a token two options share ("Asahi", or "water" when two names contain it)
// never decides. Both languages are always read, because speech recognition
// mixes scripts; `language` is part of the signature for future tie-breaks.
// Short utterances only, so a question that mentions a drink is still a
// question. Foundation only; tested in tests/emodrink-choice.
//

import Foundation

/// One offered drink, in both scripts.
struct ChoiceOption: Equatable {
    let name: String
    let nameJa: String
}

enum DrinkChoiceParser {
    static let maxEnglishWords = 5
    static let maxJapaneseChars = 15

    static func index(for text: String, options: [ChoiceOption], language: Language) -> Int? {
        guard !options.isEmpty else { return nil }
        let s = normalize(text)
        guard !s.isEmpty else { return nil }
        if let i = tapIndex(s) ?? ordinalIndex(s) {
            return i < options.count ? i : nil
        }
        return nameIndex(s, options: options)
    }

    // MARK: Normalising

    private static let fullWidthDigits = Array("０１２３４５６７８９")
    private static let punctuation = CharacterSet(charactersIn: ",.!?;:'\"、。？！「」『』・…()（）\u{3000}")

    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased().map { c -> String in
            if let i = fullWidthDigits.firstIndex(of: c) { return String(i) }
            return String(c)
        }.joined()
        let spaced = lowered.unicodeScalars.map { punctuation.contains($0) ? " " : String($0) }.joined()
        return spaced.split(separator: " ").joined(separator: " ")
    }

    // MARK: Numbers and ordinals

    /// A tapped lens button submits "2 Calpis Water": a leading digit wins.
    private static func tapIndex(_ s: String) -> Int? {
        guard let first = s.first, let digit = first.wholeNumberValue, digit >= 1,
              s.count == 1 || s.dropFirst().first == " " else { return nil }
        return digit - 1
    }

    private static let english: [String: Int] = [
        "one": 0, "1": 0, "1st": 0, "first": 0,
        "two": 1, "2": 1, "2nd": 1, "second": 1,
        "three": 2, "3": 2, "3rd": 2, "third": 2,
        "four": 3, "4": 3, "4th": 3, "fourth": 3,
        "five": 4, "5": 4, "5th": 4, "fifth": 4,
    ]
    private static let englishLead: Set<String> = ["the", "number", "option", "drink"]
    private static let englishTail: Set<String> = ["one", "please", "thanks"]

    private static let japanese: [String: Int] = [
        "一": 0, "一番": 0, "一番目": 0, "1番": 0, "1番目": 0, "一つ目": 0, "1つ目": 0, "ひとつめ": 0, "最初": 0, "いち": 0,
        "二": 1, "二番": 1, "二番目": 1, "2番": 1, "2番目": 1, "二つ目": 1, "2つ目": 1, "ふたつめ": 1, "真ん中": 1, "に": 1,
        "三": 2, "三番": 2, "三番目": 2, "3番": 2, "3番目": 2, "三つ目": 2, "3つ目": 2, "みっつめ": 2, "最後": 2, "さん": 2,
        "四": 3, "四番目": 3, "4番目": 3,
    ]
    /// Longest first: "にする" must go before "の" is considered.
    private static let japaneseTails = ["でお願いします", "にしてください", "にします", "にする", "をください", "ください",
                                        "がいいです", "がいい", "のやつ", "やつ", "です", "で", "を", "の"]
    private static let japaneseLeads = ["じゃあ", "えっと", "では"]

    private static func ordinalIndex(_ s: String) -> Int? {
        var words = s.split(separator: " ").map(String.init)
        while words.count > 1, englishLead.contains(words[0]) { words.removeFirst() }
        while words.count > 1, let last = words.last, englishTail.contains(last) { words.removeLast() }
        if words.count == 1, let i = english[words[0]] { return i }

        var core = s.replacingOccurrences(of: " ", with: "")
        for lead in japaneseLeads where core.hasPrefix(lead) && core.count > lead.count {
            core = String(core.dropFirst(lead.count))
        }
        var stripped = true
        while stripped {
            stripped = false
            for tail in japaneseTails where core.hasSuffix(tail) && core.count > tail.count {
                core = String(core.dropLast(tail.count))
                stripped = true
                break
            }
        }
        return japanese[core]
    }

    // MARK: Names

    private static let stopTokens: Set<String> = ["the", "and", "of"]

    private static func englishTokens(_ name: String) -> Set<String> {
        Set(name.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 && !stopTokens.contains($0) })
    }

    private static func japaneseTokens(_ name: String) -> Set<String> {
        Set(name.split(separator: " ").map(String.init).filter { $0.count >= 2 })
    }

    private static func nameIndex(_ s: String, options: [ChoiceOption]) -> Int? {
        let words = s.split(separator: " ").map(String.init)
        let core = words.joined()
        let japaneseText = core.unicodeScalars.contains { $0.value >= 0x3040 }
        if japaneseText {
            guard core.count <= maxJapaneseChars else { return nil }
        } else {
            guard words.count <= maxEnglishWords else { return nil }
        }

        let en = options.map { englishTokens($0.name) }
        let ja = options.map { japaneseTokens($0.nameJa) }
        var enCount: [String: Int] = [:]
        var jaCount: [String: Int] = [:]
        for set in en { for t in set { enCount[t, default: 0] += 1 } }
        for set in ja { for t in set { jaCount[t, default: 0] += 1 } }

        var bestLength = 0
        var bestIndex: Int?
        var tie = false
        func consider(_ length: Int, _ index: Int) {
            if length > bestLength {
                bestLength = length; bestIndex = index; tie = false
            } else if length == bestLength, index != bestIndex {
                tie = true
            }
        }
        let wordSet = Set(words)
        for i in options.indices {
            for t in en[i] where enCount[t] == 1 && wordSet.contains(t) { consider(t.count, i) }
            for t in ja[i] where jaCount[t] == 1 {
                if core.contains(t) { consider(t.count, i) }
                else if japaneseText, core.count >= 2, t.contains(core) { consider(core.count, i) }
            }
        }
        return tie ? nil : bestIndex
    }
}
