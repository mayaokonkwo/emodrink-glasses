//
// VendingMachineDetector.swift
//
// The one vision question drink mode asks, and the strict reading of the
// answer. Only a reply that STARTS with the word YES counts; "Yesterday",
// a later "yes" in a sentence, or a hedge is NO. Foundation only; tested
// in tests/emodrink-detector.
//

import Foundation

enum VendingMachineDetector {
    static let systemPrompt = "You are a strict image classifier. Reply with exactly one word and nothing else."
    static let userText = "Is a beverage vending machine clearly visible and close enough to buy from in this photo? Answer with one word, YES or NO."

    static func isYes(_ reply: String) -> Bool {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = trimmed.unicodeScalars.drop { !CharacterSet.letters.contains($0) }
        let firstWord = scalars.prefix { CharacterSet.letters.contains($0) }
        return String(String.UnicodeScalarView(firstWord)).uppercased() == "YES"
    }
}
