//
// HermesSessionViewModel.swift
//
// Core view model managing the Hermes voice conversation session.
// Connects to Meta glasses, captures audio, streams to Hermes Agent,
// and plays back responses through the glasses.
//

import CoreMedia
import MWDATCamera
import MWDATCore
import Observation
import os
import SwiftUI

@Observable
@MainActor
final class HermesSessionViewModel {
    // MARK: - Published state

    /// The language the session hears and speaks right now. Japanese only
    /// when both a ja-JP recognizer and a ja-JP voice exist.
    private(set) var activeLanguage: Language = .en
    /// Only a default-quality voice is installed for the language.
    private(set) var voiceNeedsInstallHint = false
    private(set) var voiceName: String?

    var connectionState: HermesConnectionState = .disconnected
    var isGlassesConnected: Bool = false
    /// Words recognized so far in the current utterance (live)
    var liveTranscript: String = ""
    /// Mic input level 0..~1 for the UI meter
    var micLevel: Float = 0
    /// Test-panel results keyed by test name: nil=never run, ""=pass, else error
    var testResults: [String: String?] = [:]
    var testRunning: Set<String> = []
    /// The failure message from the most recently completed test, cleared on
    /// a pass. `testResults` is a dictionary, so scanning its `.values` for
    /// "the" failure returns whichever one the dictionary enumerates first -
    /// this is set explicitly by `runTest` so the Developer panel always
    /// shows the outcome of the test that was just run.
    var lastTestFailure: String? = nil
    /// Outputs of the last Developer-panel Photo / Sound tests, so the panel
    /// can show what actually happened instead of burying it in the chat.
    var lastTestPhoto: UIImage? = nil
    var lastTestPhotoSource: String? = nil
    var lastTestAudioRoute: String? = nil

    // MARK: EmoDrink hooks (set by EmoDrinkViewModel)

    /// While a drink is on the lens, every finalized utterance is offered
    /// here first; true = it was a reply (why / something else / thanks) and
    /// nothing reaches the brain. False = a question for the drink persona.
    @ObservationIgnored var emoDrinkClaimer: (@MainActor (String) -> Bool)?
    /// "what should I drink" / "start drink mode" / "stop drink mode".
    @ObservationIgnored var onEmoDrinkIntent: (@MainActor (HermesIntent) -> Void)?
    /// The session is being torn down; drink mode must stop its stream.
    @ObservationIgnored var onEmoDrinkSessionEnding: (@MainActor () -> Void)?
    /// When the lens would otherwise blank after a reply's dwell, EmoDrink may restore its card. Returns true when it drew something.
    @ObservationIgnored var emoDrinkLensIdle: (@MainActor () -> Bool)?
    /// Queued cues (`speakCue(_:queued: true)`) waiting for the current one
    /// to finish; drained one at a time by `speechSynthesizer.onFinished`.
    @ObservationIgnored private var cueQueue: [String] = []

    /// Glasses camera permission (granted in the Meta AI app); nil = unknown
    var cameraPermissionGranted: Bool? = nil
    /// Preferred microphone source; the banner chip shows the ACTUAL route
    var micSource: MicSource = MicSource(
        rawValue: UserDefaults.standard.string(
            forKey: HermesSessionViewModel.micSourceKey
        ) ?? ""
    ) ?? .phone
    /// Glasses display HUD (Ray-Ban Display): live transcript, replies,
    /// status on the lens. Default on; harmless on non-display glasses.
    var displayHUDEnabled: Bool =
        (UserDefaults.standard.object(forKey: "display_hud_enabled") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(displayHUDEnabled, forKey: "display_hud_enabled")
            if !displayHUDEnabled {
                displayManager.stop()
            } else if let session = deviceSession {
                if lensBlockedByCallScreen {
                    // HUD and the glasses' HFP mic are mutually exclusive
                    // (their call screen covers the lens). HUD wins: hop
                    // back to the iPhone mic, which re-attaches the
                    // display when the route settles.
                    Task { @MainActor [weak self] in
                        guard let self, self.micSource == .glasses else { return }
                        await self.setMicSource(.phone)
                        // News, not a fault: `show(_:)` is the error channel
                        // and also fails any pending Developer-panel test.
                        self.show(notice: "Switched to the iPhone mic - the lens HUD can't show while the glasses' hands-free mic is active.")
                    }
                } else {
                    displayManager.stop()
                    displayManager.start(session: session)
                }
            }
        }
    }
    /// Silent mode: when the display is attached, show the reply as text
    /// instead of speaking it. No effect while the display is unavailable.
    var displaySilentMode: Bool =
        UserDefaults.standard.bool(forKey: "display_silent_mode") {
        didSet {
            UserDefaults.standard.set(displaySilentMode, forKey: "display_silent_mode")
        }
    }
    /// Attach time/location/status context to every query
    var contextEnabled: Bool =
        (UserDefaults.standard.object(forKey: DeviceContextProvider.enabledKey) as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(contextEnabled, forKey: DeviceContextProvider.enabledKey)
            if contextEnabled, connectionState != .disconnected {
                contextProvider.start()
            } else if !contextEnabled {
                contextProvider.stop()
            }
        }
    }
    /// Include exact coordinates (vs area name only)
    var contextPreciseLocation: Bool =
        (UserDefaults.standard.object(forKey: DeviceContextProvider.preciseKey) as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(
                contextPreciseLocation, forKey: DeviceContextProvider.preciseKey
            )
        }
    }
    /// Live context line for the Settings preview
    var contextPreview: String? {
        contextProvider.contextLine()
    }
    /// Mirror of the display manager's status for SwiftUI
    var displayStatus: DisplayHUDStatus = .off
    /// Selected direct-mode provider id (drives Settings + status chip)
    var directProviderID: String = UserDefaults.standard.string(forKey: "direct_provider_id") ?? "anthropic" {
        didSet {
            UserDefaults.standard.set(directProviderID, forKey: "direct_provider_id")
            reloadDirectProviderState()
        }
    }
    /// Model id for the current provider; applies from the next question
    var directModel: String = "" {
        didSet { UserDefaults.standard.set(directModel, forKey: "direct_model_\(directProviderID)") }
    }
    /// Custom base URL for providers that allow one (OpenAI-compatible / Ollama)
    var directBaseURL: String = "" {
        didSet { UserDefaults.standard.set(directBaseURL, forKey: "direct_base_url_\(directProviderID)") }
    }
    /// Whether the current provider has a key stored (drives Settings UI state)
    var hasDirectKey: Bool = false

    /// Reload model / base URL / key status when the provider changes.
    func reloadDirectProviderState() {
        let provider = DirectClient.provider
        directModel = DirectClient.model(for: provider)
        directBaseURL = provider.allowsCustomBaseURL ? DirectClient.baseURL(for: provider) : ""
        hasDirectKey = DirectClient.hasKey(for: provider.id)
    }

    /// The current direct-mode provider (for labels + capability checks)
    var directProvider: AIProvider { DirectClient.provider }
    var lastTranscript: String = ""
    var lastResponse: String = ""
    var conversationHistory: [ConversationTurn] = []
    var showError: Bool = false
    var errorMessage: String = ""
    /// Advisories that are NOT failures: a fallback that worked, a HUD that
    /// had to step aside. They went through `showError`, whose alert is
    /// titled "Hermes Error" - which told the user that using the iPhone mic
    /// instead of an absent headset was something that had gone wrong.
    var showNotice: Bool = false
    var noticeMessage: String = ""


    // MARK: - Constants

    /// How long the speaker's tail is given to fade before the recognizer
    /// listens again. There is no echo cancellation on the phone route (the
    /// audio session runs in `.default`, not `.voiceChat`), so a shorter
    /// wait means transcribing the end of Hermes's own reply.
    private static let speechResumeGraceNanos: UInt64 = 700_000_000

    /// Both mic fallbacks are announced from two places - session start and
    /// a mid-session switch - and must say the same thing in both.
    private static let glassesMicFallbackNotice =
        "Glasses mic not available - using iPhone mic"
    private static let headsetMicFallbackNotice =
        "No headset mic found - using iPhone mic. Connect AirPods or another Bluetooth headset first."

    private static let micSourceKey = "mic_source"

    // MARK: - Private

    // Internal, not private: the +Glasses / +Developer extensions use it.
    @ObservationIgnored let wearables: WearablesInterface
    // Internal, not private: the +Glasses / +Developer extensions use it.
    @ObservationIgnored var deviceSelector: AutoDeviceSelector
    // Internal, not private: the +Glasses / +Developer extensions use it.
    @ObservationIgnored var deviceSession: DeviceSession?
    // Internal, not private: the +Glasses / +Developer extensions use it.
    @ObservationIgnored let audioManager = HermesAudioManager()
    // Internal, not private: the +Glasses / +Developer extensions use it.
    @ObservationIgnored var sessionObserverTask: Task<Void, Never>?
    // Internal, not private: the +Glasses / +Developer extensions use it.
    @ObservationIgnored let cameraManager = HermesCameraManager()
    @ObservationIgnored private let phoneCameraManager = PhoneCameraManager()
    @ObservationIgnored private let speechRecognizer = HermesSpeechRecognizer()
    @ObservationIgnored private let speechSynthesizer = HermesSpeechSynthesizer()
    @ObservationIgnored private let directClient = DirectClient()
    // Internal, not private: the +Glasses / +Developer extensions use it.
    @ObservationIgnored let displayManager = HermesDisplayManager()
    @ObservationIgnored private let contextProvider = DeviceContextProvider()
    // Internal, not private: the +Glasses / +Developer extensions use it.
    @ObservationIgnored var pendingPhoto: Data?
    /// Last photo sent in Direct mode, reused only when a fresh capture fails.
    @ObservationIgnored private var lastDirectPhoto: Data?
    @ObservationIgnored private var lastDirectPhotoAt: Date?
    /// Camera-only session owned by the Lens view (nil while the voice
    /// session provides the camera, or when Lens is closed).
    // Internal, not private: the +Glasses / +Developer extensions use it.
    @ObservationIgnored var lensSession: DeviceSession?

    /// Resumed by the first reply (or error) that follows a test's query.
    // Internal, not private: the +Glasses / +Developer extensions use it.
    @ObservationIgnored
    var pendingTestOutcome: CheckedContinuation<Void, Error>?

    // Internal, not private: the +Glasses / +Developer extensions use it.
    @ObservationIgnored var askedForCameraGrant = false

    /// Exposed for UI to show audio route
    var audio: HermesAudioManager { audioManager }

    /// The glasses camera specifically - only for code that needs the DAT
    /// lifecycle (session configure/reset). Everything that just wants to
    /// SEE should use `vision`.
    var camera: HermesCameraManager { cameraManager }

    /// The iPhone camera, for the phone-mode screen's status tiles.
    var phoneCamera: PhoneCameraManager { phoneCameraManager }

    /// The camera EmoDrink sees through: the Ray-Ban, or the iPhone in phone mode.
    var vision: VisionSource {
        visionRoute == .phone ? phoneCameraManager : cameraManager
    }

    /// Pinned once a session (or the Lens view) commits to an eye, so a
    /// momentary SDK flap cannot redirect a capture to a camera that isn't
    /// running - the bug behind "remember this person" saving a note with no
    /// photo.
    @ObservationIgnored private var pinnedVisionRoute: VisionRoute?

    /// Which eye is in use, or would be if a session started now.
    var visionRoute: VisionRoute {
        pinnedVisionRoute ?? VisionRouting.route(
            glassesEligible: glassesAvailable, preference: phoneModePreference
        )
    }

    /// False only when the fallback is off and no glasses are reachable.
    var canStartSession: Bool {
        VisionRouting.canStartSession(
            glassesEligible: glassesAvailable, preference: phoneModePreference
        )
    }

    /// Is there an eye at all right now? The iPhone camera is always
    /// present; the glasses need a live session.
    var hasVisionSource: Bool {
        visionRoute == .phone || isGlassesConnected
    }

    /// Permission for whichever eye is active. These are two different
    /// grants from two different places - the glasses camera is authorised
    /// through the Meta AI companion app, the iPhone camera through iOS - so
    /// asking the glasses authority about a phone-mode capture always said
    /// no. That is why "remember this person" saved a note with no photo.
    func ensureVisionPermission(interactive: Bool) async -> Bool {
        switch visionRoute {
        case .glasses:
            return await ensureCameraPermission(interactive: interactive)
        case .phone:
            return interactive
                ? await PhoneCameraManager.ensurePermission()
                : PhoneCameraManager.isAuthorized
        }
    }

    /// A still from the active eye, falling back to the other one rather
    /// than returning nothing. "remember this person" saved a note with no
    /// photo because a transient route flip sent the capture to a camera
    /// that wasn't running; a photo from the wrong-but-working camera beats
    /// no photo at all.
    func captureVisionPhoto() async throws -> Data {
        do {
            return try await vision.capturePhoto()
        } catch {
            NSLog("[Hermes] \(visionRoute) capture failed: \(error.localizedDescription)")
            guard VisionRouting.mayFallBackToPhone(preference: phoneModePreference)
            else { throw error }
            switch visionRoute {
            case .glasses:
                NSLog("[Hermes] falling back to the iPhone camera for this photo")
                do {
                    return try await phoneCameraManager.capturePhoto()
                } catch {
                    NSLog("[Hermes] iPhone fallback photo ALSO failed - \(error.localizedDescription)")
                    throw error
                }
            case .phone:
                // The phone was the route and it failed; the glasses can only
                // help if a session is actually up.
                guard deviceSession != nil || lensSession != nil else { throw error }
                return try await cameraManager.capturePhoto()
            }
        }
    }

    /// Commit to an eye and hold it until `unpinVisionRoute()`.
    func pinVisionRoute(_ route: VisionRoute) { pinnedVisionRoute = route }

    func unpinVisionRoute() { pinnedVisionRoute = nil }

    /// Mirrors `AutoDeviceSelector.activeDevice`, which lives on an SDK
    /// object and is therefore invisible to SwiftUI's observation. Reading
    /// it directly meant the launch screen rendered once while the SDK was
    /// still discovering, saw nil, and never re-read - so the glasses looked
    /// unreachable until some *other* state change forced a redraw (toggling
    /// the eye to Phone and back, which is exactly how this was spotted).
    private(set) var activeGlassesDevice: DeviceIdentifier?

    @ObservationIgnored private var activeDeviceTask: Task<Void, Never>?

    /// A Meta device the SDK can open a session on right now.
    var glassesAvailable: Bool { activeGlassesDevice != nil }

    /// Everything the SDK will tell us about eligibility, in one line, so a
    /// device log shows WHY a route was chosen. Diagnostic only.
    var visionDiagnostics: String {
        let links = wearables.devices.map { id -> String in
            guard let device = wearables.deviceForIdentifier(id) else { return "?" }
            return "\(device.nameOrId())=\(device.linkState)"
        }.joined(separator: ",")
        return """
        VISIONDIAG registration=\(wearables.registrationState) \
        devices=\(wearables.devices.count) [\(links)] \
        activeDevice=\(activeGlassesDevice ?? "nil") \
        glassesAvailable=\(glassesAvailable) route=\(visionRoute) \
        pref=\(phoneModePreference.rawValue) phoneModeActive=\(phoneModeActive) \
        voiceSession=\(deviceSession != nil) lensSession=\(lensSession != nil) \
        connection=\(connectionState) mic=\(micSource.rawValue) \
        display=\(displayStatus) hudEnabled=\(displayHUDEnabled) \
        glassesStreaming=\(cameraManager.isStreaming)
        """
    }

    func logVisionDiagnostics(_ context: String) {
        NSLog("[Hermes] \(context) \(visionDiagnostics)")
    }

    /// True while a phone-mode session is running - drives the 5b screen.
    var phoneModeActive: Bool = false

    /// Set when the phone camera could not start (permission, hardware).
    /// The session still runs; only visual queries are affected.
    var phoneCameraError: String?

    /// Latest phone-camera frame, for the 5b feed.
    var phoneFeedImage: UIImage?

    /// Extra consumers of the running phone-mode stream, keyed so the Lens
    /// screen and conversation capture can both watch without clobbering
    /// each other. iOS gives one AVCaptureSession per camera, so a second
    /// consumer must share rather than start its own.
    @ObservationIgnored private var visionFrameObservers:
        [String: (VisionFrame) -> Void] = [:]

    func addVisionFrameObserver(
        _ key: String, _ handler: @escaping (VisionFrame) -> Void
    ) {
        visionFrameObservers[key] = handler
    }

    func removeVisionFrameObserver(_ key: String) {
        visionFrameObservers.removeValue(forKey: key)
    }

    /// True when a shared stream is already running, so a would-be consumer
    /// should observe it instead of calling `startLiveStream`.
    var visionStreamIsShared: Bool {
        visionRoute == .phone && phoneModeActive
    }

    /// Mirrors `displayManager.content` so SwiftUI can render the simulated
    /// lens. Updated even with no glasses attached.
    var lensContent: LensContent = .blank

    /// Auto / Always / Off (design 5a). Auto is the fallback the session
    /// screen relies on.
    var phoneModePreference: PhoneModePreference = PhoneModePreference(
        rawValue: UserDefaults.standard.string(forKey: PhoneModePreference.storageKey) ?? ""
    ) ?? .auto {
        didSet {
            UserDefaults.standard.set(
                phoneModePreference.rawValue, forKey: PhoneModePreference.storageKey
            )
        }
    }


    init(wearables: WearablesInterface) {
        self.wearables = wearables
        self.deviceSelector = AutoDeviceSelector(wearables: wearables)
        self.activeGlassesDevice = self.deviceSelector.activeDevice
        reloadDirectProviderState()
        observeActiveDevice()
        // Wired at init, NOT at session start: lens callbacks must exist
        // before any session does (see CLAUDE.md, display callbacks).
        wireDisplay()
        applyLanguage()
    }

    deinit {
        sessionObserverTask?.cancel()
        activeDeviceTask?.cancel()
    }

    /// Keep `activeGlassesDevice` live. Eligibility changes whenever the
    /// glasses wake, sleep, or wander out of Bluetooth range, and every one
    /// of those must reach the UI without the user poking something.
    private func observeActiveDevice() {
        let stream = deviceSelector.activeDeviceStream()
        activeDeviceTask = Task { [weak self] in
            for await device in stream {
                guard let self, !Task.isCancelled else { return }
                if self.activeGlassesDevice != device {
                    self.activeGlassesDevice = device
                    NSLog("[Hermes] activeDevice → \(device ?? "nil")")
                    // Glasses just became usable - re-check the camera grant
                    // so the warning under the toggle is true rather than
                    // whatever was cached at launch.
                    if device != nil {
                        await self.refreshGlassesCameraStatus()
                    }
                }
            }
        }
    }

    // MARK: - Public API

    /// Resolve the EmoDrink language setting into a recognizer locale and a
    /// voice. Falls back to English, with a notice, when Japanese speech
    /// recognition is unavailable; falls back to an English voice when no
    /// ja-JP voice is installed. Runs only while the recognizer is stopped:
    /// at init, at session start (state `.connecting`, before
    /// `speechRecognizer.start()`), and from Settings with no session. A
    /// change made mid-session applies from the next session. The
    /// recognizer always ends up in the voice's language, so the session
    /// never hears one language and speaks another. Only the session-start
    /// call (`announceFallback`) shows the STT fallback notice.
    @discardableResult
    func applyLanguage(announceFallback: Bool = false) -> Language {
        guard connectionState == .disconnected || connectionState == .connecting else { return activeLanguage }
        var language = EmoDrinkLanguage.resolved
        if !speechRecognizer.setLocale(language.sttLocale) {
            if language == .ja && announceFallback { show(notice: EmoDrinkLanguage.sttFallbackNotice) }
            language = .en
            speechRecognizer.setLocale(Language.en.sttLocale)
        }
        let voice = speechSynthesizer.configure(for: language)
        if voice.language != language {
            // A ja recognizer but no ja voice: hear what we speak.
            speechRecognizer.setLocale(voice.language.sttLocale)
        }
        activeLanguage = voice.language
        voiceNeedsInstallHint = voice.needsHint
        voiceName = voice.voiceName
        return activeLanguage
    }

    func startSession() async {
        await startSession(engagingBrain: true)
    }

    private func startSession(engagingBrain: Bool) async {
        // The voice session owns the glasses from here on - a Lens-created
        // camera session must not compete with it. (UI-wise Lens can't be
        // open when this button is reachable; this is belt-and-braces.)
        releaseCameraSession()

        connectionState = .connecting

        logVisionDiagnostics("startSession")
        var route = visionRoute

        if route == .glasses, await connectGlassesSession() == false {
            // Eligibility can lapse between the check and the start, and the
            // SDK is the only one who knows. Rather than leaving the user at
            // "No eligible device available" with no way forward, drop to the
            // phone - unless they explicitly turned that off.
            guard VisionRouting.mayFallBackToPhone(preference: phoneModePreference) else {
                connectionState = .disconnected
                return
            }
            show(notice: "Glasses unreachable - using this iPhone as the eye.")
            route = .phone
        }

        pinVisionRoute(route)
        phoneModeActive = route == .phone

        if route == .phone {
            // No DeviceSession, no display attach - the phone is the eye and
            // the lens is simulated on screen (design 5b).
            await startPhoneVision()
        }

        // Personal context (time/location/motion/battery/weather) -
        // requests location permission on first use
        contextProvider.start()

        // 2. Check the brain: the provider needs a key. A recording-only
        // session skips this: nothing it captures is ever sent anywhere.
        if engagingBrain {
            guard !directProvider.requiresKey || DirectClient.hasKey(for: directProvider.id) else {
                show("No API key set for \(directProvider.displayName). Add one in Settings.")
                endSession()
                return
            }
        }

        applyLanguage(announceFallback: true)
        let speechOK = await speechRecognizer.requestAuthorization()
        if !speechOK {
            show(HermesSpeechError.notAuthorized.localizedDescription)
        }

        audioManager.onRawBuffer = { [weak self] buffer in
            self?.speechRecognizer.append(buffer)
        }
        audioManager.onLevel = { [weak self] level in
            self?.micLevel = level
        }
        audioManager.onPlaybackComplete = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.displayManager.replySpeakingFinished()
                if case .speaking = self.connectionState {
                    self.connectionState = .listening
                }
                // Grace period: let the speaker's tail fade before the mic
                // listens again, or the recognizer hears the end of the TTS
                try? await Task.sleep(nanoseconds: Self.speechResumeGraceNanos)
                self.speechRecognizer.isSuspended = false
            }
        }

        // On-device TTS finished (or was interrupted) - same completion
        // flow as audio playback
        speechSynthesizer.onFinished = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A queued cue speaks next with the recognizer still
                // suspended: state stays .speaking, no grace gap in between.
                if case .speaking = self.connectionState, !self.cueQueue.isEmpty {
                    self.speechSynthesizer.speak(self.cueQueue.removeFirst())
                    return
                }
                self.displayManager.replySpeakingFinished()
                if case .speaking = self.connectionState {
                    self.connectionState = .listening
                }
                try? await Task.sleep(nanoseconds: Self.speechResumeGraceNanos)
                // A cue that started during the grace owns the suspension.
                if case .speaking = self.connectionState { return }
                self.speechRecognizer.isSuspended = false
            }
        }

        speechRecognizer.onPartial = { [weak self] text in
            guard let self else { return }
            if case .speaking = self.connectionState {
                // Words while Hermes talks = barge-in, unless the glasses
                // are hearing Hermes's own voice
                guard !self.isEchoOfResponse(text) else { return }
                self.liveTranscript = text
                self.displayManager.showListening(partial: text)
                if text.split(separator: " ").count >= 2 {
                    self.interruptSpeech()
                }
            } else {
                self.liveTranscript = text
                // A late partial can trail the finalized utterance - don't
                // let it overwrite the Thinking screen on the lens
                switch self.connectionState {
                case .listening, .recording:
                    self.displayManager.showListening(partial: text)
                default:
                    break
                }
            }
        }
        speechRecognizer.onFinal = { [weak self] text in
            self?.submitQuery(text)
        }

        audioManager.onRouteChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.speechRecognizer.restartCycle()
            }
        }

        do {
            let bluetoothActive = try await audioManager.startCapture(route: micSource.captureRoute)
            if micSource == .glasses && !bluetoothActive { show(notice: Self.glassesMicFallbackNotice) }
            if micSource == .headset && !bluetoothActive { show(notice: Self.headsetMicFallbackNotice) }
            if speechOK { try speechRecognizer.start() }
        } catch {
            show("Audio setup failed: \(error.localizedDescription)")
            endSession()
            return
        }

        // Attach the lens HUD only when the mic route leaves the lens
        // free - the GLASSES' hands-free link brings up their call screen
        // (a headset's hands-free link does not). In phone mode there is no
        // DeviceSession to attach to; the simulated lens reads
        // `displayManager.content` instead, which updates either way.
        if let session = deviceSession,
           displayHUDEnabled, !lensBlockedByCallScreen {
            // stop() first: a standalone Display test may still hold an
            // attachment to its temporary session
            displayManager.stop()
            displayManager.start(session: session)
        }

        // Mic live, recognizer running
        connectionState = .listening
    }

    /// Send finalized text to the active brain and move the UI into processing
    func submitQuery(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // While a drink is on the lens its replies (why, a choice, thanks)
        // are claimed first and never reach the assistant.
        if let claim = emoDrinkClaimer, claim(trimmed) {
            liveTranscript = ""
            lastTranscript = trimmed
            completeTestOutcome(.failure(TestFailure(
                "EmoDrink claimed this utterance as a reply - say thanks to end the drink moment before running this test."
            )))
            return
        }

        let intent = IntentDetector.detect(trimmed)
        if intent != .none {
            liveTranscript = ""
            lastTranscript = trimmed
            onEmoDrinkIntent?(intent)
            return
        }

        let context = contextProvider.contextLine()
        liveTranscript = ""
        lastTranscript = trimmed
        connectionState = .processing
        displayManager.showThinking(query: trimmed)
        speechRecognizer.isSuspended = true
        Task { await askDirect(trimmed, context: context) }
    }

    /// Direct mode: photo decision + capture happen locally, then one
    /// API call - no server round trips.
    private func askDirect(_ text: String, context: String? = nil) async {
        var photo: Data?
        // A visual query always gets a FRESH photo: the model's history is
        // text-only, so the memory window that skipped a re-shoot left the
        // model blind ("I can't see a photo") for any deictic question asked
        // within two minutes of the last one. The window now only decides
        // whether a failed capture may fall back to the previous photo.
        if VisualQueryDetector.shouldCapturePhoto(text, lastPhotoAt: nil),
           hasVisionSource,
           await ensureVisionPermission(interactive: false) {
            displayManager.showPhotoCaptured()
            photo = try? await captureVisionPhoto()
            if photo != nil {
                lastDirectPhotoAt = Date()
                lastDirectPhoto = photo
                pendingPhoto = photo
            } else if let recent = lastDirectPhoto, let at = lastDirectPhotoAt,
                      Date().timeIntervalSince(at) <= VisualQueryDetector.photoMemoryWindow {
                photo = recent
            }
        }

        do {
            let reply = try await directClient.ask(text, photoJPEG: photo, contextLine: context)
            lastResponse = reply
            addTurn(userText: text, agentText: reply)
            completeTestOutcome(.success(()))
            presentReply(reply)
        } catch {
            show(error.localizedDescription)
            connectionState = .listening
            speechRecognizer.isSuspended = false
            displayManager.clear()
        }
    }

    /// Store/replace the API key for the current provider (Keychain)
    func setProviderKey(_ key: String) {
        let stored = DirectClient.storeKey(key, for: directProviderID)
        // hasKey re-reads the Keychain, so the badge reflects what is
        // actually there - but a silent failure needs saying out loud.
        hasDirectKey = DirectClient.hasKey(for: directProviderID)
        if !stored, !hasDirectKey {
            show("Could not save the API key to the Keychain.")
        }
    }

    /// "Send now" button - don't wait for the pause detection
    func sendNow() {
        speechRecognizer.finalizeNow()
    }

    /// Answer a multiple-choice reply by picking one of its options. Sent
    /// as the option's words, so the transcript reads like a conversation
    /// rather than a row of letters.
    func chooseReplyOption(_ choice: ReplyChoice) {
        interruptSpeech()
        submitQuery(choice.reply)
    }

    /// The options offered by the most recent reply, if any - drives the
    /// chips under the last bubble.
    var replyChoices: [ReplyChoice] {
        lensContent.choices
    }

    /// Forget the conversation: clears the on-device history immediately.
    func startNewConversation() {
        DirectClient.clearHistory()
        conversationHistory.removeAll()
        lastTranscript = ""
        lastResponse = ""
        liveTranscript = ""
        displayManager.showNewConversationFlash()
    }

    /// Cut Hermes off mid-reply (tap on the speaking indicator, or voice
    /// barge-in in glasses mode). stopPlayback fires onPlaybackComplete,
    /// which returns the state machine to listening.
    func interruptSpeech() {
        guard case .speaking = connectionState else { return }
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stop()
        } else {
            audioManager.stopPlayback()
        }
    }

    /// Silent mode is only honored while the lens can actually show text.
    private var displaySilentActive: Bool {
        displaySilentMode && displayStatus == .connected
    }

    /// Single reply path for both brains: lens card + (unless silent) TTS.
    private func presentReply(_ text: String) {
        let shown = HermesDisplayLogic.truncateReply(text)
        if displaySilentActive {
            displayManager.showReply(text: shown, speaking: false,
                                     dwellSeconds: HermesDisplayLogic.readingDwellSeconds(charCount: shown.count))
            connectionState = .listening
            speechRecognizer.isSuspended = false
        } else {
            connectionState = .speaking
            displayManager.showReply(text: shown, speaking: true, dwellSeconds: nil)
            speechSynthesizer.speak(text)
            // Bluetooth mic: the speaker is not the mic, so keep listening.
            if audioManager.isUsingBluetoothInput { speechRecognizer.isSuspended = false }
        }
    }

    /// Step 1 for the phone route: start the iPhone camera stream that both
    /// the 5b feed and every visual query read from. A failure here is not
    /// fatal - the voice loop is the valuable half.
    private func startPhoneVision() async {
        phoneCameraError = nil
        // One AVCaptureSession, possibly two consumers: the 5b feed always,
        // plus the Lens screen while it is open (see onVisionFrame). Starting
        // a second capture session for Lens would fail - the camera is taken.
        do {
            try await phoneCameraManager.startLiveStream(
                onFrame: { [weak self] frame in
                    Task { @MainActor [weak self] in
                        guard let self, self.phoneModeActive else { return }
                        if let image = frame.image { self.phoneFeedImage = image }
                        for observe in self.visionFrameObservers.values {
                            observe(frame)
                        }
                    }
                },
                onError: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.phoneCameraError = message
                    }
                }
            )
        } catch {
            phoneCameraError = error.localizedDescription
        }
    }

    /// Back from the background in phone mode: the iPhone camera stream
    /// stopped while the app was hidden, so start it again.
    func resumePhoneVisionIfNeeded() async {
        guard phoneModeActive, !phoneCameraManager.isStreaming else { return }
        await startPhoneVision()
    }

    /// Display-HUD callbacks. Wired for BOTH routes: in phone
    /// mode nothing goes out over BLE, but `displayManager.content` still
    /// updates, which is what the simulated lens renders.
    private func wireDisplay() {
        displayManager.onContentChanged = { [weak self] content in self?.lensContent = content }
        lensContent = displayManager.content
        displayManager.onDebug = { message in NSLog("[EmoDrink] display: \(message)") }
        displayManager.onStatusChanged = { [weak self] newStatus in self?.displayStatus = newStatus }
        displayManager.onStop = { [weak self] in self?.interruptSpeech() }
        displayManager.onRepeat = { [weak self] in self?.repeatLastReply() }
        displayManager.onNewChat = { [weak self] in
            guard let self else { return }
            self.startNewConversation()
            self.displayManager.showNewConversationFlash()
        }
        displayManager.onChooseReplyOption = { [weak self] choice in self?.chooseReplyOption(choice) }
        // After a reply's dwell, EmoDrink restores its card or the watching
        // screen; otherwise the lens blanks.
        displayManager.idleHandler = { [weak self] in
            guard let self else { return }
            if self.emoDrinkLensIdle?() != true { self.displayManager.clear() }
        }
    }

    /// On-lens Repeat button: re-speak (or re-show, in silent mode).
    func repeatLastReply() {
        guard !lastResponse.isEmpty else { return }
        if case .speaking = connectionState { return }
        presentReply(lastResponse)
    }

    /// True when a partial heard during .speaking is (part of) Hermes's own
    /// spoken words leaking into the mic, rather than the user talking.
    private func isEchoOfResponse(_ partial: String) -> Bool {
        func normalize(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
                .trimmingCharacters(in: .whitespaces)
        }
        let heard = normalize(partial)
        guard !heard.isEmpty else { return true }
        // Heuristic: if what we heard appears verbatim in the response,
        // assume it's echo. A user genuinely quoting Hermes back loses -
        // acceptable trade-off.
        return normalize(lastResponse).contains(heard)
    }

    /// The glasses' hands-free mic makes the glasses show their call screen,
    /// which covers the lens.
    var lensBlockedByCallScreen: Bool {
        micSource == .glasses && audioManager.isUsingBluetoothInput
    }

    var availableMicSources: [MicSource] { MicSource.allCases }

    /// Next source that actually takes; HFP ports only appear once the
    /// session is active, so the cycle tries each in turn.
    func toggleMicSource() async {
        let all = availableMicSources
        let start = all.firstIndex(of: micSource) ?? 0
        for step in 1...all.count {
            switch await switchMicSource(all[(start + step) % all.count], announceFallback: false) {
            case .took, .sessionEnded: return
            case .routeUnavailable: continue
            }
        }
    }

    private enum MicSwitchOutcome { case took, routeUnavailable, sessionEnded }

    @discardableResult
    func setMicSource(_ target: MicSource, announceFallback: Bool = true) async -> Bool {
        await switchMicSource(target, announceFallback: announceFallback) == .took
    }

    private func switchMicSource(_ target: MicSource, announceFallback: Bool) async -> MicSwitchOutcome {
        micSource = target
        UserDefaults.standard.set(target.rawValue, forKey: Self.micSourceKey)
        guard connectionState != .disconnected else { return .took }
        audioManager.stopCapture()
        do {
            let bluetoothActive = try await audioManager.startCapture(route: target.captureRoute)
            let outcome: MicSwitchOutcome = (bluetoothActive || target == .phone) ? .took : .routeUnavailable
            speechRecognizer.restartCycle()
            if announceFallback, target == .glasses, !bluetoothActive { show(notice: Self.glassesMicFallbackNotice) }
            if announceFallback, target == .headset, !bluetoothActive { show(notice: Self.headsetMicFallbackNotice) }
            if outcome == .routeUnavailable {
                micSource = .phone
                UserDefaults.standard.set(MicSource.phone.rawValue, forKey: Self.micSourceKey)
            }
            reconcileLensHUD()
            return outcome
        } catch {
            show("Mic switch failed: \(error.localizedDescription)")
            endSession()
            return .sessionEnded
        }
    }

    /// HUD ⇄ GLASSES hands-free mic are mutually exclusive: the glasses show
    /// their call screen while their hands-free link is active. Headset mode
    /// leaves the lens free.
    ///
    /// Runs on EVERY exit from a mic switch, and reads `micSource` AFTER any
    /// fallback - a failed switch away from the glasses mic leaves the iPhone
    /// mic live, and the HUD must come back with it. Skipping it once stranded
    /// the lens off with no recovery but toggling the HUD setting.
    private func reconcileLensHUD() {
        guard displayHUDEnabled, let session = deviceSession else { return }
        if lensBlockedByCallScreen {
            displayManager.stop()
            show(notice: "Lens HUD paused - the glasses show their call screen while their hands-free mic is on. The iPhone or a headset mic keeps the HUD visible.")
        } else if displayManager.status == .off {
            displayManager.start(session: session)
        }
    }

    /// A short spoken confirmation. With the voice loop listening, the
    /// recognizer is suspended first (onFinished resumes it) so Hermes
    /// doesn't transcribe its own cue; mid-answer, the cue is skipped.
    func speakCue(_ text: String) {
        switch connectionState {
        case .listening:
            connectionState = .speaking
            speechRecognizer.isSuspended = true
            speechSynthesizer.speak(text)
        case .disconnected:
            speechSynthesizer.speak(text)
        default:
            break
        }
    }

    /// Build Check's form: while another cue is speaking the line waits its
    /// turn (FIFO, drained by onFinished) instead of being dropped - a run's
    /// warnings and step prompts must all be heard.
    func speakCue(_ text: String, queued: Bool) {
        if queued, case .speaking = connectionState {
            cueQueue.append(text)
            return
        }
        speakCue(text)
    }

    /// A notice on the main screen (the non-fault banner).
    func showNoticeMessage(_ message: String) {
        show(notice: message)
    }

    // MARK: EmoDrink surface

    func setPersonaOverride(_ prompt: String?) {
        directClient.systemPromptOverride = prompt
    }

    func showEmoDrinkOnLens(title: String, subtitle: String, reason: String, source: String, choices: [ReplyChoice]) {
        displayManager.showEmoDrink(title: title, subtitle: subtitle, reason: reason, source: source, choices: choices)
    }

    func showEmoDrinkWatchingOnLens() {
        let t = EmoDrinkStrings(language: activeLanguage)
        displayManager.showEmoDrinkWatching(heading: t.watchingHeading, text: t.watchingText, hint: t.watchingHint)
    }

    func showEmoDrinkChoicesOnLens(heading: String, options: [LensDrinkOption], source: String) {
        displayManager.showEmoDrinkChoices(heading: heading, options: options, source: source)
    }

    func clearLens() {
        displayManager.clear()
    }

    /// A question for the active persona. Skips the claimers (it was built
    /// from a claimed "why"), otherwise the normal query path.
    func askPersona(_ text: String) {
        let savedClaimer = emoDrinkClaimer
        emoDrinkClaimer = nil
        defer { emoDrinkClaimer = savedClaimer }
        submitQuery(text)
    }

    func endSession() {
        let emoEnding = onEmoDrinkSessionEnding
        onEmoDrinkSessionEnding = nil
        emoEnding?()
        sessionObserverTask?.cancel()
        sessionObserverTask = nil
        cueQueue.removeAll()
        speechSynthesizer.stop()
        speechRecognizer.stop()
        displayManager.stop()
        displayStatus = .off
        contextProvider.stop()
        liveTranscript = ""
        micLevel = 0
        audioManager.stopCapture()
        cameraManager.reset()
        phoneCameraManager.stopLiveStream()
        unpinVisionRoute()
        phoneModeActive = false
        phoneFeedImage = nil
        phoneCameraError = nil
        lensContent = .blank
        pendingPhoto = nil
        deviceSession?.stop()
        deviceSession = nil
        isGlassesConnected = false
        connectionState = .disconnected
    }

    func dismissError() {
        showError = false
    }

    func dismissNotice() {
        showNotice = false
    }

    // MARK: - Private

    // Internal, not private: the +Glasses / +Developer extensions use it.
    func addTurn(userText: String, agentText: String) {
        let turn = ConversationTurn(
            userText: userText,
            agentText: agentText,
            timestamp: Date(),
            photo: pendingPhoto,
            photoSource: pendingPhoto == nil ? nil : vision.sourceLabel
        )
        pendingPhoto = nil
        conversationHistory.append(turn)
        if conversationHistory.count > 50 {
            conversationHistory.removeFirst()
        }
        lastTranscript = ""
    }

    // Internal, not private: the +Glasses / +Developer extensions use it.
    func show(_ message: String) {
        errorMessage = message
        showError = true
        // A test waiting on a round trip has just learnt its outcome: this
        // is the only path every brain's failures share.
        completeTestOutcome(.failure(TestFailure(message)))
    }

    /// The same surface for something that merely happened, phrased as news
    /// rather than as a fault.
    private func show(notice message: String) {
        noticeMessage = message
        showNotice = true
    }
}
