//
// VoiceCommandCatalog.swift
//
// What you can say, read STRAIGHT OUT of the detectors that match it
// (IntentDetector, EmoDrinkCommands, VisualQueryDetector), so the list
// cannot drift from what the app recognises.
//

import Foundation

struct VoiceCommandGroup: Identifiable {
    let id: String
    let title: String
    let summary: String
    let examples: [String]
    let phrases: [String]
}

enum VoiceCommandCatalog {
    static var groups: [VoiceCommandGroup] {
        [
            VoiceCommandGroup(
                id: "emodrink",
                title: "Pick a drink",
                summary: "Shows drinks that fit last night's sleep and this morning's body data. Drink mode watches the camera and offers them when a vending machine comes into view.",
                examples: ["What should I drink", "Start drink mode", "何を飲めばいい", "見守りを開始"],
                phrases: IntentDetector.recommendDrinkCommands.sorted()
                    + IntentDetector.startDrinkModeCommands.sorted()
                    + IntentDetector.stopDrinkModeCommands.sorted()),
            VoiceCommandGroup(
                id: "emodrink-replies",
                title: "Talk about the drink",
                summary: "Heard while a drink is on the lens. Anything else you say is a question for the drink assistant.",
                examples: ["Why", "Back", "Thanks", "なぜ？", "戻る", "ありがとう"],
                phrases: EmoDrinkCommands.whyPhrases.sorted()
                    + EmoDrinkCommands.somethingElsePhrases.sorted()
                    + EmoDrinkCommands.thanksPhrases.sorted()
                    + EmoDrinkCommands.backPhrases.sorted()
                    + EmoDrinkCommands.stopPhrases.sorted()),
            VoiceCommandGroup(
                id: "visual",
                title: "Ask about what you see",
                summary: "Takes a photo and sends it with your question.",
                examples: ["What am I looking at"],
                phrases: VisualQueryDetector.keywords.sorted()),
        ]
    }
}
