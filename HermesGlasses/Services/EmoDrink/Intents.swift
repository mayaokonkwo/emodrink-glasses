//
// Intents.swift
//
// What a finalized utterance asks for before it reaches the assistant.
// Foundation only, so IntentDetector tests compile with swiftc.
//

import Foundation

/// `.none` means the normal reply path (a question for the assistant).
enum HermesIntent: Equatable {
    /// "what should I drink": run the pick now, camera or not.
    case recommendDrink
    /// "start drink mode": watch the camera for a vending machine.
    case startDrinkMode
    case stopDrinkMode
    case none
}
