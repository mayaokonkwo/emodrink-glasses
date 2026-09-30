//
// BuildCheckViewModel.swift
//
// Runs Build Check. Owned by the App struct (not a screen) so a run keeps
// going with the phone in a pocket and the screen dismissed. It borrows the
// mic, camera, speech and lens from HermesSessionViewModel through the
// hooks in Task 11, and follows conversation capture's camera rules: observe
// a shared phone stream, never stop a stream it didn't start.
//
// Loop, every `intervalSeconds`: latest frame → saved to the log → feature
// print → ChangeGate → maybe a quick check. "step done" → BuildRunTracker →
// end-of-step check (blocking on critical steps) → AlertPolicy → speak /
// chime / log. Every decision is pure and tested; this file only wires.
//

import Foundation
import Observation
import UIKit
import Vision

@MainActor
@Observable
final class BuildCheckViewModel {
    static let intervalKey = "buildcheck_interval_seconds"
    static let budgetKey = "buildcheck_quick_budget_per_hour"
    static let checksEnabledKey = "buildcheck_checks_enabled"
    static let operatorKey = "buildcheck_operator_name"
    static let lastProcedureKey = "buildcheck_last_procedure_id"
    static let frameObserverKey = "build-check"
    static let replyWindow: TimeInterval = 20
    static let maxSettledFrames = 3

    // MARK: Settings

    /// Clamped on read (2...60); the Stepper enforces the same range. No
    /// clamping re-assignment inside didSet - with @Observable that recurses.
    var intervalSeconds: Int = {
        let v = UserDefaults.standard.integer(forKey: intervalKey)
        return v == 0 ? 5 : min(60, max(2, v))
    }() {
        didSet { UserDefaults.standard.set(intervalSeconds, forKey: Self.intervalKey) }
    }
    var budgetPerHour: Int = {
        let v = UserDefaults.standard.integer(forKey: budgetKey)
        return v == 0 ? 120 : v
    }() {
        didSet { UserDefaults.standard.set(max(0, budgetPerHour), forKey: Self.budgetKey) }
    }
    var checksEnabled: Bool = UserDefaults.standard.object(forKey: checksEnabledKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(checksEnabled, forKey: Self.checksEnabledKey) }
    }
    var operatorName: String = UserDefaults.standard.string(forKey: operatorKey) ?? "" {
        didSet { UserDefaults.standard.set(operatorName, forKey: Self.operatorKey) }
    }

    // MARK: Observable state

    private(set) var procedures: [Procedure] = []
    private(set) var runs: [BuildRun] = []
    private(set) var activeRun: BuildRun?
    private(set) var tracker: BuildRunTracker?
    private(set) var liveImage: UIImage?
    private(set) var aiCallCount = 0
    /// "Checks offline, still logging" / "Checks off: <reason>".
    private(set) var checksNotice: String?
    private(set) var lastWarning: String?
    var errorMessage: String?
    private(set) var importing = false

    var currentStepNumber: Int { (tracker?.current ?? 0) + 1 }

    // MARK: Collaborators

    let procedureStore = ProcedureStore()
    let runStore = BuildRunStore()
    @ObservationIgnored private let checker = BuildChecker()
    @ObservationIgnored private let hermesVM: HermesSessionViewModel

    // MARK: Run-scoped state (not observed)

    @ObservationIgnored private var gate = ChangeGate()
    @ObservationIgnored private var policy = AlertPolicy()
    @ObservationIgnored private var throttle = SaveThrottle()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var streamStarted = false
    @ObservationIgnored private var startedSession = false
    @ObservationIgnored private var latestImage: UIImage?
    @ObservationIgnored private var prevPrint: VNFeaturePrintObservation?
    @ObservationIgnored private var checkedPrint: VNFeaturePrintObservation?
    @ObservationIgnored private var settledFrames: [(filename: String, image: UIImage, t: Date)] = []
    @ObservationIgnored private var quickInFlight = false
    @ObservationIgnored private var fullInFlight = false
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var checksDisabled = false
    @ObservationIgnored private var pendingReply: (alertID: UUID, step: Int, expires: Date)?
    @ObservationIgnored private var blockingAlertID: UUID?
    @ObservationIgnored private var unreadNotes: [Int: [(alertID: UUID, issue: String)]] = [:]
    /// Notes were read out on this step's "step done"; the next one advances.
    @ObservationIgnored private var notesReadThisCycle = false
    @ObservationIgnored private var isStarting = false
    /// A log write failed this run - reported once, not on every save.
    @ObservationIgnored private var logWriteFailed = false
    /// The in-flight critical check is a re-check of this blocked step:
    /// only a `.match` unblocks it.
    @ObservationIgnored private var recheckingBlockedStep: Int?
    /// How the pending critical check was started, logged on its advance.
    @ObservationIgnored private var criticalVia: StepChangeVia = .voice

    init(hermesVM: HermesSessionViewModel) {
        self.hermesVM = hermesVM
        hermesVM.onStartBuildCheck = { [weak self] in self?.startFromVoice() }
        hermesVM.onBuildKey = { [weak self] action in self?.handleKey(action) }
        reload()
    }

    func reload() {
        procedures = procedureStore.all()
        runs = runStore.all()
    }

    // MARK: Procedures

    func importDocument(at url: URL) async -> Procedure? {
        importing = true
        defer { importing = false }
        do {
            let text = try await ProcedureImporter.text(fromFileAt: url)
            let scoped = url.startAccessingSecurityScopedResource()
            let data = try? Data(contentsOf: url)
            if scoped { url.stopAccessingSecurityScopedResource() }
            let source = try data.map { try procedureStore.addSource($0, fileExtension: url.pathExtension) }
            return try await makeProcedure(text: text, fallbackTitle: url.deletingPathExtension().lastPathComponent,
                                           source: source)
        } catch {
            errorMessage = importMessage(error)
            return nil
        }
    }

    func importText(_ text: String, title: String) async -> Procedure? {
        importing = true
        defer { importing = false }
        do {
            let source = try procedureStore.addSource(Data(text.utf8), fileExtension: "txt")
            return try await makeProcedure(text: text, fallbackTitle: title, source: source)
        } catch {
            errorMessage = importMessage(error)
            return nil
        }
    }

    private func makeProcedure(text: String, fallbackTitle: String, source: String?) async throws -> Procedure {
        let split = try await ProcedureImporter.steps(from: text, checker: checker)
        let title = split.title ?? (fallbackTitle.isEmpty ? "Untitled procedure" : fallbackTitle)
        let procedure = Procedure(title: title, steps: split.steps, sourceFilename: source)
        procedureStore.save(procedure)
        reload()
        return procedure
    }

    private func importMessage(_ error: Error) -> String {
        switch error as? ProcedureParser.ParseError {
        case .tooLong(let n):
            return "That document is \(n) characters; the limit is \(ProcedureParser.maxCharacters). Split it into smaller procedures and import each."
        case .empty:
            return "That document has no text."
        case .unreadableAIReply:
            return "The AI couldn't split that document into steps. Try pasting it as a numbered list."
        case nil:
            return error.localizedDescription
        }
    }

    func save(_ procedure: Procedure) {
        procedureStore.save(procedure)
        reload()
    }

    func delete(_ procedure: Procedure) {
        procedureStore.delete(id: procedure.id)
        reload()
    }

    func deleteRun(_ run: BuildRun) {
        runStore.delete(id: run.id)
        reload()
    }

    /// Adds a reference photo (max 3 per step). Returns false at the cap.
    func addReferencePhoto(_ image: UIImage, to stepID: UUID, in procedure: inout Procedure) -> Bool {
        guard let index = procedure.steps.firstIndex(where: { $0.id == stepID }),
              procedure.steps[index].referencePhotoFilenames.count < Procedure.maxReferencePhotos,
              let jpeg = BuildCheckComposer.downscaledJPEG(image, maxSide: 1600, quality: 0.8),
              let name = try? procedureStore.addPhoto(jpeg) else { return false }
        procedure.edit { $0.steps[index].referencePhotoFilenames.append(name) }
        return true
    }

    /// A still from whichever eye is active (glasses or iPhone).
    func captureReferenceFromCamera() async -> UIImage? {
        guard await hermesVM.ensureVisionPermission(interactive: true),
              let data = try? await hermesVM.captureVisionPhoto() else {
            errorMessage = "Couldn't take a photo from the camera."
            return nil
        }
        return UIImage(data: data)
    }

    // MARK: Start / end

    private func startFromVoice() {
        let lastID = UserDefaults.standard.string(forKey: Self.lastProcedureKey).flatMap(UUID.init)
        let ready = procedures.filter(\.ready)
        guard let procedure = ready.first(where: { $0.id == lastID }) ?? (ready.count == 1 ? ready.first : nil) else {
            hermesVM.speakCue("Pick a procedure on the phone first.")
            return
        }
        Task { await startRun(procedure) }
    }

    func startRun(_ procedure: Procedure) async {
        guard activeRun == nil, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        guard procedure.ready else { errorMessage = "Review the procedure and mark it ready first."; return }
        guard !hermesVM.conversationCaptureActive else {
            errorMessage = "Stop the conversation recording before starting a build check."
            return
        }
        if hermesVM.connectionState == .disconnected {
            await hermesVM.startSessionForRecording()
            guard hermesVM.connectionState != .disconnected else {
                errorMessage = "Couldn't start the microphone."
                return
            }
            startedSession = true
        }
        guard hermesVM.hasVisionSource, await hermesVM.ensureVisionPermission(interactive: true) else {
            errorMessage = "Build Check needs a camera - connect the glasses or allow the iPhone camera."
            if startedSession { startedSession = false; hermesVM.endSession() }
            return
        }

        let settings = BuildRunSettings(
            intervalSeconds: intervalSeconds,
            gate: ChangeGate.Config(budgetPerHour: budgetPerHour),
            checksEnabled: checksEnabled)
        let run = BuildRun(id: UUID(), procedure: procedure, operatorName: operatorName,
                           startedAt: Date(), endedAt: nil, settings: settings, events: [])
        do {
            try runStore.begin(run, referencePhoto: procedureStore.photoURL)
        } catch {
            errorMessage = "Couldn't create the run log: \(error.localizedDescription)"
            if startedSession { startedSession = false; hermesVM.endSession() }
            return
        }
        UserDefaults.standard.set(procedure.id.uuidString, forKey: Self.lastProcedureKey)

        activeRun = run
        tracker = BuildRunTracker(stepCount: procedure.steps.count, criticalSteps: procedure.criticalStepIndices)
        gate = ChangeGate(config: settings.gate)
        policy = AlertPolicy()
        throttle = SaveThrottle()
        aiCallCount = 0
        checksNotice = settings.checksEnabled ? nil : "Checks off - logging only"
        checksDisabled = !settings.checksEnabled
        consecutiveFailures = 0
        quickInFlight = false
        fullInFlight = false
        lastWarning = nil
        pendingReply = nil
        blockingAlertID = nil
        unreadNotes = [:]
        notesReadThisCycle = false
        logWriteFailed = false
        recheckingBlockedStep = nil
        criticalVia = .voice
        settledFrames = []
        prevPrint = nil
        checkedPrint = nil
        latestImage = nil
        liveImage = nil

        hermesVM.buildRunClaimer = { [weak self] text in self?.claim(text) ?? false }
        hermesVM.onSessionEnding = { [weak self] in self?.endRun(sessionEnding: true) }

        await startStream()
        // Ended while the stream was opening: no ticker for a dead run.
        guard activeRun?.id == run.id else { return }
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double(settings.intervalSeconds)))
                guard let self, !Task.isCancelled else { return }
                await self.sampleFrame()
            }
        }
        announceStep(prefix: "Build check started.")
    }

    func endRun() { endRun(sessionEnding: false) }

    private func endRun(sessionEnding: Bool) {
        guard var run = activeRun else { return }
        ticker?.cancel()
        ticker = nil
        stopStream()
        hermesVM.buildRunClaimer = nil
        hermesVM.onSessionEnding = nil
        run.endedAt = Date()
        var saved = true
        do {
            try runStore.write(run)
        } catch {
            saved = false
            errorMessage = "Couldn't save the build check log: \(error.localizedDescription)"
        }
        let summary = BuildRunSummary.spokenSummary(run)
        activeRun = nil
        tracker = nil
        liveImage = nil
        latestImage = nil
        pendingReply = nil
        recheckingBlockedStep = nil
        reload()
        // The session is already going away; don't let a stale flag make a
        // later run end a session the user started.
        guard !sessionEnding else { startedSession = false; return }
        hermesVM.speakCue(saved ? summary : "The run log could not be saved.")
        if startedSession {
            startedSession = false
            // Let the summary finish before the audio stack goes away.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard let self, self.activeRun == nil else { return }
                self.hermesVM.endSession()
            }
        }
    }

    // MARK: Camera

    private func startStream() async {
        let onImage: (UIImage) -> Void = { [weak self] image in
            self?.latestImage = image
            self?.liveImage = image
        }
        if hermesVM.visionStreamIsShared {
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
                onError: { _ in })
            streamStarted = true
            if activeRun == nil { hermesVM.vision.stopLiveStream(); streamStarted = false }
        } catch {
            errorMessage = "The camera stream didn't open (\(error.localizedDescription)). The run keeps logging speech; close Lens if it's open, then end and restart the run."
        }
    }

    private func stopStream() {
        hermesVM.removeVisionFrameObserver(Self.frameObserverKey)
        if streamStarted {
            hermesVM.vision.stopLiveStream()
            streamStarted = false
        }
    }

    // MARK: Sampling

    private func sampleFrame() async {
        guard let runID = activeRun?.id, let tracker, let image = latestImage,
              let jpeg = BuildCheckComposer.downscaledJPEG(image),
              let filename = try? runStore.addFrame(jpeg, runID: runID, at: Date()) else { return }
        let now = Date()
        let step = tracker.current
        let print: VNFeaturePrintObservation? = await Task.detached {
            UIImage(data: jpeg)?.cgImage.flatMap(FramePrint.observation(for:))
        }.value
        guard activeRun?.id == runID else { return }

        let dPrev = FramePrint.distance(print, prevPrint)
        let dChecked = checkedPrint == nil ? nil : FramePrint.distance(print, checkedPrint)
        prevPrint = print
        if let dPrev, dPrev < gate.config.settleThreshold, let frameImage = UIImage(data: jpeg) {
            settledFrames.append((filename, frameImage, now))
            if settledFrames.count > Self.maxSettledFrames { settledFrames.removeFirst() }
        }

        var sent = false
        if !checksDisabled, !quickInFlight, !fullInFlight, tracker.phase == .working,
           gate.evaluate(distanceFromChecked: dChecked, distanceFromPrevious: dPrev, now: now) == .send {
            gate.recordSent(at: now)
            checkedPrint = print
            sent = true
            runQuickCheck(step: step, jpeg: jpeg, filename: filename)
        }
        append(.frame(t: now, step: step, filename: filename, sentToAI: sent))
    }

    private func persist(force: Bool) {
        guard let run = activeRun, throttle.shouldSave(now: Date(), force: force) else { return }
        do {
            try runStore.write(run)
        } catch {
            guard !logWriteFailed else { return }
            logWriteFailed = true
            errorMessage = "Couldn't save the build check log: \(error.localizedDescription)"
        }
    }

    private func append(_ event: BuildRunEvent, force: Bool = false) {
        activeRun?.events.append(event)
        persist(force: force)
    }

    // MARK: Checks

    private func runQuickCheck(step: Int, jpeg: Data, filename: String) {
        guard let run = activeRun else { return }
        quickInFlight = true
        let procedureStep = run.procedure.steps[step]
        let total = run.procedure.steps.count
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.callChecker(kind: .quick, step: procedureStep, number: step + 1,
                                                 total: total, jpeg: jpeg, labels: [])
            // A verdict from a run that has since ended must not land in the next one.
            guard self.activeRun?.id == run.id else { return }
            self.quickInFlight = false
            self.finishCheck(outcome, kind: .quick, step: step, frames: [filename], criticalWaiting: false)
        }
    }

    /// End-of-step check. `criticalWaiting` = the tracker is holding the step on it.
    private func runFullCheck(step: Int, criticalWaiting: Bool) {
        guard let run = activeRun else { return }
        if checksDisabled {
            // Logging-only run: a critical step can't be verified, so it
            // advances on the wearer's word and the log shows it unchecked.
            if criticalWaiting {
                let recheck = recheckingBlockedStep == step
                recheckingBlockedStep = nil
                applyCriticalResult(step: step, blocking: recheck)
            }
            return
        }
        fullInFlight = true
        let procedureStep = run.procedure.steps[step]
        var tiles: [(label: String, image: UIImage)] = []
        for (i, name) in procedureStep.referencePhotoFilenames.enumerated() {
            if let image = UIImage(contentsOfFile: runStore.referenceURL(runID: run.id, filename: name).path) {
                tiles.append(("REFERENCE \(i + 1)", image))
            }
        }
        var frames = settledFrames
        if frames.isEmpty, let latest = latestImage { frames = [("latest", latest, Date())] }
        let now = Date()
        for frame in frames {
            tiles.append(("NOW -\(Int(now.timeIntervalSince(frame.t)))s", frame.image))
        }
        guard let jpeg = BuildCheckComposer.composite(tiles) else {
            fullInFlight = false
            finishCheck(.failure(ProcedureImporter.ImportError.unreadable), kind: .full, step: step,
                        frames: [], criticalWaiting: criticalWaiting)
            return
        }
        let labels = tiles.map(\.label)
        let frameNames = frames.map(\.filename)
        let total = run.procedure.steps.count
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.callChecker(kind: .full, step: procedureStep, number: step + 1,
                                                 total: total, jpeg: jpeg, labels: labels)
            guard self.activeRun?.id == run.id else { return }
            self.fullInFlight = false
            self.finishCheck(outcome, kind: .full, step: step, frames: frameNames, criticalWaiting: criticalWaiting)
        }
    }

    private func callChecker(kind: CheckKind, step: ProcedureStep, number: Int, total: Int,
                             jpeg: Data, labels: [String]) async -> Result<CheckResult, Error> {
        aiCallCount += 1
        do {
            return .success(try await checker.check(kind: kind, step: step, number: number, total: total,
                                                    imageJPEG: jpeg, tileLabels: labels))
        } catch {
            return .failure(error)
        }
    }

    private func finishCheck(_ outcome: Result<CheckResult, Error>, kind: CheckKind, step: Int,
                             frames: [String], criticalWaiting: Bool) {
        guard let run = activeRun else { return }
        let checkID = UUID()
        let now = Date()
        let result: CheckResult
        switch outcome {
        case .success(let r):
            result = r
            consecutiveFailures = 0
            if checksNotice == "Checks offline, still logging" { checksNotice = nil }
            append(.check(id: checkID, t: now, step: step, kind: kind, frames: frames, result: r, error: nil))
        case .failure(let error):
            result = .unclear("check failed")
            append(.check(id: checkID, t: now, step: step, kind: kind, frames: frames, result: nil,
                          error: error.localizedDescription))
            consecutiveFailures += 1
            if BuildChecker.isFatal(error) {
                checksDisabled = true
                checksNotice = "Checks off: \(error.localizedDescription)"
                hermesVM.playChime()
            } else if consecutiveFailures == 3 {
                checksNotice = "Checks offline, still logging"
                hermesVM.playChime()
            }
        }

        let critical = run.procedure.steps[step].critical
        let decision = policy.decide(result: result, kind: kind, step: step, critical: critical, now: now)
        // A re-check of a blocked step unblocks only on a match; the first
        // end-of-step check blocks only on a confident mismatch.
        let isRecheck = criticalWaiting && recheckingBlockedStep == step
        if isRecheck { recheckingBlockedStep = nil }
        let blocking = criticalWaiting && (isRecheck ? result.verdict != .match : result.isConfidentMismatch)
        let blockLine: String? = !blocking ? nil : isRecheck
            ? "Couldn't confirm the fix on step \(step + 1). Say fixed to check again, or override."
            : "Say fixed to check again, or override."
        var alertID: UUID?
        if decision.level != .log {
            let id = UUID()
            alertID = id
            append(.alert(id: id, t: now, step: step, checkID: checkID, level: decision.level,
                          askedToConfirm: decision.askToConfirm), force: true)
            deliver(decision, result: result, step: step, alertID: id, blockLine: blockLine)
        } else if let blockLine {
            lastWarning = blockLine
            hermesVM.speakCue(blockLine)
        }
        if criticalWaiting {
            // Keep the previous blocking alert when the re-check raised none.
            if blocking, let alertID { blockingAlertID = alertID }
            applyCriticalResult(step: step, blocking: blocking)
        }
    }

    private func applyCriticalResult(step: Int, blocking: Bool) {
        guard var t = tracker else { return }
        let outcome = t.criticalCheckFinished(step: step, blocking: blocking)
        tracker = t
        if blocking {
            showLens(flag: lastWarning)
        } else {
            blockingAlertID = nil
            handleAdvance(outcome, from: step, via: criticalVia)
        }
    }

    /// `blockLine`: the alert blocks a critical step, so the wearer is told
    /// how to get out of it (fixed / override) instead of the usual reply set.
    private func deliver(_ decision: AlertDecision, result: CheckResult, step: Int, alertID: UUID,
                         blockLine: String?) {
        let issue = result.issue.isEmpty ? result.observed : result.issue
        switch decision.level {
        case .speak:
            let line = "Check step \(step + 1): \(issue.isEmpty ? "this doesn't match the procedure" : issue)."
            lastWarning = line
            pendingReply = (alertID, step, Date().addingTimeInterval(Self.replyWindow))
            hermesVM.speakCue(line + " " + (blockLine ?? "Say confirmed, ignore, or fixed."))
            showLens(flag: issue)
        case .chime:
            hermesVM.playChime()
            if let blockLine {
                lastWarning = blockLine
                pendingReply = (alertID, step, Date().addingTimeInterval(Self.replyWindow))
                hermesVM.speakCue(blockLine)
            } else if decision.askToConfirm {
                let line = "Couldn't verify step \(step + 1). Can you confirm it's right?"
                lastWarning = line
                pendingReply = (alertID, step, Date().addingTimeInterval(Self.replyWindow))
                hermesVM.speakCue(line)
            } else {
                unreadNotes[step, default: []].append((alertID, issue))
            }
        case .log:
            break
        }
    }

    // MARK: Commands

    private func claim(_ text: String) -> Bool {
        guard activeRun != nil else { return false }
        if let cmd = IntentDetector.buildRunCommand(text) {
            command(cmd, via: .voice)
        } else {
            append(.speech(t: Date(), step: tracker?.current ?? 0, text: text))
        }
        return true
    }

    private func handleKey(_ action: GlassesKeyAction) {
        guard activeRun != nil else {
            hermesVM.speakCue("No build check is running.")
            return
        }
        switch action {
        case .buildStepDone: command(.stepDone, via: .button)
        case .buildRepeatWarning: command(.repeatWarning, via: .button)
        default: break
        }
    }

    func command(_ command: BuildRunCommand, via: StepChangeVia) {
        guard activeRun != nil, var t = tracker else { return }
        let now = Date()
        switch command {
        case .end:
            endRun()

        case .repeatWarning:
            hermesVM.speakCue(lastWarning ?? "No warnings so far.")

        case .confirmed, .ignore:
            guard let pending = pendingReply, pending.expires > now else {
                hermesVM.speakCue("There's no open warning.")
                return
            }
            append(.reply(t: now, step: pending.step, alertID: pending.alertID,
                          reply: command == .confirmed ? .confirmed : .ignore), force: true)
            pendingReply = nil
            if t.phase == .blocked, pending.step == t.current {
                hermesVM.speakCue("Logged. Step \(t.current + 1) is still blocked - say fixed or override.")
                return
            }
            showLens(flag: nil)
            hermesVM.speakCue("Noted.")

        case .fixed:
            guard t.phase != .checking, !fullInFlight else {
                hermesVM.speakCue("Still checking step \(t.current + 1).")
                return
            }
            // "fixed" re-checks the FLAGGED step; with nothing flagged it spends nothing.
            let pending = pendingReply.flatMap { $0.expires > now ? $0 : nil }
            let targetStep: Int
            if let pending {
                targetStep = pending.step
            } else if t.phase == .blocked {
                targetStep = t.current
            } else {
                hermesVM.speakCue("There's no open warning.")
                return
            }
            let recheckBlocked = t.phase == .blocked && targetStep == t.current
            if recheckBlocked, checksDisabled {
                hermesVM.speakCue("Checks are off. Say override to continue.")
                return
            }
            if let pending {
                append(.reply(t: now, step: pending.step, alertID: pending.alertID, reply: .fixed), force: true)
                pendingReply = nil
            } else if let id = blockingAlertID {
                append(.reply(t: now, step: t.current, alertID: id, reply: .fixed), force: true)
            }
            if recheckBlocked {
                _ = t.fixed()
                tracker = t
                recheckingBlockedStep = t.current
                criticalVia = via
            }
            hermesVM.speakCue("Checking step \(targetStep + 1) again.")
            runFullCheck(step: targetStep, criticalWaiting: recheckBlocked)

        case .override:
            guard t.phase == .blocked else {
                hermesVM.speakCue("Nothing to override.")
                return
            }
            let from = t.current
            if let id = blockingAlertID {
                append(.reply(t: now, step: from, alertID: id, reply: .override), force: true)
            }
            blockingAlertID = nil
            pendingReply = nil
            let outcome = t.override()
            tracker = t
            handleAdvance(outcome, from: from, via: .override)

        case .stepDone:
            let step = t.current
            // Chimed notes (from this or any earlier step) are read out on
            // "step done"; this utterance doesn't advance, the next one does.
            let notes = unreadNotes.keys.sorted().flatMap { key in
                (unreadNotes[key] ?? []).map { (step: key, alertID: $0.alertID, issue: $0.issue) }
            }
            if !notes.isEmpty, !notesReadThisCycle, t.phase == .working {
                notesReadThisCycle = true
                unreadNotes = [:]
                let first = notes[0]
                pendingReply = (first.alertID, first.step, now.addingTimeInterval(Self.replyWindow))
                lastWarning = "Note on step \(first.step + 1): \(first.issue)"
                let more = notes.count > 1 ? " And \(notes.count - 1) more on the phone." : ""
                hermesVM.speakCue("One note on step \(first.step + 1) before you move on: \(first.issue).\(more) Say confirmed, ignore, or fixed, then step done.")
                return
            }
            let outcome = t.stepDone()
            tracker = t
            switch outcome {
            case .awaitingCheck:
                criticalVia = via
                recheckingBlockedStep = nil
                hermesVM.speakCue("Checking step \(step + 1).")
                runFullCheck(step: step, criticalWaiting: true)
            case .refused:
                hermesVM.speakCue(t.phase == .blocked
                    ? "Step \(step + 1) is blocked. Say fixed to check again, or override."
                    : "Still checking step \(step + 1).")
            case .advanced, .finished:
                runFullCheck(step: step, criticalWaiting: false)
                handleAdvance(outcome, from: step, via: via)
            }
        }
    }

    private func handleAdvance(_ outcome: BuildRunTracker.Outcome, from: Int, via: StepChangeVia) {
        switch outcome {
        case .advanced(let to):
            append(.stepChange(t: Date(), from: from, to: to, via: via), force: true)
            policy.stepChanged()
            settledFrames = []
            notesReadThisCycle = false
            announceStep(prefix: nil)
        case .finished:
            append(.stepChange(t: Date(), from: from, to: from + 1, via: via), force: true)
            hermesVM.speakCue("All steps done. Say end build check to save the run.")
            showLens(flag: "All steps done - say \"end build check\"")
        case .awaitingCheck, .refused:
            break
        }
    }

    private func announceStep(prefix: String?) {
        guard let run = activeRun, let t = tracker, t.current < run.procedure.steps.count else { return }
        let step = run.procedure.steps[t.current]
        let line = "Step \(t.current + 1)\(step.critical ? ", critical" : ""): \(step.text)"
        hermesVM.speakCue([prefix, line].compactMap { $0 }.joined(separator: " "))
        showLens(flag: nil)
    }

    private func showLens(flag: String?) {
        guard let run = activeRun, let t = tracker else { return }
        let index = min(t.current, max(0, run.procedure.steps.count - 1))
        guard run.procedure.steps.indices.contains(index) else { return }
        hermesVM.showBuildCheckOnLens(step: index + 1, total: run.procedure.steps.count,
                                      text: run.procedure.steps[index].text, flag: flag)
    }
}
