//
// HermesSpeechSynthesizer.swift
//
// Text-to-speech for the spoken lines. With a `CloudSpeech` configured, a
// line is fetched from Gemini (length-aware timeout, 3 to 10 s) and played with AVAudioPlayer;
// offline, on any error or after the timeout, the same line is spoken by
// the on-device AVSpeechSynthesizer voice. Both play through the app's
// current audio session and route (this file never touches the session).
// Interruption is stop(): it cancels a fetch, stops the player, or stops
// the on-device voice, and onFinished fires once.
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

    // Cloud voice (nil = on-device only).
    private var cloud: CloudSpeech?
    /// The language the cloud voice speaks: the on-device voice's language.
    private var cloudLanguage: Language = .en
    private var fetchTask: Task<Void, Never>?
    private var player: AVAudioPlayer?
    /// Bumped by every speak/stop so a late fetch cannot play over a newer line.
    private var cloudGeneration = 0
    private var cloudLastFailed = false
    /// Each cloud attempt's outcome: true = Gemini audio played, false = fell
    /// back on-device. Delivered on the main queue.
    var onCloudOutcome: ((Bool) -> Void)?

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
        cloudLanguage = choice.language
        if let name = choice.voice?.name {
            logger.info("TTS voice: \(name, privacy: .public) for \(language.rawValue, privacy: .public)")
        }
        return (choice.language, VoicePicker.needsEnhancedHint(for: language, available: installed), choice.voice?.name)
    }

    func configure(voice: AVSpeechSynthesisVoice?, rate: Float) {
        self.voice = voice
        self.rate = rate
    }

    /// Use the Gemini voice for every line (nil = on-device only).
    func configureCloud(_ cloud: CloudSpeech?) {
        self.cloud = cloud
        cloudLastFailed = false
    }

    /// Configured, and the last attempt (if any) played Gemini audio.
    var cloudVoiceActive: Bool { cloud != nil && !cloudLastFailed }
    /// The Gemini voice for the current language, when configured.
    var cloudVoiceName: String? { cloud == nil ? nil : CloudSpeechCodec.voiceName(for: cloudLanguage) }

    // MARK: - Public API

    /// Covers the on-device voice, the cloud player and an in-flight fetch.
    var isSpeaking: Bool { synthesizer.isSpeaking || fetchTask != nil || player != nil }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            DispatchQueue.main.async { [weak self] in self?.onFinished?() }
            return
        }
        // A newer line replaces any cloud line silently (no onFinished).
        cancelCloud()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        guard let cloud else {
            speakOnDevice(trimmed)
            return
        }
        let generation = cloudGeneration
        let language = cloudLanguage
        logger.info("Speaking \(trimmed.count) chars with the cloud voice")
        fetchTask = Task { @MainActor [weak self] in
            do {
                let wav = try await cloud.synthesize(trimmed, language: language)
                guard let self, generation == self.cloudGeneration, !Task.isCancelled else { return }
                self.fetchTask = nil
                let player = try AVAudioPlayer(data: wav)
                player.delegate = self
                self.player = player
                guard player.play() else {
                    self.player = nil
                    throw CloudSpeechError.playbackFailed
                }
                self.recordCloud(success: true)
            } catch {
                guard let self, generation == self.cloudGeneration, !Task.isCancelled else { return }
                self.fetchTask = nil
                self.logger.warning("Cloud voice failed (\(CloudSpeech.describe(error), privacy: .public)); on-device fallback")
                self.recordCloud(success: false)
                self.speakOnDevice(trimmed)
            }
        }
    }

    private func recordCloud(success: Bool) {
        cloudLastFailed = !success
        onCloudOutcome?(success)
    }

    /// Cancel a fetch and stop the cloud player, without onFinished.
    private func cancelCloud() {
        cloudGeneration += 1
        fetchTask?.cancel()
        fetchTask = nil
        player?.stop()
        player = nil
    }

    private func speakOnDevice(_ trimmed: String) {
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        logger.info("Speaking \(trimmed.count) chars on-device")
        synthesizer.speak(utterance)
    }

    /// Barge-in: stop immediately. The delegate's didCancel fires onFinished
    /// for the on-device voice; a cloud fetch or player fires it here
    /// (AVAudioPlayer.stop() does not call its delegate).
    func stop() {
        if fetchTask != nil || player != nil {
            cancelCloud()
            DispatchQueue.main.async { [weak self] in self?.onFinished?() }
            return
        }
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }
}

// MARK: - AVAudioPlayerDelegate (cloud voice)

extension HermesSpeechSynthesizer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player === player else { return }
            self.player = nil
            self.onFinished?()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player === player else { return }
            self.player = nil
            self.onFinished?()
        }
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
