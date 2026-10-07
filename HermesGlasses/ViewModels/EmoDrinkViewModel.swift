//
// EmoDrinkViewModel.swift
//
// Runs EmoDrink. Owned by the App struct so drink
// mode keeps watching with the phone in a pocket. Borrows mic, camera,
// speech and lens from HermesSessionViewModel through its EmoDrink hooks.
//
// Two loops. The MOMENT: a pick is on the lens, the persona is swapped in,
// "why" / "something else" / "thanks" are claimed, anything else is a
// question for the persona; ends on thanks, stop, a new pick, or 120 s of
// silence. DRINK MODE: every `intervalSeconds` the latest frame is feature-
// printed; VendingMachineGate decides whether to spend one vision call on
// "is there a vending machine"; YES starts a moment. Every decision in
// between is pure and tested; this file only wires.
//

import Foundation
import Observation
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

    // MARK: Observable state

    private(set) var catalog: DrinkCatalog?
    private(set) var cached: CachedSnapshot?
    /// "sample data: short night", "this morning's cached data (fetch failed)". Nil when live.
    private(set) var snapshotNotice: String?
    private(set) var recommendation: Recommendation?
    /// The drink on the lens right now (the pick, or an alternate after "something else").
    private(set) var currentPick: Drink?
    private(set) var momentActive = false
    private(set) var drinkModeOn = false
    private(set) var frameCount = 0
    private(set) var sentCount = 0
    private(set) var budgetUsed = 0
    private(set) var restingUntil: Date?
    private(set) var liveImage: UIImage?
    private(set) var fetching = false
    var errorMessage: String?
    /// Why the AI was skipped, when it was ("no API key", a timeout).
    private(set) var aiNotice: String?

    var hasCatalog: Bool { catalog != nil }

    // MARK: Collaborators

    @ObservationIgnored private let hermesVM: HermesSessionViewModel
    @ObservationIgnored private let store = PhysiologyStore()
    /// One-shot vision and text calls that must not touch chat memory.
    @ObservationIgnored private let oneShot = DirectClient()

    // MARK: Loop state (not observed)

    @ObservationIgnored private var gate = VendingMachineGate()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var momentTimer: Task<Void, Never>?
    @ObservationIgnored private var streamStarted = false
    @ObservationIgnored private var startedSession = false
    @ObservationIgnored private var latestImage: UIImage?
    @ObservationIgnored private var latestImageAt: Date?
    @ObservationIgnored private var prevPrint: VNFeaturePrintObservation?
    @ObservationIgnored private var checkedPrint: VNFeaturePrintObservation?
    @ObservationIgnored private var checkInFlight = false
    @ObservationIgnored private var isStarting = false
    private(set) var currentSnapshot: PhysiologySnapshot?
    @ObservationIgnored private var currentSourceLabel = ""
    /// The persona prompt of the moment on the lens, for "why".
    @ObservationIgnored private var currentPrompt: String?
    /// The card on the lens, redrawn when a reply's dwell ends.
    @ObservationIgnored private var currentCard: (title: String, subtitle: String, reason: String, source: String)?
    @ObservationIgnored private var cameraLostAnnounced = false
    @ObservationIgnored private var drinkModeStartedAt: Date?

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
            let stale = !snap.isToday(today)
            snapshotNotice = stale ? "feed dated \(snap.date)" : nil
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

    // MARK: The pick and the moment

    /// Voice, button, sheet or detection all land here.
    func pickNow() async {
        guard let catalog else {
            fail("The drink catalogue is missing from this build.")
            return
        }
        guard let snapshot = await refreshSnapshot() else { return }
        let hour = Calendar.current.component(.hour, from: Date())
        guard let rec = DrinkRecommender.recommend(snapshot: snapshot, catalog: catalog, hour: hour, lowSugar: lowSugar) else { return }
        recommendation = rec
        currentPick = rec.pick
        startMoment(snapshot: snapshot, recommendation: rec, pick: rec.pick, speak: .firstLine)
    }

    private enum MomentSpeech { case firstLine, alternate }

    private func startMoment(snapshot: PhysiologySnapshot, recommendation rec: Recommendation, pick: Drink, speak: MomentSpeech) {
        guard let catalog else { return }
        momentActive = true
        if !drinkModeOn { hermesVM.onEmoDrinkSessionEnding = { [weak self] in self?.endMoment(saying: nil) } }
        let prompt = EmoDrinkPersona.systemPrompt(snapshot: snapshot, pick: pick, recommendation: rec,
                                                  catalog: catalog, sourceLabel: currentSourceLabel)
        hermesVM.setPersonaOverride(prompt)
        currentPrompt = prompt
        let sourceLine = snapshotNotice ?? currentSourceLabel
        currentCard = (title: pick.name, subtitle: pick.nameJa, reason: rec.reasonLine, source: sourceLine)
        hermesVM.showEmoDrinkOnLens(title: pick.name, subtitle: pick.nameJa, reason: rec.reasonLine,
                                    source: sourceLine, choices: EmoDrinkCommands.cardChoices(for: .en))  // Task 13 passes the resolved language
        resetMomentTimer()
        switch speak {
        case .alternate:
            say(EmoDrinkPersona.alternateLine(pick: pick))
        case .firstLine:
            Task { await speakFirstLine(prompt: prompt, pick: pick, recommendation: rec) }
        }
    }

    private func speakFirstLine(prompt: String, pick: Drink, recommendation rec: Recommendation) async {
        let fallback = EmoDrinkPersona.fallbackLine(pick: pick, recommendation: rec)
        guard hermesVM.hasDirectKey else {
            aiNotice = "no API key, spoken from the rules"
            say(fallback)
            return
        }
        do {
            let line = try await oneShot.askOneShotText(systemPrompt: prompt, userText: EmoDrinkPersona.firstLineRequest,
                                                        maxTokens: 80, timeout: Self.firstLineTimeout)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard momentActive, currentPick == pick else { return }
            aiNotice = nil
            say(trimmed.isEmpty ? fallback : trimmed)
        } catch {
            guard momentActive, currentPick == pick else { return }
            aiNotice = "AI line skipped: \(Self.shortReason(error))"
            say(fallback)
        }
    }

    /// Redraws the moment's card, e.g. when a reply's dwell ends.
    private func reshowMoment() {
        guard momentActive, let card = currentCard else { return }
        hermesVM.showEmoDrinkOnLens(title: card.title, subtitle: card.subtitle, reason: card.reason,
                                    source: card.source, choices: EmoDrinkCommands.cardChoices(for: .en))  // Task 13 passes the resolved language
    }

    /// Spoken only: the card stays on the lens. A one-shot call so the
    /// answer cannot replace the card; any failure speaks the rule-based reason.
    func why() {
        guard momentActive, let rec = recommendation else { return }
        resetMomentTimer()
        let fallback = EmoDrinkPersona.whyFallback(recommendation: rec)
        guard hermesVM.hasDirectKey, let prompt = currentPrompt else {
            say(fallback)
            return
        }
        let pickAtAsk = currentPick
        Task {
            do {
                let answer = try await oneShot.askOneShotText(systemPrompt: prompt, userText: EmoDrinkPersona.whyQuestion,
                                                              maxTokens: 120, timeout: Self.firstLineTimeout)
                guard momentActive, currentPick == pickAtAsk else { return }
                let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                say(trimmed.isEmpty ? fallback : trimmed)
            } catch {
                aiNotice = "why answer skipped: \(Self.shortReason(error))"
                guard momentActive, currentPick == pickAtAsk else { return }
                say(fallback)
            }
        }
    }

    func somethingElse() {
        guard momentActive, let rec = recommendation, let snapshot = currentSnapshot, let pick = currentPick else { return }
        let next = rec.next(after: pick)
        currentPick = next
        startMoment(snapshot: snapshot, recommendation: rec, pick: next, speak: .alternate)
    }

    func thanks() {
        guard momentActive else { return }
        endMoment(saying: "Enjoy.")
    }

    private func endMoment(saying line: String?) {
        momentTimer?.cancel()
        momentTimer = nil
        guard momentActive else { return }
        momentActive = false
        currentPrompt = nil
        currentCard = nil
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

    // MARK: Utterances, intents, keys

    /// Offered every finalized utterance while a moment is active. True =
    /// it was a reply and nothing reaches the brain.
    private func claim(_ text: String) -> Bool {
        guard momentActive else { return false }
        resetMomentTimer()
        switch EmoDrinkCommands.spoken(text) {
        case .why: why(); return true
        case .somethingElse: somethingElse(); return true
        case .thanks: thanks(); return true
        case .back: return true // Task 13 implements back
        case .stop: endMoment(saying: nil); return true
        case nil: break
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
        default: break
        }
    }

    // MARK: Drink mode

    func toggleDrinkMode() {
        if drinkModeOn { stopDrinkMode() } else { Task { await startDrinkMode() } }
    }

    func startDrinkMode() async {
        guard !drinkModeOn, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        guard catalog != nil else { fail("The drink catalogue is missing from this build."); return }

        if hermesVM.connectionState == .disconnected {
            await hermesVM.startSession()
            guard hermesVM.connectionState != .disconnected else { fail("Couldn't start the microphone."); return }
            startedSession = true
        }
        guard hermesVM.hasVisionSource, await hermesVM.ensureVisionPermission(interactive: true) else {
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
        drinkModeOn = true
        drinkModeStartedAt = Date()
        hermesVM.onEmoDrinkSessionEnding = { [weak self] in self?.stopDrinkMode(sessionEnding: true) }
        await refreshSnapshot()
        guard drinkModeOn else { return }
        await startStream()
        guard drinkModeOn else { return }
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
            say("The camera didn't open. Say what should I drink to pick without it.")
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
        say("The camera stream stopped.")
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
        say("Camera lost. Drink mode is paused.")
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
        guard drinkModeOn else { return }
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

    private func check(_ image: UIImage) async {
        defer { checkInFlight = false }
        guard let jpeg = FrameTools.downscaledJPEG(image, maxSide: 768, quality: 0.6) else { return }
        do {
            let reply = try await oneShot.askOneShot(systemPrompt: VendingMachineDetector.systemPrompt,
                                                     userText: VendingMachineDetector.userText,
                                                     photoJPEG: jpeg, timeout: Self.detectTimeout)
            guard drinkModeOn, !momentActive else { return }
            if VendingMachineDetector.isYes(reply) { await pickNow() }
        } catch {
            // A failed check is a NO: stay quiet, keep watching.
            aiNotice = "vision check failed: \(Self.shortReason(error))"
        }
    }

    // MARK: Helpers

    private func say(_ text: String) {
        hermesVM.speakCue(text, queued: true)
    }

    /// Shown on the phone AND spoken, like Build Check's `fail`.
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
