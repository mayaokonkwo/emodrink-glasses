//
// LensContent.swift
//
// What is on the lens right now, as a value. The glasses render it through
// the Meta SDK's view DSL (HermesDisplayScreens); phone mode renders the
// SAME value in SwiftUI (SimulatedLensView). EmoDrink cases carry their
// text already in the wearer's language (EmoDrinkStrings). Foundation only,
// so the text derivation unit-tests standalone (tests/lens-content).
//

import Foundation

/// One drink offered in the three-drink step.
struct LensDrinkOption: Equatable {
    /// Name in the active language (shown large, read by the parser).
    let title: String
    /// Name in the other language.
    let subtitle: String
    /// That drink's one-line reason.
    let reason: String
}

enum LensContent: Equatable {
    case blank
    case listening(partial: String)
    case thinking(query: String)
    case photoCaptured
    case reply(text: String, speaking: Bool, choices: [ReplyChoice] = [])
    case newConversation
    /// EmoDrink step B: the chosen drink, with Why / Thanks.
    case emoDrink(title: String, subtitle: String, reason: String, source: String, choices: [ReplyChoice])
    /// EmoDrink step A: three drinks as numbered buttons.
    case emoDrinkChoices(heading: String, options: [LensDrinkOption], source: String)
    /// EmoDrink drink mode, nothing in view yet.
    case emoDrinkWatching(heading: String, text: String, hint: String)

    /// Nothing to draw: the simulated lens shows its empty frame.
    var isBlank: Bool { self == .blank }

    /// Tappable replies the current screen offers. A choice button's label
    /// ("2 Calpis Water") is also its reply, which DrinkChoiceParser reads.
    var choices: [ReplyChoice] {
        switch self {
        case .reply(_, _, let choices): return choices
        case .emoDrink(_, _, _, _, let choices): return choices
        case .emoDrinkChoices(_, let options, _):
            return options.enumerated().map { ReplyChoice(key: "\($0.offset + 1)", label: "\($0.offset + 1) \($0.element.title)") }
        default: return []
        }
    }

    /// Small all-caps line above the body, or nil.
    var label: String? {
        switch self {
        case .blank, .thinking, .reply, .emoDrink, .emoDrinkChoices: return nil
        case .listening: return "LISTENING"
        case .photoCaptured: return "PHOTO"
        case .newConversation: return "NEW CHAT"
        case .emoDrinkWatching(let heading, _, _): return heading.uppercased()
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
        case .emoDrinkChoices(let heading, _, _): return heading
        case .emoDrinkWatching(_, let text, _): return text
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
        case .emoDrinkChoices(_, let options, let source):
            guard let reason = options.first?.reason, !reason.isEmpty else { return source }
            return "\(reason) · \(source)"
        case .emoDrinkWatching(_, _, let hint): return hint
        }
    }

    /// True while the wearer is expected to keep looking, so the simulated
    /// lens keeps a live dot lit.
    var isLive: Bool {
        switch self {
        case .blank, .photoCaptured, .newConversation: return false
        case .listening, .thinking, .reply, .emoDrink, .emoDrinkChoices, .emoDrinkWatching: return true
        }
    }
}
