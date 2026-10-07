//
// HermesSpeechSynthesizer.swift
//
// On-device text-to-speech for Hermes's replies via AVSpeechSynthesizer.
// Speech starts the instant the response text
// arrives, no cloud synthesis or PCM streaming. Plays through the current
// audio route (glasses in HFP mode). Interruption is stopSpeaking().
//

import AVFoundation
import Foundation
import os

final class HermesSpeechSynthesizer: NSObject, @unchecked Sendable {
    // MARK: - Callbacks (delivered on the main queue)

    /// Fired when an utterance finishes OR is cancelled
    var onFinished: (() -> Void)?

    // MARK: - Private

    private let logger = Logger(subsystem: "com.flowsxr.hermesglasses", category: "tts")
    private let synthesizer = AVSpeechSynthesizer()
    private var voice: AVSpeechSynthesisVoice?
    private var rate: Float = VoicePicker.rate
    private var pitch: Float = VoicePicker.pitch

    override init() {
        super.init()
        synthesizer.delegate = self
        configure(for: .en)
    }

    /// Every installed voice as a plain descriptor for VoicePicker.
    static func installedVoices() -> [VoiceDescriptor] {
        AVSpeechSynthesisVoice.speechVoices().map { v in
            VoiceDescriptor(identifier: v.identifier, name: v.name, language: v.language,
                            quality: v.quality.rawValue, isNovelty: v.voiceTraits.contains(.isNoveltyVoice))
        }
    }

    /// Pick and use the best voice for `language`. Returns the language the
    /// voice actually speaks (English when no voice for `language` exists),
    /// whether only a default-quality voice was found, and the voice's name.
    @discardableResult
    func configure(for language: Language) -> (language: Language, needsHint: Bool, voiceName: String?) {
        let installed = Self.installedVoices()
        let choice = VoicePicker.choose(for: language, available: installed)
        configure(voice: choice.voice.flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) }, rate: VoicePicker.rate)
        if let name = choice.voice?.name {
            logger.info("TTS voice: \(name, privacy: .public) for \(language.rawValue, privacy: .public)")
        }
        return (choice.language, VoicePicker.needsEnhancedHint(for: language, available: installed), choice.voice?.name)
    }

    func configure(voice: AVSpeechSynthesisVoice?, rate: Float) {
        self.voice = voice
        self.rate = rate
    }

    // MARK: - Public API

    var isSpeaking: Bool { synthesizer.isSpeaking }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            DispatchQueue.main.async { [weak self] in self?.onFinished?() }
            return
        }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        logger.info("Speaking \(trimmed.count) chars on-device")
        synthesizer.speak(utterance)
    }

    /// Barge-in: stop immediately. The delegate's didCancel fires onFinished.
    func stop() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension HermesSpeechSynthesizer: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        DispatchQueue.main.async { [weak self] in self?.onFinished?() }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        DispatchQueue.main.async { [weak self] in self?.onFinished?() }
    }
}
