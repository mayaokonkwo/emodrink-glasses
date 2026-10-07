//
// IntentDetector.swift
//
// Pure, on-device classification of a finalized utterance into an EmoDrink
// command, or nothing. Runs BEFORE the assistant, so it stays cheap and
// Foundation-only. Every phrase is a WHOLE utterance: "what should I drink
// tonight with dinner" is a question for the assistant, not the command.
// Tested in tests/intent.
//

import Foundation

enum IntentDetector {
    static let recommendDrinkCommands: Set<String> = [
        "what should i drink", "what should i get", "pick a drink", "pick me a drink",
        "recommend a drink", "recommend me a drink", "which drink", "what do i drink",
    ]
    static let startDrinkModeCommands: Set<String> = [
        "start drink mode", "drink mode on", "begin drink mode", "start emodrink",
    ]
    static let stopDrinkModeCommands: Set<String> = [
        "stop drink mode", "drink mode off", "end drink mode", "stop emodrink",
    ]

    /// Lowercase, strip punctuation and leading address filler, collapse
    /// whitespace, so "Hey, what should I drink?" reduces to the command.
    static func normalizeCommand(_ text: String) -> String {
        var s = text.lowercased()
            .replacingOccurrences(of: ",", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ?.!,'\""))
        s = s.split(separator: " ").joined(separator: " ")
        for filler in ["hey ", "ok ", "okay ", "hermes ", "please "] {
            while s.hasPrefix(filler) {
                s = String(s.dropFirst(filler.count))
            }
        }
        return s.split(separator: " ").joined(separator: " ")
    }

    static func detect(_ text: String) -> HermesIntent {
        let command = normalizeCommand(text)
        guard !command.isEmpty else { return .none }
        if recommendDrinkCommands.contains(command) { return .recommendDrink }
        if startDrinkModeCommands.contains(command) { return .startDrinkMode }
        if stopDrinkModeCommands.contains(command) { return .stopDrinkMode }
        return .none
    }
}
