//
// VoicePicker.swift
//
// Which installed system voice speaks EmoDrink's lines. Premium over
// enhanced over default; within a quality, a preferred list per language
// (en: Ava, Zoe, Samantha; ja: Kyoko, O-ren); novelty voices never. Pure
// selection over plain descriptors so it tests without AVFoundation;
// HermesSpeechSynthesizer turns AVSpeechSynthesisVoice into descriptors.
// Tested in tests/emodrink-voice.
//

import Foundation

/// An installed voice. `quality` uses AVSpeechSynthesisVoiceQuality's raw
/// values: 1 default, 2 enhanced, 3 premium.
struct VoiceDescriptor: Equatable {
    let identifier: String
    let name: String
    let language: String
    let quality: Int
    var isNovelty: Bool = false
}

enum VoicePicker {
    /// AVSpeechUtterance rate: a measured pace, a little under the default 0.5.
    static let rate: Float = 0.47
    static let pitch: Float = 1.0
    static let enhancedQuality = 2

    static func preferredNames(for language: Language) -> [String] {
        language == .ja ? ["Kyoko", "O-ren"] : ["Ava", "Zoe", "Samantha"]
    }

    /// The best voice that speaks `language`, or nil when none is installed.
    /// Never a voice of another language: Japanese text read by an English
    /// voice is worse than the fallback the caller chooses.
    static func pick(for language: Language, available: [VoiceDescriptor]) -> VoiceDescriptor? {
        let prefix = language.rawValue
        let candidates = available.filter {
            !$0.isNovelty && $0.language.lowercased().hasPrefix(prefix)
        }
        let preferred = preferredNames(for: language)
        func rank(_ v: VoiceDescriptor) -> Int {
            preferred.firstIndex { v.name.hasPrefix($0) } ?? preferred.count
        }
        return candidates.min { a, b in
            if a.quality != b.quality { return a.quality > b.quality }
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            let ea = a.language == language.ttsLanguage, eb = b.language == language.ttsLanguage
            if ea != eb { return ea }
            return a.identifier < b.identifier
        }
    }

    /// The voice to use and the language it speaks: `language` when any
    /// voice for it exists, otherwise English (spec: no ja-JP voice, speak
    /// English and show the install hint).
    static func choose(for language: Language, available: [VoiceDescriptor]) -> (voice: VoiceDescriptor?, language: Language) {
        if let voice = pick(for: language, available: available) { return (voice, language) }
        return (pick(for: .en, available: available), .en)
    }

    /// True when the best voice for `language` is only default quality (or
    /// missing): Settings and onboarding then suggest installing an enhanced one.
    static func needsEnhancedHint(for language: Language, available: [VoiceDescriptor]) -> Bool {
        (pick(for: language, available: available)?.quality ?? 0) < enhancedQuality
    }
}
