//
// EmoDrinkViewModel.swift
//
// Runs EmoDrink. Owned by the App struct so drink mode keeps watching with
// the phone in a pocket. Borrows mic, camera, speech and lens from
// HermesSessionViewModel through its EmoDrink hooks.
//
// The MOMENT has two steps. A (choices): three drinks on the lens as
// numbered buttons, one spoken sentence naming them. B (chosen): the drink
// the wearer tapped or said, its card with Why / Thanks, one warm spoken
// line. Saying another number or name in B switches drink; "back" shows the
// three again; "something else" offers the next three. Ends on thanks,
// stop, or 120 s of silence. DRINK MODE: every `intervalSeconds` the latest
// frame is feature-printed; VendingMachineGate decides whether to spend one
// vision call on "is there a vending machine"; YES starts a moment. "Check
// now" skips the change gate (never the budget). Every decision in between
// is pure and tested; this file only wires.
//

import AVFoundation
import Foundation
import Observation
import Speech
import UIKit
import Vision

@MainActor
@Observable
final class EmoDrinkViewModel {
    static let frameObserverKey = "emodrink"
    static let momentTimeout: TimeInterval = 120
    static let snapshotMaxAge: TimeInterval = 30 * 60
    static let firstLineTimeout: TimeInterval = 4
    static let detectTimeout: TimeInterval = 12
    static let noMachineSeconds: TimeInterval = 3
    static let optionCount = 3
    static let autoWatchKey = "emodrink_auto_watch"

    enum MomentStep: Equatable { case choices, chosen }
    /// One vision check's outcome. A failure is not a NO: Check now says so.
    enum VisionCheck: Equatable { case yes, no, failed(String) }

    // MARK: Settings (UserDefaults-backed)

    var sourceURLString: String = UserDefaults.standard.string(forKey: EmoDrinkDefaults.sourceURLKey) ?? EmoDrinkDefaults.defaultSourceURL {
        didSet { UserDefaults.standard.set(sourceURLString, forKey: EmoDrinkDefaults.sourceURLKey) }
    }
    var useMock: Bool = UserDefaults.standard.object(forKey: EmoDrinkDefaults.useMockKey) as? Bool ?? false {
        didSet { UserDefaults.standard.set(useMock, forKey: EmoDrinkDefaults.useMockKey) }
    }
    var mockProfile: MockProfile = MockProfile(rawValue: UserDefaults.standard.string(forKey: EmoDrinkDefaults.mockProfileKey) ?? "") ?? EmoDrinkDefaults.defaultMockProfile {
        didSet { UserDefaults.standard.set(mockProfile.rawValue, forKey: EmoDrinkDefaults.mockProfileKey) }
    }
    var lowSugar: Bool = UserDefaults.standard.object(forKey: EmoDrinkDefaults.lowSugarKey) as? Bool ?? false {
        didSet { UserDefaults.standard.set(lowSugar, forKey: EmoDrinkDefaults.lowSugarKey) }
    }
    /// Clamped on read (2...30); the Stepper enforces the same range.
    var intervalSeconds: Int = {
        let v = UserDefaults.standard.integer(forKey: EmoDrinkDefaults.intervalKey)
        return v == 0 ? EmoDrinkDefaults.defaultIntervalSeconds : min(30, max(2, v))
    }() {
        didSet { UserDefaults.standard.set(intervalSeconds, forKey: EmoDrinkDefaults.intervalKey) }
    }
    /// "Watch for vending machines when the app opens" (default on).
    var autoWatch: Bool = UserDefaults.standard.object(forKey: EmoDrinkViewModel.autoWatchKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoWatch, forKey: Self.autoWatchKey) }
    }

    // MARK: Observable state

    private(set) var catalog: DrinkCatalog?
    private(set) var cached: CachedSnapshot?
    /// "sample data: short night", "this morning's cached data (fetch failed)". Nil when live.
    private(set) var snapshotNotice: String?
    private(set) var recommendation: Recommendation?
    /// Nil when no moment is on the lens.
    private(set) var step: MomentStep?
    /// The three drinks offered in step A (fewer if the catalogue is smaller).
    private(set) var options: [Drink] = []
    /// The drink chosen in step B.
    private(set) var currentPick: Drink?
    private(set) var drinkModeOn = false
    private(set) var frameCount = 0
    private(set) var sentCount = 0
    private(set) var budgetUsed = 0
    private(set) var restingUntil: Date?
    private(set) var liveImage: UIImage?
    private(set) var fetching = false
    private(set) var checkingNow = false
    /// Check now's 3 s line on the home card: "No vending machine in view"
    /// after a NO, "Vision check failed" after an error, "Camera not ready
    /// yet" with no fresh frame, or the hour's budget spent.
    private(set) var noMachineNotice: String?
    /// Why the session could not start (no mic or speech permission).
    private(set) var sessionBlocked: String?
    var errorMessage: String?
    /// Why the AI was skipped, when it was ("no API key", a timeout, a
    /// failed vision check). The home card shows it under the idle line.
    private(set) var aiNotice: String?
    private(set) var currentSnapshot: PhysiologySnapshot?

    var hasCatalog: Bool { catalog != nil }
    var momentActive: Bool { step != nil }
    var language: Language { hermesVM.activeLanguage }
    var strings: EmoDrinkStrings { EmoDrinkStrings(language: language) }
    var sourceLine: String { snapshotNotice ?? currentSourceLabel }

    // MARK: Collaborators

    @ObservationIgnored private let hermesVM: HermesSessionViewModel
    @ObservationIgnored private let store = PhysiologyStore()
    /// One-shot vision and text calls that must not touch chat memory.
    @ObservationIgnored private let oneShot = DirectClient()

    // MARK: Loop state (not observed)

    @ObservationIgnored private var gate = VendingMachineGate()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var momentTimer: Task<Void, Never>?
    @ObservationIgnored private var noMachineTask: Task<Void, Never>?
    @ObservationIgnored private var streamStarted = false
    @ObservationIgnored private var startedSession = false
    @ObservationIgnored private var latestImage: UIImage?
    @ObservationIgnored private var latestImageAt: Date?
    @ObservationIgnored private var prevPrint: VNFeaturePrintObservation?
    @ObservationIgnored private var checkedPrint: VNFeaturePrintObservation?
    @ObservationIgnored private var checkInFlight = false
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var currentSourceLabel = ""
    /// Index into `recommendation.ranked` of the first offered drink.
    @ObservationIgnored private var offerOffset = 0
    /// The persona prompt of the moment on the lens, for "why".
    @ObservationIgnored private var currentPrompt: String?
    @ObservationIgnored private var cameraLostAnnounced = false
    @ObservationIgnored private var drinkModeStartedAt: Date?
    /// Phone camera in the background: frames stop, so do not call it lost.
    @ObservationIgnored private var pausedForBackground = false

    init(hermesVM: HermesSessionViewModel) {
        self.hermesVM = hermesVM
        catalog = DrinkCatalog.bundled()
        cached = store.load()
        if catalog == nil {
            assertionFailure("asahi-drinks.json is missing from the bundle")
            errorMessage = "The drink catalogue is missing from this build. Picks are disabled."
        }
        hermesVM.onEmoDrinkIntent = { [weak self] intent in self?.handleIntent(intent) }
        hermesVM.emoDrinkClaimer = { [weak self] text in self?.claim(text) ?? false }
        hermesVM.emoDrinkLensIdle = { [weak self] in
            guard let self else { return false }
            if self.momentActive { self.reshowMoment(); return true }
            if self.drinkModeOn { self.hermesVM.showEmoDrinkWatchingOnLens(); return true }
            return false
        }
    }

    // MARK: Start / stop (home screen, app open)

    /// Session first, then drink mode, always. Used by the Start button and
    /// by the home screen on appear; `autoWatch` gates only that on-appear
    /// call (in ContentView), never this.
    func start() async {
        // A Stop while the session starts must win: bail, do not watch.
        let gen = hermesVM.sessionGeneration
        if hermesVM.connectionState == .disconnected {
            await hermesVM.startSession()
            guard !hermesVM.stoppedSince(gen) else { return }
        }
        guard hermesVM.connectionState != .disconnected else {
            sessionBlocked = sessionFailureText()
            return
        }
        sessionBlocked = micDenied ? strings.micBlocked : nil
        await startDrinkMode()
    }

    /// Microphone or speech recognition refused. The session still reaches
    /// listening in that case, so this is read from the grants, not the state.
    private var micDenied: Bool {
        let speech = SFSpeechRecognizer.authorizationStatus()
        return AVAudioApplication.shared.recordPermission == .denied || speech == .denied || speech == .restricted
    }

    /// Why the session stayed disconnected: the mic line only when the mic
    /// is the reason, else what the session itself reported (a missing key,
    /// absent glasses), else a generic line.
    private func sessionFailureText() -> String {
        if micDenied { return strings.micBlocked }
        if hermesVM.showError, !hermesVM.errorMessage.isEmpty { return hermesVM.errorMessage }
        if hermesVM.showNotice, !hermesVM.noticeMessage.isEmpty { return hermesVM.noticeMessage }
        return strings.sessionDidNotStart
    }

    func stop() {
        stopDrinkMode()
        hermesVM.endSession()
    }

    // MARK: Snapshot

    /// The snapshot to pick from, in this order: mock profile when asked;
    /// today's cached data when fresh enough and not forced; a remote fetch;
    /// today's cached data as a fallback; the mock profile as the last
    /// resort. Sets `snapshotNotice` whenever the result is not live.
    @discardableResult
    func refreshSnapshot(force: Bool = false) async -> PhysiologySnapshot? {
        let now = Date()
        let today = EmoDrinkDay.string(for: now)

        if useMock {
            let snap = MockPhysiologySource(profile: mockProfile).profile.snapshot(date: today)
            snapshotNotice = "sample data: \(mockProfile.title.lowercased())"
            currentSnapshot = snap
            currentSourceLabel = snap.source
            return snap
        }

        if !force, let cached, now.timeIntervalSince(cached.fetchedAt) <= Self.snapshotMaxAge {
            snapshotNotice = cached.snapshot.isToday(today) ? nil : "feed dated \(cached.snapshot.date)"
            currentSnapshot = cached.snapshot
            currentSourceLabel = cached.sourceLabel
            return cached.snapshot
        }

        guard let source = RemoteJSONPhysiologySource(urlString: sourceURLString) else {
            return fallbackSnapshot(today: today, reason: "the feed URL is not valid")
        }
        fetching = true
        defer { fetching = false }
        do {
            let snap = try await source.fetch()
            let label = "\(snap.source), \(Self.clock.string(from: now))"
            let fresh = CachedSnapshot(snapshot: snap, fetchedAt: now, sourceLabel: label)
            try? store.save(fresh)
            cached = fresh
            snapshotNotice = snap.isToday(today) ? nil : "feed dated \(snap.date)"
            currentSnapshot = snap
            currentSourceLabel = label
            return snap
        } catch {
            return fallbackSnapshot(today: today, reason: Self.shortReason(error))
        }
    }

    private func fallbackSnapshot(today: String, reason: String) -> PhysiologySnapshot {
        if let cached, cached.snapshot.isToday(today) {
            snapshotNotice = "this morning's cached data (\(reason))"
            currentSnapshot = cached.snapshot
            currentSourceLabel = cached.sourceLabel
            return cached.snapshot
        }
        let snap = mockProfile.snapshot(date: today)
        snapshotNotice = "sample data: \(mockProfile.title.lowercased()) (\(reason))"
        currentSnapshot = snap
        currentSourceLabel = snap.source
        return snap
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    // MARK: Step A: three drinks

    /// Voice, button, or a detection all land here.
    func pickNow() async {
        guard let catalog else {
            fail("The drink catalogue is missing from this build.")
            return
        }
        guard let snapshot = await refreshSnapshot() else { return }
        let hour = Calendar.current.component(.hour, from: Date())
        guard let rec = DrinkRecommender.recommend(snapshot: snapshot, catalog: catalog, hour: hour,
                                                   lowSugar: lowSugar, language: language) else { return }
        recommendation = rec
        offerOffset = 0
        offerChoices(speakWithAI: true)
    }

    private func offerChoices(speakWithAI: Bool) {
        guard let rec = recommendation, let catalog, let snapshot = currentSnapshot, !rec.ranked.isEmpty else { return }
        let count = min(Self.optionCount, rec.ranked.count)
        options = (0..<count).map { rec.ranked[(offerOffset + $0) % rec.ranked.count] }
        currentPick = nil
        step = .choices
        if !drinkModeOn { hermesVM.onEmoDrinkSessionEnding = { [weak self] in self?.endMoment(saying: nil) } }
        let prompt = EmoDrinkPersona.systemPrompt(snapshot: snapshot, pick: options[0], recommendation: rec,
                                                  catalog: catalog, sourceLabel: currentSourceLabel, language: language)
        hermesVM.setPersonaOverride(prompt)
        currentPrompt = prompt
        showChoicesOnLens()
        resetMomentTimer()
        let fallback = strings.choicesLine(names: options.map(name))
        if speakWithAI {
            let offered = options
            Task { await speakAI(prompt: prompt, request: EmoDrinkPersona.choicesRequest(options: offered), fallback: fallback) {
                [weak self] in self?.step == .choices && self?.options == offered
            } }
        } else {
            say(fallback)
        }
    }

    private func showChoicesOnLens() {
        guard let rec = recommendation else { return }
        let lensOptions = options.map { LensDrinkOption(title: name($0), subtitle: otherName($0), reason: rec.reasonLine) }
        hermesVM.showEmoDrinkChoicesOnLens(heading: strings.choiceHeading, options: lensOptions, source: sourceLine)
    }

    // MARK: Step B: the chosen drink

    /// A tap on the home screen or the lens, or a number or name said aloud.
    func choose(_ index: Int) {
        guard momentActive, options.indices.contains(index), let rec = recommendation, let catalog,
              let snapshot = currentSnapshot else { return }
        let pick = options[index]
        currentPick = pick
        step = .chosen
        let prompt = EmoDrinkPersona.systemPrompt(snapshot: snapshot, pick: pick, recommendation: rec,
                                                  catalog: catalog, sourceLabel: currentSourceLabel, language: language)
        hermesVM.setPersonaOverride(prompt)
        currentPrompt = prompt
        showChosenOnLens()
        resetMomentTimer()
        let fallback = strings.chosenLine(name: name(pick), reasons: rec.reasons)
        Task { await speakAI(prompt: prompt, request: EmoDrinkPersona.chosenRequest(pick: pick, language: language), fallback: fallback) {
            [weak self] in self?.step == .chosen && self?.currentPick == pick
        } }
    }

    private func showChosenOnLens() {
        guard let pick = currentPick, let rec = recommendation else { return }
        hermesVM.showEmoDrinkOnLens(title: name(pick), subtitle: otherName(pick), reason: rec.reasonLine,
                                    source: sourceLine, choices: EmoDrinkCommands.cardChoices(for: language))
    }

    /// "back" / 「戻る」: the three again, spoken from the rules (no wait).
    func back() {
        guard momentActive else { return }
        offerChoices(speakWithAI: false)
    }

    /// "something else" / 「他には」: the next three in rank order.
    func somethingElse() {
        guard momentActive, let rec = recommendation else { return }
        offerOffset = (offerOffset + Self.optionCount) % max(rec.ranked.count, 1)
        offerChoices(speakWithAI: false)
    }

    /// Spoken only: the card stays on the lens. A one-shot call so the
    /// answer cannot replace the card; any failure speaks the rule reasons.
    func why() {
        guard momentActive, let rec = recommendation else { return }
        resetMomentTimer()
        let fallback = strings.whyLine(reasons: rec.reasons)
        guard hermesVM.hasDirectKey, let prompt = currentPrompt else {
            say(fallback)
            return
        }
        let stepAtAsk = step, pickAtAsk = currentPick
        Task {
            await speakAI(prompt: prompt, request: EmoDrinkPersona.whyQuestion, fallback: fallback, maxTokens: 120) {
                [weak self] in self?.step == stepAtAsk && self?.currentPick == pickAtAsk
            }
        }
    }

    func thanks() {
        guard momentActive else { return }
        endMoment(saying: strings.enjoy)
    }

    /// One AI-phrased line within the first-line timeout, else the fallback.
    /// `stillCurrent` drops the line when the wearer has moved on.
    private func speakAI(prompt: String, request: String, fallback: String, maxTokens: Int = 80,
                         stillCurrent: @escaping @MainActor () -> Bool) async {
        guard hermesVM.hasDirectKey else {
            aiNotice = "no API key, spoken from the rules"
            say(fallback)
            return
        }
        do {
            let line = try await oneShot.askOneShotText(systemPrompt: prompt, userText: request,
                                                        maxTokens: maxTokens, timeout: Self.firstLineTimeout)
            guard stillCurrent() else { return }
            aiNotice = nil
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            say(trimmed.isEmpty ? fallback : trimmed)
        } catch {
            guard stillCurrent() else { return }
            aiNotice = "AI line skipped: \(Self.shortReason(error))"
            say(fallback)
        }
    }

    /// Redraws the moment, e.g. when a reply's dwell ends.
    private func reshowMoment() {
        switch step {
        case .choices: showChoicesOnLens()
        case .chosen: showChosenOnLens()
        case nil: break
        }
    }

    private func endMoment(saying line: String?) {
        momentTimer?.cancel()
        momentTimer = nil
        guard momentActive else { return }
        step = nil
        options = []
        currentPick = nil
        recommendation = nil
        currentPrompt = nil
        hermesVM.setPersonaOverride(nil)
        if !drinkModeOn { hermesVM.onEmoDrinkSessionEnding = nil }
        gate.startCooldown(at: Date())
        if drinkModeOn { hermesVM.showEmoDrinkWatchingOnLens() } else { hermesVM.clearLens() }
        if let line { say(line) }
    }

    private func resetMomentTimer() {
        momentTimer?.cancel()
        momentTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.momentTimeout))
            guard !Task.isCancelled else { return }
            self?.endMoment(saying: nil)
        }
    }

    // MARK: Utterances and intents

    /// Offered every finalized utterance while a moment is active. True =
    /// it was a reply and nothing reaches the brain.
    private func claim(_ text: String) -> Bool {
        guard momentActive else { return false }
        resetMomentTimer()
        switch EmoDrinkCommands.spoken(text) {
        case .why: why(); return true
        case .somethingElse: somethingElse(); return true
        case .thanks: thanks(); return true
        case .back: back(); return true
        case .stop: endMoment(saying: nil); return true
        case nil: break
        }
        let offered = options.map { ChoiceOption(name: $0.name, nameJa: $0.nameJa) }
        if let index = DrinkChoiceParser.index(for: text, options: offered, language: language) {
            choose(index)
            return true
        }
        switch IntentDetector.detect(text) {
        case .stopDrinkMode: if drinkModeOn { stopDrinkMode() } else { endMoment(saying: nil) }; return true
        case .recommendDrink: Task { await pickNow() }; return true
        default: return false
        }
    }

    private func handleIntent(_ intent: HermesIntent) {
        switch intent {
        case .recommendDrink: Task { await pickNow() }
        case .startDrinkMode: Task { await startDrinkMode() }
        case .stopDrinkMode: stopDrinkMode()
        case .none: break
        }
    }

    // MARK: Drink mode

    func startDrinkMode() async {
        guard !drinkModeOn, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        guard catalog != nil else { fail("The drink catalogue is missing from this build."); return }

        // A Stop during any await below ends the session; drink mode must
        // then stay off rather than come back on a dead session.
        let gen = hermesVM.sessionGeneration
        if hermesVM.connectionState == .disconnected {
            await hermesVM.startSession()
            guard !hermesVM.stoppedSince(gen) else { return }
            guard hermesVM.connectionState != .disconnected else { sessionBlocked = sessionFailureText(); return }
            startedSession = true
        }
        sessionBlocked = micDenied ? strings.micBlocked : nil
        let granted = hermesVM.hasVisionSource ? await hermesVM.ensureVisionPermission(interactive: true) : false
        guard gen == hermesVM.sessionGeneration else { startedSession = false; return }
        guard granted else {
            fail("Drink mode needs a camera - connect the glasses or allow the iPhone camera.")
            if startedSession { startedSession = false; hermesVM.endSession() }
            return
        }
        let preflight = FrameTools.canRunVisionChecks
        guard preflight.ok else {
            fail("Drink mode needs a vision provider with a key (\(preflight.reason ?? "not set up")). Say \"what should I drink\" instead.")
            if startedSession { startedSession = false; hermesVM.endSession() }
            return
        }

        gate = VendingMachineGate()
        prevPrint = nil
        checkedPrint = nil
        checkInFlight = false
        frameCount = 0
        sentCount = 0
        budgetUsed = 0
        restingUntil = nil
        cameraLostAnnounced = false
        pausedForBackground = false
        drinkModeOn = true
        drinkModeStartedAt = Date()
        hermesVM.onEmoDrinkSessionEnding = { [weak self] in self?.stopDrinkMode(sessionEnding: true) }
        await refreshSnapshot()
        guard drinkModeOn, gen == hermesVM.sessionGeneration else { return }
        await startStream()
        guard drinkModeOn, gen == hermesVM.sessionGeneration else { return }
        if !momentActive { hermesVM.showEmoDrinkWatchingOnLens() }
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleFrame()
                let seconds = self?.intervalSeconds ?? EmoDrinkDefaults.defaultIntervalSeconds
                try? await Task.sleep(for: .seconds(Double(seconds)))
            }
        }
    }

    func stopDrinkMode() { stopDrinkMode(sessionEnding: false) }

    private func stopDrinkMode(sessionEnding: Bool) {
        guard drinkModeOn else { return }
        drinkModeOn = false
        drinkModeStartedAt = nil
        ticker?.cancel()
        ticker = nil
        stopStream()
        liveImage = nil
        hermesVM.onEmoDrinkSessionEnding = nil
        if momentActive { endMoment(saying: nil) } else if !sessionEnding { hermesVM.clearLens() }
        guard !sessionEnding else { startedSession = false; return }
        if startedSession {
            startedSession = false
            hermesVM.endSession()
        }
    }

    /// "Check now": the latest frame goes to the detector at once, past the
    /// change gate and the cooldown but never past the hourly budget. A NO,
    /// no fresh frame, or a spent budget each show their line for 3 s.
    func checkNow() async {
        guard drinkModeOn, !momentActive, !checkInFlight else { return }
        let now = Date()
        guard gate.canCheckNow(now: now) else {
            restingUntil = gate.restingUntil(now: now)
            flashNotice(strings.checkResting)
            return
        }
        guard let image = latestImage, let at = latestImageAt, now.timeIntervalSince(at) <= staleAfter else {
            flashNotice(strings.cameraNotReady)
            return
        }
        gate.recordSent(at: now)
        sentCount += 1
        budgetUsed = gate.budgetUsed(now: now)
        checkInFlight = true
        checkingNow = true
        defer { checkingNow = false }
        switch await check(image) {
        case .yes: break
        case .no: flashNotice(strings.noMachine)
        case .failed: flashNotice(strings.visionCheckFailed)
        }
    }

    /// The home card's 3 s line after Check now: no machine, a failed
    /// check, camera not ready, or the hour's budget spent.
    private func flashNotice(_ text: String) {
        noMachineNotice = text
        noMachineTask?.cancel()
        noMachineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.noMachineSeconds))
            guard !Task.isCancelled else { return }
            self?.noMachineNotice = nil
        }
    }

    // MARK: Background

    /// The iPhone camera stops in the background; the glasses' DAT stream
    /// does not. Phone route: pause sampling so silence is not "camera lost".
    func appDidEnterBackground() {
        guard drinkModeOn, hermesVM.visionRoute == .phone else { return }
        pausedForBackground = true
        hermesVM.pausePhoneVisionForBackground()
    }

    /// Back in front: restart the phone camera if it was lost, give frames a
    /// fresh grace period, resume sampling.
    func appDidBecomeActive() async {
        guard pausedForBackground else { return }
        pausedForBackground = false
        await hermesVM.resumePhoneVisionIfNeeded()
        latestImage = nil
        latestImageAt = nil
        drinkModeStartedAt = Date()
        cameraLostAnnounced = false
    }

    // MARK: Stream and frames

    private func startStream() async {
        let onImage: (UIImage) -> Void = { [weak self] image in
            guard let self else { return }
            self.latestImage = image
            self.latestImageAt = Date()
            self.liveImage = image
            if self.cameraLostAnnounced {
                self.cameraLostAnnounced = false
                if self.drinkModeOn && !self.momentActive { self.hermesVM.showEmoDrinkWatchingOnLens() }
            }
        }
        if hermesVM.visionStreamIsShared {
            guard drinkModeOn else { return }
            hermesVM.addVisionFrameObserver(Self.frameObserverKey) { frame in
                MainActor.assumeIsolated { if let image = frame.image { onImage(image) } }
            }
            return
        }
        do {
            try await hermesVM.vision.startLiveStream(
                onFrame: { frame in
                    guard let image = frame.image else { return }
                    Task { @MainActor in onImage(image) }
                },
                onError: { [weak self] message in
                    Task { @MainActor in self?.streamFailed(message) }
                })
            streamStarted = true
            if !drinkModeOn { hermesVM.vision.stopLiveStream(); streamStarted = false }
        } catch {
            guard drinkModeOn else { return }
            cameraLostAnnounced = true
            errorMessage = "The camera stream didn't open (\(error.localizedDescription)). Say \"what should I drink\" to pick without the camera."
            say(strings.cameraDidNotOpen)
        }
    }

    /// The live stream reported an error: say so once.
    private func streamFailed(_ message: String) {
        guard drinkModeOn else { return }
        latestImage = nil
        latestImageAt = nil
        liveImage = nil
        errorMessage = "The camera stream stopped (\(message))."
        guard !cameraLostAnnounced else { return }
        cameraLostAnnounced = true
        say(strings.cameraStopped)
    }

    /// Frames went stale or never arrived: stop trusting the last frame and
    /// say so once. Frames arriving again reset it.
    private func cameraLost() {
        guard drinkModeOn else { return }
        latestImage = nil
        latestImageAt = nil
        liveImage = nil
        guard !cameraLostAnnounced else { return }
        cameraLostAnnounced = true
        errorMessage = "Camera lost. Drink mode is paused until the camera is back; say \"what should I drink\" to pick without it."
        say(strings.cameraLost)
    }

    private func stopStream() {
        hermesVM.removeVisionFrameObserver(Self.frameObserverKey)
        if streamStarted {
            hermesVM.vision.stopLiveStream()
            streamStarted = false
        }
    }

    private var staleAfter: TimeInterval { max(2 * Double(intervalSeconds), 6) }

    private func sampleFrame() async {
        guard drinkModeOn, !pausedForBackground else { return }
        let now = Date()
        guard let image = latestImage, let at = latestImageAt, now.timeIntervalSince(at) <= staleAfter else {
            let started = latestImageAt ?? drinkModeStartedAt ?? now
            if latestImage != nil || now.timeIntervalSince(started) > staleAfter { cameraLost() }
            return
        }
        frameCount += 1
        let print: VNFeaturePrintObservation? = await Task.detached {
            image.cgImage.flatMap(FramePrint.observation(for:))
        }.value
        guard drinkModeOn else { return }
        let dPrev = FramePrint.distance(print, prevPrint)
        let dChecked = checkedPrint == nil ? nil : FramePrint.distance(print, checkedPrint)
        prevPrint = print
        budgetUsed = gate.budgetUsed(now: now)
        guard !momentActive, !checkInFlight else { return }
        switch gate.evaluate(distanceFromChecked: dChecked, distanceFromPrevious: dPrev, now: now) {
        case .send:
            gate.recordSent(at: now)
            checkedPrint = print
            sentCount += 1
            budgetUsed = gate.budgetUsed(now: now)
            restingUntil = nil
            checkInFlight = true
            Task { await self.check(image) }
        case .overBudget:
            restingUntil = gate.restingUntil(now: now)
        case .unsettled, .unchanged, .tooSoon, .coolingDown:
            break
        }
    }

    private static let visionNoticePrefix = "vision check failed: "

    /// One vision call. `.yes` when the reply is YES (and the moment
    /// started); `.failed` when the call itself failed.
    @discardableResult
    private func check(_ image: UIImage) async -> VisionCheck {
        defer { checkInFlight = false }
        guard let jpeg = FrameTools.downscaledJPEG(image, maxSide: 768, quality: 0.6) else {
            return .failed("could not encode the frame")
        }
        do {
            let reply = try await oneShot.askOneShot(systemPrompt: VendingMachineDetector.systemPrompt,
                                                     userText: VendingMachineDetector.userText,
                                                     photoJPEG: jpeg, timeout: Self.detectTimeout)
            // The call works again: drop a stale failure line.
            if aiNotice?.hasPrefix(Self.visionNoticePrefix) == true { aiNotice = nil }
            guard drinkModeOn, !momentActive, VendingMachineDetector.isYes(reply) else { return .no }
            await pickNow()
            return .yes
        } catch {
            // The loop stays quiet and keeps watching; the home card shows
            // the reason, and Check now flashes it.
            let reason = Self.shortReason(error)
            aiNotice = Self.visionNoticePrefix + reason
            return .failed(reason)
        }
    }

    // MARK: Helpers

    private func name(_ drink: Drink) -> String { language == .ja ? drink.nameJa : drink.name }
    private func otherName(_ drink: Drink) -> String { language == .ja ? drink.name : drink.nameJa }

    private func say(_ text: String) {
        hermesVM.speakCue(text, queued: true)
    }

    /// Shown on the phone AND spoken.
    private func fail(_ message: String) {
        errorMessage = message
        say(message)
    }

    private static func shortReason(_ error: Error) -> String {
        let text = error.localizedDescription
        let first = text.split(whereSeparator: { ".\n".contains($0) }).first.map(String.init) ?? text
        return first.count > 80 ? String(first.prefix(80)) : first
    }
}
