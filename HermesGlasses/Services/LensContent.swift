//
// LensContent.swift
//
// What is on the lens right now, as a value. The glasses render it through
// the Meta SDK's view DSL (HermesDisplayScreens); phone mode renders the
// SAME value in SwiftUI (SimulatedLensView). Foundation only, so the text
// derivation unit-tests standalone with swiftc (tests/lens-content).
//

import Foundation

enum LensContent: Equatable {
    case blank
    case listening(partial: String)
    case thinking(query: String)
    case photoCaptured
    case reply(text: String, speaking: Bool, choices: [ReplyChoice] = [])
    case newConversation
    /// EmoDrink: the chosen drink, with tappable replies.
    case emoDrink(title: String, subtitle: String, reason: String, source: String, choices: [ReplyChoice])
    /// EmoDrink drink mode, nothing in view yet.
    case emoDrinkWatching

    /// Nothing to draw: the simulated lens shows its empty frame.
    var isBlank: Bool { self == .blank }

    /// Tappable replies the current screen offers. Empty for the others.
    var choices: [ReplyChoice] {
        switch self {
        case .reply(_, _, let choices): return choices
        case .emoDrink(_, _, _, _, let choices): return choices
        default: return []
        }
    }

    /// Small all-caps line above the body, or nil.
    var label: String? {
        switch self {
        case .blank, .thinking, .reply: return nil
        case .listening: return "LISTENING"
        case .photoCaptured: return "PHOTO"
        case .newConversation: return "NEW CHAT"
        case .emoDrink: return "DRINK"
        case .emoDrinkWatching: return "DRINK MODE"
        }
    }

    /// The main line. Empty string means "draw nothing".
    var body: String {
        switch self {
        case .blank: return ""
        case .listening(let partial): return partial
        case .thinking(let query): return query
        case .photoCaptured: return "Photo captured"
        case .reply(let text, _, _): return text
        case .newConversation: return "New conversation"
        case .emoDrink(let title, _, _, _, _): return title
        case .emoDrinkWatching: return "Watching for a vending machine"
        }
    }

    /// Monospaced status line under the body, or nil.
    var statusLine: String? {
        switch self {
        case .blank, .photoCaptured, .newConversation: return nil
        case .listening: return "listening"
        case .thinking: return "thinking…"
        case .reply(_, let speaking, let choices):
            if !choices.isEmpty { return "\(choices.count) options - tap one" }
            return speaking ? "speaking" : nil
        case .emoDrink(_, _, let reason, let source, _): return "\(reason) · \(source)"
        case .emoDrinkWatching: return "say \"what should I drink\" any time"
        }
    }

    /// True while the wearer is expected to keep looking, so the simulated
    /// lens keeps a live dot lit.
    var isLive: Bool {
        switch self {
        case .blank, .photoCaptured, .newConversation: return false
        case .listening, .thinking, .reply, .emoDrink, .emoDrinkWatching: return true
        }
    }
}
