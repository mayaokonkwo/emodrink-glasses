//
// AiSeeDeviceCoordinator.swift — AiSeeGlassKit
//
// The only object that starts or stops anything on the glasses. It keeps the
// mic / livestream state, asks AiSeeSequencing for a plan before every still,
// and executes it. Consumers (the sample UI, Hermes) never touch the SDK's
// routines directly, which is how the FINDINGS rules stay enforced.
//

import AVFoundation
import Foundation

#if canImport(RTKAIDeviceConnection)
import RTKAIDeviceConnection

actor AiSeeDeviceCoordinator {
    private let log: AiSeeLog
    private var connection: IntelligenceDeviceConnection?

    private(set) var micOpen = false { didSet { if oldValue != micOpen { notifyStateChange() } } }
    private(set) var streaming = false { didSet { if oldValue != streaming { notifyStateChange() } } }
    /// Latched when a shot returns `DeviceFailure.failure(code: 4)`. The camera is
    /// gone until the glasses are power-cycled (FINDINGS §1), so every later
    /// `capturePhoto()` fails immediately until a new connection is attached.
    private(set) var unavailableUntilReconnect = false
    private var lastStreamStop: Date?
    private var captureInFlight = false
    private var latestFrameJPEG: (() -> Data?)?
    private var reopenMic: (() async -> Void)?
    private var closeMic: (() async -> Void)?
    private var liveStream: AiSeeLiveStream?
    private var streamStarting = false
    private var microphone: AiSeeMicrophone?
    private var micBufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var micStarting = false
    private var pendingStreamStop = false
    private var pendingMicStop = false
    private var onStateChange: (@Sendable (_ micOpen: Bool, _ streaming: Bool) -> Void)?

    init(log: @escaping AiSeeLog) { self.log = log }

    /// Notified whenever `micOpen` or `streaming` changes, including changes the
    /// host did not ask for (an SDK-initiated stream termination, a failed mic
    /// reopen). Hosts mirror their own UI state from this.
    /// Physical key presses on the glasses (`keyIdx` as the SDK reports it; the
    /// vendor demo maps 1 → photo, 2 → livestream). The kit only reports them —
    /// mapping a key to an action is the host's decision.
    private var keyPressObserver: (@Sendable (_ keyIndex: Int) -> Void)?
    func setKeyPressObserver(_ observer: (@Sendable (_ keyIndex: Int) -> Void)?) {
        keyPressObserver = observer
    }
    private func keyPressed(_ index: Int) {
        log("key: pressed \(index)")
        keyPressObserver?(index)
    }

    func setStateObserver(_ observer: (@Sendable (_ micOpen: Bool, _ streaming: Bool) -> Void)?) {
        onStateChange = observer
    }

    private func notifyStateChange() { onStateChange?(micOpen, streaming) }

    func attach(_ connection: IntelligenceDeviceConnection?) {
        // Every piece of state below describes the device we are leaving, so a swap
        // to a different connection resets exactly as a detach does — otherwise a
        // reconnect inherits the old device's mic/stream flags.
        if self.connection !== connection {
            resetDeviceState()
            self.connection?.mediaRoutine.onKeyPressNotification = nil
        }
        self.connection = connection
        connection?.mediaRoutine.onKeyPressNotification = { [weak self] index in
            Task { await self?.keyPressed(index) }
        }
        if connection != nil {
            // A power cycle is the only way out of the wedge, and it always brings a
            // new connection with it — so attaching one clears the latch.
            unavailableUntilReconnect = false
        }
    }

    /// Vendor-type-free detach, so hosts (and the `#else` stub) have one name to call.
    func detach() { attach(nil) }

    private func resetDeviceState() {
        // A clip in progress is closed and handed over, not lost: the frames
        // already written are still a valid file.
        endClip(reason: "the glasses disconnected")
        streamUsers.removeAll()
        visionTerminate = nil
        micOpen = false
        streaming = false
        lastStreamStop = nil
        liveStream = nil
        latestFrameJPEG = nil
        microphone = nil
        micBufferHandler = nil
        closeMic = nil
        reopenMic = nil
        micSuspendedForCapture = false
        micReopenCancelled = true
    }

    // MARK: Still photo

    func capturePhoto() async throws -> Data {
        // Once wedged (FINDINGS §1) the camera refuses every shot until the
        // glasses are power-cycled — fail fast instead of shooting into a dead device.
        if unavailableUntilReconnect { throw AiSeeError.deviceWedged }
        // Serialize: a second caller waits, never fails.
        while captureInFlight { try await Task.sleep(for: .milliseconds(50)) }
        // The capture we queued behind may be the one that wedged the device.
        if unavailableUntilReconnect { throw AiSeeError.deviceWedged }
        // Bind the connection only once it is our turn: `attach()` may have
        // swapped or cleared it while we waited above.
        guard let connection else { throw AiSeeError.notConnected }
        captureInFlight = true
        defer { captureInFlight = false }

        let plan = AiSeeSequencing.stillPhotoPlan(
            state: .init(micOpen: micOpen, streaming: streaming, lastStreamStop: lastStreamStop), now: Date())
        log("capture plan: \(plan)")

        var result: Data?
        var midPlanMicClose = false
        do {
            for step in plan {
                switch step {
                case .serveLatestFrame:
                    guard let jpeg = latestFrameJPEG?() else { throw AiSeeError.streamUnavailable }
                    log("✅ photo served from live frame (\(jpeg.count) bytes)")
                    result = jpeg
                case .wait(let ms):
                    try await Task.sleep(for: .milliseconds(ms))
                case .closeMic:
                    await closeMic?()
                case .reopenMic:
                    await reopenMic?()
                case .shoot:
                    // Every `.wait` and every SDK await above suspended the actor, so
                    // the state this plan was built from may no longer hold. Re-read it
                    // here — this is the last line of defence against the F1 wedge.
                    guard self.connection === connection else { throw AiSeeError.notConnected }
                    if streaming {
                        guard let jpeg = latestFrameJPEG?() else { throw AiSeeError.streamUnavailable }
                        log("⚠️ live stream opened mid-plan — serving latest frame instead of shooting")
                        result = jpeg
                        continue
                    }
                    if micOpen && !micSuspendedForCapture {
                        log("⚠️ mic opened mid-plan — closing it before the shot")
                        await closeMic?()
                        midPlanMicClose = true
                        try await Task.sleep(for: .milliseconds(AiSeeSequencing.micCloseLeadMs))
                        try await Task.sleep(for: .milliseconds(AiSeeSequencing.micSettleMs))
                    }
                    result = try await AiSeePhotoCapture(connection: connection, log: log).capture()
                    if midPlanMicClose && !plan.contains(.reopenMic) { await reopenMic?() }
                }
            }
        } catch {
            // Any failure — including cancellation inside a `.wait` — must still hand
            // the mic back if the plan (or the mid-plan close above) took it away.
            if plan.contains(.reopenMic) || midPlanMicClose { await reopenMic?() }
            if let aiSee = error as? AiSeeError, case .deviceWedged = aiSee { unavailableUntilReconnect = true }
            throw error
        }
        guard let result else { throw AiSeeError.sdk(NSError(domain: "AiSee", code: -1, userInfo: [NSLocalizedDescriptionKey: "empty plan"])) }
        return result
    }

    // MARK: Live stream

    // The glasses serve ONE livestream. Two users share it: the host's camera
    // consumer (`startLiveStream`/`stopLiveStream`) and a clip recording
    // (`startClip`/`stopClip`). It opens for the first and stops only when the
    // last one leaves (`AiSeeSequencing.StreamUsers`), so closing Lens can't
    // cut a clip short and a clip can't blank the view the user is watching.

    /// - Parameters:
    ///   - onError: errors the running stream reports that are not an end of stream.
    ///     A start failure is thrown, not routed here.
    ///   - onTerminate: the stream ended — error text, or nil for a clean end.
    ///     Fired for SDK-initiated ends only; an explicit `stopLiveStream()` does not fire it.
    func startLiveStream(onFrame: @escaping @Sendable (AiSeeFrame) -> Void,
                         onError: @escaping @Sendable (String) -> Void,
                         onTerminate: @escaping @Sendable (String?) -> Void) async throws {
        // One operation at a time: a stream opened mid-capture would race the shot.
        guard !captureInFlight else { throw AiSeeError.captureInProgress }
        guard let connection else { throw AiSeeError.notConnected }
        if streamStarting && streamStartingFor == .vision { return }
        await waitForStreamTransition()
        if streamUsers.contains(.vision) { return }
        if let stream = liveStream, streaming {
            // A clip already holds the stream: join it.
            stream.setFrameHandler(onFrame)
            visionTerminate = onTerminate
            _ = streamUsers.add(.vision)
            log("livestream: camera joined the running stream")
            return
        }
        try await openStream(connection, for: .vision, onFrame: onFrame, onError: onError)
        guard streaming else { return }
        visionTerminate = onTerminate
        _ = streamUsers.add(.vision)
    }

    func stopLiveStream() async {
        if streamStarting && streamStartingFor == .vision {
            // `startLiveStream` is inside its start await; it honours this after it returns.
            pendingStreamStop = true
            log("livestream: stop requested during start — will stop once started")
            return
        }
        guard streamUsers.contains(.vision) else { return }
        visionTerminate = nil
        if streamUsers.remove(.vision) {
            await closeStream()
        } else {
            // A clip is still recording: keep the stream, drop the consumer.
            liveStream?.setFrameHandler(nil)
            log("livestream: camera left; stream kept for the clip")
        }
    }

    /// Serializes stream opens/closes: a user joining mid-close would attach to
    /// a stream that is about to die, and a second open would ask the glasses
    /// for a stream they are still tearing down.
    private func waitForStreamTransition() async {
        while streamStarting || streamStopping {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private var streamStartingFor: AiSeeSequencing.StreamUsers.User?
    private var streamStopping = false

    private func openStream(_ connection: IntelligenceDeviceConnection,
                            for user: AiSeeSequencing.StreamUsers.User,
                            onFrame: @escaping @Sendable (AiSeeFrame) -> Void,
                            onError: @escaping @Sendable (String) -> Void) async throws {
        streamStarting = true
        streamStartingFor = user
        defer { streamStarting = false; streamStartingFor = nil; pendingStreamStop = false }
        let stream = AiSeeLiveStream(connection: connection, log: log)
        try await stream.start(
            onFrame: onFrame,
            // Not fired today: start failures throw, terminations go to onTerminate.
            // Kept as the hook for a non-terminal error the running stream reports.
            onError: onError,
            onTerminate: { [weak self, weak stream] text in
                Task {
                    guard let self, let stream else { return }
                    await self.streamDidTerminate(stream, text: text)
                }
            })
        // `stream.start` suspended the actor. If a stop or a detach arrived while it
        // ran, tear the stream straight back down instead of installing it.
        guard !pendingStreamStop, self.connection === connection else {
            await stream.stop()
            lastStreamStop = Date()
            log("livestream: start abandoned (stopped/detached meanwhile)")
            return
        }
        liveStream = stream
        streaming = true
        latestFrameJPEG = { [weak stream] in
            stream?.latestFrame?.image?.jpegData(compressionQuality: 0.85)
        }
    }

    private func closeStream() async {
        guard let stream = liveStream else { return }
        streamStopping = true
        defer { streamStopping = false }
        await stream.stop()
        // `stream.stop()` suspended the actor: only clear state if this is still the
        // installed stream (a terminate callback may have replaced/cleared it).
        guard liveStream === stream else { return }
        liveStream = nil
        latestFrameJPEG = nil
        streaming = false
        streamUsers.removeAll()
        lastStreamStop = Date()
    }

    /// Called from `AiSeeLiveStream`'s `onTerminate` hook — an SDK-initiated
    /// end (clean or errored) must reset `streaming` even though nobody
    /// called `stopLiveStream()`. Guarded by identity so a stale callback
    /// from an already-replaced/stopped stream can't clobber current state.
    private func streamDidTerminate(_ stream: AiSeeLiveStream, text: String?) async {
        guard liveStream === stream else { return }
        liveStream = nil
        latestFrameJPEG = nil
        streaming = false
        streamUsers.removeAll()
        // Tell the host before tearing down: nothing about the cleanup below changes
        // what it needs to know, and it should not wait on the decoder drain.
        let terminate = visionTerminate
        visionTerminate = nil
        terminate?(text)
        endClip(reason: text ?? "the glasses ended the stream")
        // The SDK ended the stream, but nothing tore our side down: without this the
        // decoder session and the retained latest frame outlive it. Local cleanup
        // only — the SDK is already done with this stream.
        await stream.releaseAfterTermination()
        // Stamped after the cleanup, as in closeStream(), so the 1 s post-stream
        // settle is measured from when the stream was actually released.
        lastStreamStop = Date()
    }

    // MARK: Clip recording

    /// Every clip end — `stopClip()`, the length cap, the stream dying, a
    /// disconnect — is reported here exactly once: the finished file (nil when
    /// nothing usable was written) and, for an end the host did not ask for, why.
    /// When the file is nil the text also carries the recorder's diagnostics.
    func setClipObserver(_ observer: (@Sendable (_ file: URL?, _ interruption: String?) -> Void)?) {
        clipObserver = observer
    }

    var clipRecording: Bool { clip != nil }

    /// Records the livestream to an .mp4 — opening the stream if nothing else
    /// holds it. The file arrives on the clip observer when the clip ends.
    func startClip() async throws {
        guard clip == nil else { return }
        guard !captureInFlight else { throw AiSeeError.captureInProgress }
        guard let connection else { throw AiSeeError.notConnected }
        await waitForStreamTransition()
        guard clip == nil else { return }
        if liveStream == nil || !streaming {
            // Frames still decode with no consumer: a still asked for while
            // recording is served from the latest one.
            try await openStream(connection, for: .clip, onFrame: { _ in }, onError: { _ in })
        }
        guard let stream = liveStream, streaming else { throw AiSeeError.streamUnavailable }
        let recorder = AiSeeClipRecorder(url: AiSeeClipRecorder.makeTemporaryURL(),
                                         audioFormat: stream.audioFormat, log: log)
        stream.setRecorder(recorder)
        clip = recorder
        _ = streamUsers.add(.clip)
        clipGeneration &+= 1
        let generation = clipGeneration
        log("clip: recording (cap \(AiSeeSequencing.maxClipSeconds) s)")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(AiSeeSequencing.maxClipSeconds))
            await self?.stopClip(generation: generation)
        }
    }

    /// Stops the clip; the file goes to the clip observer. No-op if none runs.
    func stopClip() async { await stopClip(generation: nil) }

    private func stopClip(generation: Int?) async {
        guard let recorder = clip else { return }
        let capped = generation != nil
        if let generation, generation != clipGeneration { return }
        clip = nil
        liveStream?.setRecorder(nil)
        _ = streamUsers.remove(.clip)
        let file = await recorder.finish()
        let reason = capped ? "reached the \(AiSeeSequencing.maxClipSeconds / 60)-minute limit" : nil
        // An empty clip always carries what the stream delivered, so the host
        // can say WHY ("0 keyframes") instead of just "nothing saved".
        clipObserver?(file, file == nil ? [reason, recorder.diagnostics].compactMap { $0 }.joined(separator: "; ") : reason)
        // Decided AFTER the finish await, not before: the camera (or a new clip)
        // may have joined the still-running stream meanwhile.
        if streamUsers.isEmpty { await closeStream() }
    }

    /// Synchronous end for paths that can't await (stream death, detach): the
    /// file is finished and reported in the background.
    private func endClip(reason: String) {
        guard let recorder = clip else { return }
        clip = nil
        let observer = clipObserver
        Task {
            let file = await recorder.finish()
            observer?(file, file == nil ? "\(reason); \(recorder.diagnostics)" : reason)
        }
    }

    private var clip: AiSeeClipRecorder?
    private var clipGeneration = 0
    private var clipObserver: (@Sendable (_ file: URL?, _ interruption: String?) -> Void)?
    private var streamUsers = AiSeeSequencing.StreamUsers()
    private var visionTerminate: (@Sendable (String?) -> Void)?

    // MARK: Microphone

    func startMicrophone(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        // FINDINGS §1: the mic must never open across a snapshot().
        guard !captureInFlight else { throw AiSeeError.captureInProgress }
        guard let connection else { throw AiSeeError.notConnected }
        guard !micOpen && !micStarting else { return }
        micStarting = true
        defer { micStarting = false; pendingMicStop = false }
        let mic = AiSeeMicrophone(connection: connection, log: log)
        try await mic.start(onBuffer: onBuffer)
        // `mic.start` suspended the actor. If a stop or a detach arrived while it
        // ran, close the mic we just opened instead of installing it — the same
        // contract startLiveStream honours via pendingStreamStop.
        guard !pendingMicStop, self.connection === connection else {
            await mic.stop(releasingHandlers: microphone == nil)
            log("mic: start abandoned (stopped/detached meanwhile)")
            return
        }
        microphone = mic
        micBufferHandler = onBuffer
        micOpen = true
        // The still-photo plan uses these to close/reopen around a shot.
        closeMic = { [weak self] in await self?.closeMicForCapture() }
        reopenMic = { [weak self] in await self?.reopenMicAfterCapture() }
    }

    func stopMicrophone() async {
        if micStarting {
            // `startMicrophone` is inside its start await; it honours this after it returns.
            pendingMicStop = true
            log("mic: stop requested during start — will stop once started")
        }
        if micSuspendedForCapture || (micOpen && microphone == nil) {
            // No live mic object right now: either it is closed for a capture in
            // flight, or `reopenMicAfterCapture()` is still inside its `mic.start`
            // await. Cancel the pending reopen — it will stop the mic it started
            // rather than installing it.
            micSuspendedForCapture = false
            micReopenCancelled = true
            micBufferHandler = nil
            micOpen = false
            closeMic = nil
            reopenMic = nil
            log("mic: stop requested during capture — will not reopen")
            return
        }
        // Flip state synchronously, before the first await, so a
        // closeMicForCapture() interleaved during mic.stop() finds
        // `microphone == nil` and returns instead of racing this function to
        // stop the same mic object a second time.
        guard let mic = microphone else { return }
        microphone = nil
        micBufferHandler = nil
        micOpen = false
        closeMic = nil
        reopenMic = nil
        await mic.stop()
    }

    private var micSuspendedForCapture = false
    /// Set by `stopMicrophone()` / `attach(nil)` while a reopen is in flight, so the
    /// reopen can tell "still wanted" from "the user restarted the mic meanwhile".
    private var micReopenCancelled = false

    private func closeMicForCapture() async {
        // Flip state synchronously, before the first await, so a
        // stopMicrophone() interleaved during mic.stop() sees
        // micSuspendedForCapture already true and takes that branch instead
        // of racing this function to clear/rebuild `microphone`.
        guard let mic = microphone else { return }
        microphone = nil
        micSuspendedForCapture = true
        micReopenCancelled = false
        await mic.stop()
        log("mic: closed for capture")
    }

    private func reopenMicAfterCapture() async {
        guard micSuspendedForCapture, let conn = connection, let handler = micBufferHandler else { return }
        micSuspendedForCapture = false
        micReopenCancelled = false
        let mic = AiSeeMicrophone(connection: conn, log: log)
        do {
            try await mic.start(onBuffer: handler)
        } catch {
            microphone = nil
            micOpen = false
            log("mic: reopen failed: \(error)")
            return
        }
        // `mic.start` suspended the actor: `stopMicrophone()` or `attach(nil)` may
        // have run meanwhile. Don't install a mic nobody asked for — stop it instead.
        guard micOpen, !micReopenCancelled, connection === conn else {
            await mic.stop(releasingHandlers: microphone == nil)
            log("mic: reopen abandoned (stopped/detached meanwhile)")
            return
        }
        microphone = mic
        log("mic: reopened after capture")
    }
}

#else

/// Simulator / no-SDK stub. Mirrors the full public surface of the real actor so
/// hosts compile unchanged; every operation reports "not connected".
actor AiSeeDeviceCoordinator {
    init(log: @escaping AiSeeLog) {}
    var micOpen: Bool { false }
    var streaming: Bool { false }
    var unavailableUntilReconnect: Bool { false }
    func detach() {}
    func setKeyPressObserver(_ observer: (@Sendable (_ keyIndex: Int) -> Void)?) {}
    func setStateObserver(_ observer: (@Sendable (_ micOpen: Bool, _ streaming: Bool) -> Void)?) {}
    func capturePhoto() async throws -> Data { throw AiSeeError.notConnected }
    func startLiveStream(onFrame: @escaping @Sendable (AiSeeFrame) -> Void,
                         onError: @escaping @Sendable (String) -> Void,
                         onTerminate: @escaping @Sendable (String?) -> Void) async throws {
        throw AiSeeError.notConnected
    }
    func stopLiveStream() async {}
    var clipRecording: Bool { false }
    func setClipObserver(_ observer: (@Sendable (_ file: URL?, _ interruption: String?) -> Void)?) {}
    func startClip() async throws { throw AiSeeError.notConnected }
    func stopClip() async {}
    func startMicrophone(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        throw AiSeeError.notConnected
    }
    func stopMicrophone() async {}
}

#endif
