//
// GlassesLink.swift
// EmoDrink Glasses
//
// The ONE path to the glasses: registration and device state, the shared
// DeviceSession, the Display capability and the Camera stream. Extracted
// unchanged in behaviour from GlassesBasicsViewModel, the code proven on a
// Meta Ray-Ban Display (Test 1 lens card, Test 2 camera feed, Test 3 frame
// to the vending machine check). It is a near-copy of Meta's samples:
//
//   Display flow:  samples/DisplayAccess/DisplayAccess/ViewModels/DisplayViewModel.swift
//   Camera flow:   samples/CameraAccess/CameraAccess/ViewModels/CameraViewModel.swift
//   Device rows:   samples/DisplayAccess/DisplayAccess/ViewModels/WearablesViewModel.swift
//                  (DeviceItemState)
//
// Differences from the samples, all forced by sharing ONE DeviceSession
// between display and camera (one session per device):
//   - one session observer drives both capabilities; whichever asks first
//     creates the session, the other reuses it once `.started`.
//   - Display `.stopped` (and the display readiness timeout) only stop the
//     session when the camera is not using it.
//   - camera uses `.raw` + `frame.makeUIImage()` (camera-streaming SKILL.md)
//     instead of hvc1 + VideoFrameDecoder, which the sample needs only for
//     recording to file.
//   - several camera consumers (keyed) share the one stream; it stops when
//     the last one leaves.
//
// Created once in HermesGlassesApp and injected into the basics screen,
// the session view model, the display manager and the glasses vision
// source. This file imports no SwiftUI so the Display DSL names (Text,
// FlexBox) are unambiguous.
//

import Foundation
import MWDATCamera
import MWDATCore
import MWDATDisplay
import Observation
import UIKit

// MARK: - Device row (copy of DisplayAccess DeviceItemState)

@Observable
@MainActor
final class BasicsDeviceRow: Identifiable {
    let identifier: DeviceIdentifier
    var name: String
    var linkState: LinkState
    var compatibility: Compatibility
    var supportsDisplay: Bool

    @ObservationIgnored private var linkStateToken: AnyListenerToken?
    @ObservationIgnored private var compatibilityToken: AnyListenerToken?

    nonisolated var id: DeviceIdentifier { identifier }

    var linkText: String {
        switch linkState {
        case .connected: return "connected"
        case .connecting: return "connecting"
        case .disconnected: return "disconnected"
        }
    }

    var compatibilityText: String { compatibility.displayString }
    var needsFirmwareUpdate: Bool { compatibility == .deviceUpdateRequired }
    /// Link up and compatible: a session can be opened on it now.
    var isReady: Bool { linkState == .connected && compatibility == .compatible }

    init(device: Device, onChange: @escaping @MainActor (String) -> Void) {
        identifier = device.identifier
        name = device.nameOrId()
        linkState = device.linkState
        compatibility = device.compatibility()
        supportsDisplay = device.supportsDisplay()

        linkStateToken = device.addLinkStateListener { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.linkState = device.linkState
                self.compatibility = device.compatibility()
                self.name = device.nameOrId()
                onChange("device \(self.name): link \(self.linkText), compatibility \(self.compatibilityText)")
            }
        }
        compatibilityToken = device.addCompatibilityListener { [weak self] compat in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.compatibility = compat
                onChange("device \(self.name): compatibility \(self.compatibilityText)")
            }
        }
    }
}

// MARK: - Log line

struct BasicsLogLine: Identifiable {
    let id = UUID()
    let text: String
}

// MARK: - Link

@Observable
@MainActor
final class GlassesLink {
    // MARK: Status

    var registrationState: RegistrationState
    var devices: [BasicsDeviceRow] = []
    /// nil = no DeviceSession object exists.
    var sessionState: DeviceSessionState?
    /// Meta AI glasses-camera grant; nil = unknown.
    var cameraPermissionGranted: Bool?
    var requiresDATAppUpdate = false

    // MARK: Display

    /// nil = no Display capability attached.
    var displayState: DisplayState?
    /// Why the last display attach or send could not finish (timeout,
    /// addDisplay error, session stopped). Cleared when the display starts.
    private(set) var displayIssue: String?

    // MARK: Camera

    var streamState: StreamState = .stopped
    /// The latest glasses camera frame (Test 2's preview image).
    var latestFrame: UIImage?
    var framesReceived = 0
    var measuredFPS: Double = 0
    var resolutionText = "-"
    /// Camera was asked for and is not yet torn down.
    private(set) var cameraRequested = false

    // MARK: Log

    var log: [BasicsLogLine] = []

    // MARK: Derived

    var isRegistered: Bool { registrationState == .registered }
    var isRegistering: Bool { registrationState == .registering }
    var registrationText: String {
        switch registrationState {
        case .registered: return "registered"
        case .registering: return "registering"
        case .available: return "not registered"
        case .unavailable: return "unavailable (Meta AI app missing?)"
        }
    }
    var cameraPermissionText: String {
        switch cameraPermissionGranted {
        case .some(true): return "granted"
        case .some(false): return "denied"
        case .none: return "unknown"
        }
    }
    var sessionStateText: String { sessionState.map { $0.description } ?? "none" }
    var displayStateText: String { displayState.map(Self.describe) ?? "not attached" }
    var streamStateText: String { Self.describe(streamState) }
    /// Registered, and a device whose link is up and which is compatible.
    var deviceReady: Bool { isRegistered && devices.contains { $0.isReady } }
    var isSessionStarted: Bool { sessionState == .started }
    var isDisplayReady: Bool { displayState == .started }
    var isCameraStreaming: Bool { streamState == .streaming }
    var needsFirmwareUpdate: Bool { devices.contains { $0.needsFirmwareUpdate } }

    // MARK: Private

    @ObservationIgnored let wearables: WearablesInterface
    /// Created up front, as both samples do: AutoDeviceSelector fills from
    /// devicesStream(), and createSession throws noEligibleDevice if it is
    /// still empty.
    @ObservationIgnored private let displaySelector: AutoDeviceSelector
    @ObservationIgnored private let cameraSelector: AutoDeviceSelector

    @ObservationIgnored private var deviceSession: DeviceSession?
    @ObservationIgnored private var sessionStateTask: Task<Void, Never>?
    @ObservationIgnored private var sessionErrorTask: Task<Void, Never>?

    @ObservationIgnored private var display: Display?
    @ObservationIgnored private var displayStateToken: AnyListenerToken?
    @ObservationIgnored private var displayStateTask: Task<Void, Never>?
    @ObservationIgnored private var displayStateContinuation: AsyncStream<DisplayState>.Continuation?
    @ObservationIgnored private var displayReadinessTimeoutTask: Task<Void, Never>?
    /// DisplayViewModel's pendingAction: the view to send once
    /// DisplayState.started arrives. Built at send time, so a card that
    /// waited still carries the time it actually went out.
    @ObservationIgnored private var pendingSend: PendingSend?
    /// Add the display as soon as the session reaches `.started`.
    @ObservationIgnored private var wantDisplay = false

    @ObservationIgnored private var camera: MWDATCamera.Camera?
    @ObservationIgnored private let streamTokenBag = ListenerTokenBag()
    /// Add the camera as soon as the session reaches `.started`.
    @ObservationIgnored private var wantCamera = false
    /// A consumer arrived while the camera was stopping: start it again
    /// once the stop completes.
    @ObservationIgnored private var restartCameraAfterStop = false
    @ObservationIgnored private var cameraConsumers: [String: CameraConsumer] = [:]
    @ObservationIgnored private var fpsWindowStart: Date?
    @ObservationIgnored private var fpsWindowCount = 0

    @ObservationIgnored private var displayObservers: [String: @MainActor (DisplayState?) -> Void] = [:]
    @ObservationIgnored private var sessionObservers: [String: @MainActor (DeviceSessionState?) -> Void] = [:]

    @ObservationIgnored private var registrationTask: Task<Void, Never>?
    @ObservationIgnored private var deviceStreamTask: Task<Void, Never>?

    @ObservationIgnored private let logClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private struct PendingSend {
        let label: String
        let build: () -> FlexBox
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct CameraConsumer {
        let onFrame: @MainActor (UIImage) -> Void
        let onStop: (@MainActor () -> Void)?
    }

    init(wearables: WearablesInterface) {
        self.wearables = wearables
        self.registrationState = wearables.registrationState
        self.displaySelector = AutoDeviceSelector(
            wearables: wearables,
            filter: { $0.supportsDisplay() }
        )
        self.cameraSelector = AutoDeviceSelector(wearables: wearables)
        add("launch: registration \(registrationText)")
        observeWearables()
    }

    isolated deinit {
        registrationTask?.cancel()
        deviceStreamTask?.cancel()
        sessionStateTask?.cancel()
        sessionErrorTask?.cancel()
        displayStateTask?.cancel()
        displayReadinessTimeoutTask?.cancel()
        deviceSession?.stop()
    }

    // MARK: - Log

    func add(_ message: String) {
        NSLog("[Basics] %@", message)
        log.insert(BasicsLogLine(text: "\(logClock.string(from: Date())) \(message)"), at: 0)
        if log.count > 100 { log.removeLast(log.count - 100) }
    }

    // MARK: - Observers

    /// Called with the new DisplayState (nil = not attached) on every
    /// change, and when `displayIssue` changes. Keyed, so several owners
    /// can watch without clobbering each other.
    func observeDisplay(_ key: String, _ handler: @escaping @MainActor (DisplayState?) -> Void) {
        displayObservers[key] = handler
    }

    func observeSession(_ key: String, _ handler: @escaping @MainActor (DeviceSessionState?) -> Void) {
        sessionObservers[key] = handler
    }

    private func notifyDisplay() {
        let state = displayState
        for handler in displayObservers.values { handler(state) }
    }

    private func notifySession() {
        let state = sessionState
        for handler in sessionObservers.values { handler(state) }
    }

    private func setDisplayState(_ state: DisplayState?) {
        displayState = state
        if state == .started { displayIssue = nil }
        notifyDisplay()
    }

    private func setDisplayIssue(_ issue: String?) {
        guard displayIssue != issue else { return }
        displayIssue = issue
        notifyDisplay()
    }

    private func setSessionState(_ state: DeviceSessionState?) {
        sessionState = state
        notifySession()
    }

    // MARK: - Registration and devices (DisplayAccess WearablesViewModel)

    private func observeWearables() {
        deviceStreamTask = Task { [weak self] in
            guard let wearables = self?.wearables else { return }
            for await deviceIds in wearables.devicesStream() {
                guard let self, !Task.isCancelled else { return }
                self.devices = deviceIds.compactMap { id in
                    guard let device = wearables.deviceForIdentifier(id) else { return nil }
                    return BasicsDeviceRow(device: device) { [weak self] line in
                        self?.add(line)
                    }
                }
                let summary = self.devices.map {
                    "\($0.name) (link \($0.linkText), \($0.compatibilityText), display \($0.supportsDisplay ? "yes" : "no"))"
                }
                self.add("devices: \(summary.isEmpty ? "none" : summary.joined(separator: "; "))")
            }
        }

        registrationTask = Task { [weak self] in
            guard let wearables = self?.wearables else { return }
            for await state in wearables.registrationStateStream() {
                guard let self, !Task.isCancelled else { return }
                let changed = state != self.registrationState
                self.registrationState = state
                if changed { self.add("registration: \(self.registrationText)") }
                if state == .registered { await self.refreshCameraPermission() }
                // DisplayViewModel.observeRegistration: reset on .available / .unavailable.
                if changed, state == .available || state == .unavailable, self.deviceSession != nil {
                    self.add("registration lost: resetting session")
                    self.reset()
                }
            }
        }
    }

    func connectGlasses() {
        guard registrationState != .registering else { return }
        add("startRegistration() (opens Meta AI)")
        Task {
            do {
                try await wearables.startRegistration()
            } catch {
                add("startRegistration failed: \(error.localizedDescription) [\(error)]")
            }
        }
    }

    func openFirmwareUpdate() {
        add("openFirmwareUpdate()")
        Task {
            do {
                try await wearables.openFirmwareUpdate()
            } catch {
                add("openFirmwareUpdate failed: \(error.localizedDescription)")
            }
        }
    }

    func openDATGlassesAppUpdate() {
        add("openDATGlassesAppUpdate()")
        Task {
            do {
                try await wearables.openDATGlassesAppUpdate()
            } catch {
                add("openDATGlassesAppUpdate failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Camera permission

    func refreshCameraPermission() async {
        do {
            let status = try await wearables.checkPermissionStatus(.camera)
            cameraPermissionGranted = status == .granted
        } catch {
            cameraPermissionGranted = nil
            add("checkPermissionStatus(.camera) failed: \(error.localizedDescription)")
        }
    }

    /// The basics screen's button: fire and forget.
    func requestCameraPermission() {
        Task { await requestCameraPermissionNow() }
    }

    /// Opens Meta AI for the glasses-camera grant. Returns the outcome.
    @discardableResult
    func requestCameraPermissionNow() async -> Bool {
        add("requestPermission(.camera) (opens Meta AI)")
        do {
            let status = try await wearables.requestPermission(.camera)
            cameraPermissionGranted = status == .granted
            add("camera permission: \(cameraPermissionText)")
            return status == .granted
        } catch {
            add("requestPermission(.camera) failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Check the grant; with `interactive`, ask Meta AI when it is missing.
    func ensureCameraPermission(interactive: Bool) async -> Bool {
        await refreshCameraPermission()
        if cameraPermissionGranted == true { return true }
        guard interactive else { return false }
        return await requestCameraPermissionNow()
    }

    // MARK: - Shared device session

    /// Make sure a DeviceSession exists and wait (bounded) until it is
    /// `.started`. Returns false when it failed or did not start in time;
    /// a session still starting is left alone.
    @discardableResult
    func ensureSession(timeout: TimeInterval = 15) async -> Bool {
        if deviceSession == nil {
            createAndStartSession(selector: displaySelector, reason: "ensureSession")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            guard deviceSession != nil else { return false }
            if sessionState == .started { return true }
            if Date() >= deadline || Task.isCancelled {
                add("ensureSession: not started after \(Int(timeout)) s (session \(sessionStateText))")
                return false
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// DisplayViewModel.attachToDisplay / CameraViewModel.startSession: create,
    /// subscribe before start(), then start(). Capabilities are attached by
    /// handleSessionState(.started).
    private func createAndStartSession(selector: AutoDeviceSelector, reason: String) {
        do {
            let session = try wearables.createSession(deviceSelector: selector)
            deviceSession = session
            setSessionState(session.state)
            add("session created (for \(reason)), state \(session.state.description); calling start()")

            let stateStream = session.stateStream()
            let errorStream = session.errorStream()
            sessionStateTask = Task { [weak self] in
                for await state in stateStream {
                    guard let self, !Task.isCancelled else { return }
                    self.handleSessionState(state, session: session)
                }
            }
            sessionErrorTask = Task { [weak self] in
                for await error in errorStream {
                    guard let self, !Task.isCancelled else { return }
                    self.handleSessionError(error)
                }
            }

            try session.start()
        } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
            requiresDATAppUpdate = true
            add("session FAILED: \(DeviceSessionError.datAppOnTheGlassesUpdateRequired.localizedDescription)")
            failPendingWork(reason: "session could not start")
            teardownAll()
        } catch {
            add("session create/start FAILED: \(error.localizedDescription) [\(error)]")
            failPendingWork(reason: "session could not start")
            teardownAll()
        }
    }

    private func handleSessionState(_ state: DeviceSessionState, session: DeviceSession) {
        guard deviceSession === session else { return }
        setSessionState(state)
        add("session state: \(state.description)")
        switch state {
        case .started:
            requiresDATAppUpdate = false
            if wantDisplay, display == nil {
                wantDisplay = false
                setupDisplay(on: session)
            }
            if wantCamera, camera == nil {
                wantCamera = false
                Task { await beginCamera(on: session) }
            }
        case .stopped:
            failPendingWork(reason: "session stopped")
            teardownAll()
        case .idle, .starting, .paused, .stopping:
            break
        @unknown default:
            break
        }
    }

    private func handleSessionError(_ error: DeviceSessionError) {
        requiresDATAppUpdate = error == .datAppOnTheGlassesUpdateRequired
        add("session ERROR: \(error.localizedDescription) [\(error)]")
        if let pending = pendingSend {
            pendingSend = nil
            add("send FAILED: session error before display was ready")
            pending.continuation.resume(returning: false)
        }
    }

    // MARK: - Display (DisplayViewModel)

    /// Attach the display now (creating the session if needed) without
    /// sending anything. Same readiness deadline as a send.
    func ensureDisplay() {
        if display != nil {
            return
        }
        setDisplayIssue(nil)
        startDisplayReadinessTimeout()
        attachDisplayIfNeeded()
    }

    /// Send a view to the lens. When the display is not `.started` yet the
    /// view waits (pending-action pattern) and goes out on `.started`; it
    /// fails after 10 s. A newer pending send replaces an older one, which
    /// then returns false. Returns true when the SDK accepted the send.
    @discardableResult
    func send(_ view: FlexBox, label: String = "view") async -> Bool {
        await send(label: label) { view }
    }

    /// As `send(_:label:)`, but the view is built when it actually goes out.
    @discardableResult
    func send(label: String, _ build: @escaping () -> FlexBox) async -> Bool {
        if let display, displayState == .started {
            return await doSend(build(), label: label, on: display)
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            if let older = pendingSend {
                add("send superseded: \"\(older.label)\" replaced by \"\(label)\"")
                older.continuation.resume(returning: false)
            }
            pendingSend = PendingSend(label: label, build: build, continuation: continuation)
            add("send queued: \"\(label)\" waits for display .started")
            setDisplayIssue(nil)
            startDisplayReadinessTimeout()
            attachDisplayIfNeeded()
        }
    }

    /// Test 1's attach step: reuse the attached display, add it to a
    /// started session, or create the session with the display wanted.
    private func attachDisplayIfNeeded() {
        if display != nil {
            add("display already attached (\(displayStateText)); waiting for .started")
            return
        }
        if let session = deviceSession {
            if session.state == .started {
                setupDisplay(on: session)
            } else {
                wantDisplay = true
                add("session is \(session.state.description); display will be added at .started")
            }
            return
        }
        wantDisplay = true
        createAndStartSession(selector: displaySelector, reason: "display")
    }

    /// The SDK's clearDisplay(). Returns false (and logs) when the display
    /// is not started or the clear failed.
    @discardableResult
    func clear() async -> Bool {
        guard let display, displayState == .started else {
            add("clear ignored: display is \(displayStateText)")
            return false
        }
        do {
            try await display.clearDisplay()
            add("clearDisplay OK")
            return true
        } catch {
            add("clearDisplay FAILED: \(Self.describe(error))")
            return false
        }
    }

    private func setupDisplay(on session: DeviceSession) {
        guard display == nil else { return }
        do {
            let capability = try session.addDisplay()
            add("addDisplay OK; display.start()")

            let (stateStream, continuation) = AsyncStream.makeStream(of: DisplayState.self)
            displayStateContinuation = continuation
            displayStateToken = capability.statePublisher.listen { state in
                continuation.yield(state)
            }
            displayStateTask = Task { [weak self] in
                for await state in stateStream {
                    guard let self, !Task.isCancelled else { return }
                    await self.handleDisplayState(state, capability: capability)
                }
            }

            capability.start()
            display = capability
        } catch {
            add("addDisplay FAILED: \(error.localizedDescription) [\(error)]")
            failPendingDisplay(reason: "addDisplay failed")
            setDisplayIssue("Display attach failed: \(error.localizedDescription)")
            if camera == nil, !wantCamera {
                session.stop()
            }
        }
    }

    private func handleDisplayState(_ state: DisplayState, capability: Display) async {
        guard display === capability || display == nil else { return }
        setDisplayState(state)
        add("display state: \(Self.describe(state))")
        switch state {
        case .starting, .stopping:
            break
        case .started:
            finishDisplayReadinessWait()
            if let pending = pendingSend {
                pendingSend = nil
                let ok = await doSend(pending.build(), label: pending.label, on: capability)
                pending.continuation.resume(returning: ok)
            }
        case .stopped:
            displayStateToken = nil
            displayStateContinuation?.finish()
            displayStateContinuation = nil
            display = nil
            displayStateTask = nil
            failPendingDisplay(reason: "display stopped before it was ready")
            if displayIssue == nil { setDisplayIssue("Display stopped") }
            // DisplayViewModel stops the session here; only do that when the
            // camera is not sharing it.
            if camera == nil, !wantCamera, let deviceSession {
                add("display stopped and camera idle: stopping session")
                deviceSession.stop()
            }
        }
    }

    private func doSend(_ view: FlexBox, label: String, on capability: Display) async -> Bool {
        add("display.send(\(label))")
        do {
            try await capability.send(view)
            add("send OK")
            return true
        } catch {
            add("send FAILED: \(Self.describe(error))")
            return false
        }
    }

    private func startDisplayReadinessTimeout() {
        displayReadinessTimeoutTask?.cancel()
        displayReadinessTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            guard let self else { return }
            self.displayReadinessTimeoutTask = nil
            self.add("TIMEOUT: display not ready after 10 s (session \(self.sessionStateText), display \(self.displayStateText))")
            self.failPendingDisplay(reason: "timed out")
            self.setDisplayIssue("Timed out waiting for the display to become ready.")
            self.wantDisplay = false
            if let display = self.display {
                display.stop()
            } else if self.camera == nil, !self.wantCamera {
                self.deviceSession?.stop()
            }
        }
    }

    private func finishDisplayReadinessWait() {
        displayReadinessTimeoutTask?.cancel()
        displayReadinessTimeoutTask = nil
    }

    private func failPendingDisplay(reason: String) {
        if let pending = pendingSend {
            pendingSend = nil
            add("send FAILED: \(reason)")
            pending.continuation.resume(returning: false)
        }
        finishDisplayReadinessWait()
    }

    // MARK: - Camera (CameraViewModel)

    /// Start (or join) the glasses camera stream. `onFrame` gets every
    /// decoded frame on the main actor; `onStop` fires when the stream ends
    /// for any reason other than this consumer's own `stopCamera`. Opening
    /// the stream may redirect to Meta AI for the camera grant.
    func startCamera(
        consumer: String = "default",
        onFrame: @escaping @MainActor (UIImage) -> Void,
        onStop: (@MainActor () -> Void)? = nil
    ) {
        cameraConsumers[consumer] = CameraConsumer(onFrame: onFrame, onStop: onStop)
        if camera != nil, streamState == .stopping {
            restartCameraAfterStop = true
            add("camera consumer \(consumer) joined while stopping; restart after stop")
            return
        }
        guard !cameraRequested else {
            add("camera consumer \(consumer) joined the running camera")
            return
        }
        beginCameraRequest()
    }

    /// Leave the camera stream; it stops when no consumer is left.
    func stopCamera(consumer: String = "default") {
        guard cameraConsumers.removeValue(forKey: consumer) != nil else { return }
        guard cameraConsumers.isEmpty else {
            add("camera consumer \(consumer) left; \(cameraConsumers.count) still watching")
            return
        }
        restartCameraAfterStop = false
        wantCamera = false
        cameraRequested = false
        guard let activeCamera = camera else {
            add("camera stop: no camera attached")
            return
        }
        add("camera.stop()")
        streamState = .stopping
        activeCamera.stop()
    }

    func isCameraConsumer(_ consumer: String) -> Bool {
        cameraConsumers[consumer] != nil
    }

    private func beginCameraRequest() {
        cameraRequested = true
        framesReceived = 0
        measuredFPS = 0
        resolutionText = "-"
        fpsWindowStart = nil
        fpsWindowCount = 0

        if let session = deviceSession {
            if session.state == .started {
                Task { await beginCamera(on: session) }
            } else {
                wantCamera = true
                add("session is \(session.state.description); camera will be added at .started")
            }
            return
        }
        wantCamera = true
        createAndStartSession(selector: cameraSelector, reason: "camera")
    }

    /// CameraViewModel.startStreaming + confirmCameraPermissionRedirect +
    /// beginStream. Asking for the camera is the user's consent for the
    /// Meta AI redirect, so no extra confirm prompt.
    private func beginCamera(on session: DeviceSession) async {
        guard camera == nil else { return }
        do {
            if try await wearables.checkPermissionStatus(.camera) != .granted {
                cameraPermissionGranted = false
                add("camera permission not granted: requestPermission(.camera)")
                guard try await wearables.requestPermission(.camera) == .granted else {
                    add("camera FAILED: permission denied")
                    failCamera()
                    return
                }
            }
            cameraPermissionGranted = true
        } catch {
            add("camera permission check FAILED: \(error.localizedDescription)")
            failCamera()
            return
        }

        guard cameraRequested, camera == nil, deviceSession === session, session.state == .started else {
            add("camera not started: session \(sessionStateText) after permission step")
            failCamera()
            return
        }

        let config = StreamConfiguration(
            videoCodec: .raw,
            resolution: .low,
            frameRate: 24
        )
        do {
            guard let newCamera = try session.addCamera(config: config) else {
                add("addCamera returned nil")
                failCamera()
                return
            }
            camera = newCamera
            add("addCamera OK (raw, low, 24 fps); stream.start()")
            setupStreamListeners(for: newCamera.stream)
            streamState = .starting
            newCamera.stream.start()
        } catch {
            camera = nil
            add("addCamera FAILED: \(error.localizedDescription) [\(error)]")
            failCamera()
        }
    }

    private func setupStreamListeners(for stream: MWDATCamera.Stream) {
        stream.statePublisher.listen { [weak self] state in
            Task { @MainActor in self?.handleStreamState(state) }
        }.store(in: streamTokenBag)

        stream.videoFramePublisher.listen { [weak self] frame in
            let image = frame.makeUIImage()
            Task { @MainActor in self?.handleFrame(image) }
        }.store(in: streamTokenBag)

        stream.errorPublisher.listen { [weak self] error in
            Task { @MainActor in
                self?.add("stream ERROR: \(error.localizedDescription) [\(error)]")
            }
        }.store(in: streamTokenBag)
    }

    private func handleStreamState(_ state: StreamState) {
        streamState = state
        add("stream state: \(Self.describe(state))")
        if state == .stopped {
            clearStreamResources()
        }
    }

    private func handleFrame(_ image: UIImage?) {
        guard camera != nil else { return }
        framesReceived += 1
        let now = Date()
        if fpsWindowStart == nil { fpsWindowStart = now }
        fpsWindowCount += 1
        if let start = fpsWindowStart, now.timeIntervalSince(start) >= 1 {
            measuredFPS = Double(fpsWindowCount) / now.timeIntervalSince(start)
            fpsWindowStart = now
            fpsWindowCount = 0
        }
        guard let image else {
            if framesReceived == 1 { add("first frame: makeUIImage() returned nil") }
            return
        }
        latestFrame = image
        let size = image.cgImage.map { "\($0.width)x\($0.height)" }
            ?? "\(Int(image.size.width))x\(Int(image.size.height))"
        if size != resolutionText {
            resolutionText = size
            add("frame resolution: \(size)\(framesReceived == 1 ? " (first frame)" : "")")
        }
        for consumer in cameraConsumers.values {
            consumer.onFrame(image)
        }
    }

    /// CameraViewModel.clearStreamResources.
    private func clearStreamResources() {
        streamTokenBag.clear()
        camera?.stop()
        camera = nil
        cameraRequested = false
        streamState = .stopped
        latestFrame = nil
        if restartCameraAfterStop, !cameraConsumers.isEmpty {
            restartCameraAfterStop = false
            add("camera stopped; restarting for \(cameraConsumers.count) waiting consumer(s)")
            beginCameraRequest()
            return
        }
        restartCameraAfterStop = false
        dropCameraConsumers()
    }

    /// The camera could not start: tell every consumer and forget them.
    private func failCamera() {
        cameraRequested = false
        dropCameraConsumers()
    }

    private func dropCameraConsumers() {
        let stopped = cameraConsumers.values.compactMap(\.onStop)
        cameraConsumers.removeAll()
        for onStop in stopped { onStop() }
    }

    // MARK: - Reset

    func reset() {
        add("RESET: display.stop(), camera.stop(), session.stop()")
        if let pending = pendingSend {
            pendingSend = nil
            pending.continuation.resume(returning: false)
        }
        wantDisplay = false
        wantCamera = false
        display?.stop()
        camera?.stop()
        deviceSession?.stop()
        teardownAll()
        add("RESET done: local state cleared")
    }

    private func failPendingWork(reason: String) {
        failPendingDisplay(reason: reason)
        if wantDisplay {
            setDisplayIssue("Display session failed: \(reason)")
        }
        if wantCamera {
            add("camera FAILED: \(reason)")
        }
        wantDisplay = false
        wantCamera = false
    }

    /// DisplayViewModel.clearSessionState + CameraViewModel.cleanupSession.
    private func teardownAll() {
        if let pending = pendingSend {
            pendingSend = nil
            pending.continuation.resume(returning: false)
        }
        finishDisplayReadinessWait()
        displayStateTask?.cancel()
        displayStateTask = nil
        displayStateContinuation?.finish()
        displayStateContinuation = nil
        displayStateToken = nil
        let hadDisplay = display != nil
        display = nil
        if hadDisplay, displayIssue == nil { displayIssue = "Display stopped" }
        setDisplayState(nil)

        streamTokenBag.clear()
        camera = nil
        cameraRequested = false
        restartCameraAfterStop = false
        streamState = .stopped
        latestFrame = nil
        dropCameraConsumers()

        sessionStateTask?.cancel()
        sessionStateTask = nil
        sessionErrorTask?.cancel()
        sessionErrorTask = nil
        deviceSession = nil
        setSessionState(nil)
    }

    // MARK: - Descriptions

    static func describe(_ state: DisplayState) -> String {
        switch state {
        case .starting: return "starting"
        case .started: return "started"
        case .stopping: return "stopping"
        case .stopped: return "stopped"
        }
    }

    static func describe(_ state: StreamState) -> String {
        switch state {
        case .streaming: return "streaming"
        case .starting: return "starting"
        case .waitingForDevice: return "waiting for device"
        case .stopping: return "stopping"
        case .stopped: return "stopped"
        case .paused: return "paused"
        }
    }

    static func describe(_ error: Error) -> String {
        if let displayError = error as? DisplayError {
            return "\(displayError.description) [\(displayError)]"
        }
        return "\(error.localizedDescription) [\(error)]"
    }
}
