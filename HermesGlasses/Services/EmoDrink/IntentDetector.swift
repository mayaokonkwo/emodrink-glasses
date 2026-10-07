//
// IntentDetector.swift
//
// Pure, on-device classification of a finalized utterance into an EmoDrink
// command, or nothing. Runs BEFORE the assistant, so it stays cheap and
// Foundation-only. Every phrase is a WHOLE utterance, in English or
// Japanese: "what should I drink tonight with dinner" and
// 「何を飲めばいいか迷う」 are questions for the assistant, not the command.
// Tested in tests/intent.
//

import Foundation

enum IntentDetector {
    static let recommendDrinkCommands: Set<String> = [
        "what should i drink", "what should i get", "pick a drink", "pick me a drink",
        "recommend a drink", "recommend me a drink", "which drink", "what do i drink",
        "何を飲めばいい", "何を飲めばいいですか", "何飲めばいい", "何飲もう", "何を飲もう",
        "おすすめの飲み物", "おすすめの飲み物は", "おすすめは",
    ]
    static let startDrinkModeCommands: Set<String> = [
        "start drink mode", "drink mode on", "begin drink mode", "start emodrink",
        "見守りを開始", "見守り開始", "ドリンクモード開始", "ドリンクモードを開始",
    ]
    static let stopDrinkModeCommands: Set<String> = [
        "stop drink mode", "drink mode off", "end drink mode", "stop emodrink",
        "見守りを停止", "見守り停止", "ドリンクモード停止", "ドリンクモードを停止",
    ]

    /// Lowercase, strip punctuation (Japanese 、。？！ too) and leading
    /// address filler, collapse whitespace, so "Hey, what should I drink?"
    /// and 「何を飲めばいい？」 reduce to the command. Japanese has no word
    /// spaces, so spaces a recogniser inserts between Japanese words go.
    static func normalizeCommand(_ text: String) -> String {
        var s = text.lowercased()
        for mark in [",", "、", "。", "？", "！", "「", "」", "\u{3000}"] {
            s = s.replacingOccurrences(of: mark, with: " ")
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ?.!,'\""))
        s = s.split(separator: " ").joined(separator: " ")
        for filler in ["hey ", "ok ", "okay ", "hermes ", "please "] {
            while s.hasPrefix(filler) {
                s = String(s.dropFirst(filler.count))
            }
        }
        s = s.split(separator: " ").joined(separator: " ")
        if s.unicodeScalars.contains(where: { $0.value >= 0x3040 }) {
            s = s.replacingOccurrences(of: " ", with: "")
        }
        return s
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
