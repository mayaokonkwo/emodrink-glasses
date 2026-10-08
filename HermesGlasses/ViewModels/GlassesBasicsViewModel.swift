//
// GlassesBasicsViewModel.swift
// EmoDrink Glasses
//
// Bare diagnostics for the two fundamentals: text on the glasses display
// and a live glasses camera feed on the phone. Deliberately NOT built on the
// Hermes session machinery: it is a near-copy of Meta's own samples so it
// exercises only the DAT SDK path.
//
//   Display flow:  samples/DisplayAccess/DisplayAccess/ViewModels/DisplayViewModel.swift
//   Camera flow:   samples/CameraAccess/CameraAccess/ViewModels/CameraViewModel.swift
//   Device rows:   samples/DisplayAccess/DisplayAccess/ViewModels/WearablesViewModel.swift
//                  (DeviceItemState)
//
// Differences from the samples, all forced by sharing ONE DeviceSession
// between the two tests (one session per device):
//   - one session observer drives both capabilities; whichever test asks
//     first creates the session, the other reuses it once `.started`.
//   - Display `.stopped` (and the display readiness timeout) only stop the
//     session when the camera is not using it.
//   - camera uses `.raw` + `frame.makeUIImage()` (camera-streaming SKILL.md)
//     instead of hvc1 + VideoFrameDecoder, which the sample needs only for
//     recording to file.
//
// This file imports no SwiftUI so the Display DSL names (Text, FlexBox)
// are unambiguous.
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

// MARK: - View model

@Observable
@MainActor
final class GlassesBasicsViewModel {
    // MARK: Status

    var registrationState: RegistrationState
    var devices: [BasicsDeviceRow] = []
    /// nil = no DeviceSession object exists.
    var sessionState: DeviceSessionState?
    var cameraPermissionText = "unknown"
    var requiresDATAppUpdate = false

    // MARK: Test 1: display

    var displayText = "Hello from EmoDrink"
    /// nil = no Display capability attached.
    var displayState: DisplayState?
    private(set) var isSending = false

    // MARK: Test 2: camera

    var streamState: StreamState = .stopped
    var previewImage: UIImage?
    var framesReceived = 0
    var measuredFPS: Double = 0
    var resolutionText = "-"
    /// Camera was asked for and is not yet torn down (drives the toggle label).
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
    var sessionStateText: String { sessionState.map { $0.description } ?? "none" }
    var displayStateText: String { displayState.map(Self.describe) ?? "not attached" }
    var streamStateText: String { Self.describe(streamState) }

    // MARK: Private

    @ObservationIgnored private let wearables: WearablesInterface
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
    /// DisplayViewModel's pendingAction: the text to send once DisplayState.started arrives.
    @ObservationIgnored private var pendingDisplayText: String?
    /// Add the display as soon as the session reaches `.started`.
    @ObservationIgnored private var wantDisplay = false

    @ObservationIgnored private var camera: MWDATCamera.Camera?
    @ObservationIgnored private let streamTokenBag = ListenerTokenBag()
    /// Add the camera as soon as the session reaches `.started`.
    @ObservationIgnored private var wantCamera = false
    @ObservationIgnored private var fpsWindowStart: Date?
    @ObservationIgnored private var fpsWindowCount = 0

    @ObservationIgnored private var registrationTask: Task<Void, Never>?
    @ObservationIgnored private var deviceStreamTask: Task<Void, Never>?

    @ObservationIgnored private let logClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    @ObservationIgnored private let sentClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

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

    func refreshCameraPermission() async {
        do {
            let status = try await wearables.checkPermissionStatus(.camera)
            cameraPermissionText = status == .granted ? "granted" : "denied"
        } catch {
            cameraPermissionText = "unknown"
            add("checkPermissionStatus(.camera) failed: \(error.localizedDescription)")
        }
    }

    func requestCameraPermission() {
        add("requestPermission(.camera) (opens Meta AI)")
        Task {
            do {
                let status = try await wearables.requestPermission(.camera)
                cameraPermissionText = status == .granted ? "granted" : "denied"
                add("camera permission: \(cameraPermissionText)")
            } catch {
                add("requestPermission(.camera) failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Shared device session

    /// DisplayViewModel.attachToDisplay / CameraViewModel.startSession: create,
    /// subscribe before start(), then start(). Capabilities are attached by
    /// handleSessionState(.started).
    private func createAndStartSession(selector: AutoDeviceSelector, reason: String) {
        do {
            let session = try wearables.createSession(deviceSelector: selector)
            deviceSession = session
            sessionState = session.state
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
        sessionState = state
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
        if pendingDisplayText != nil {
            pendingDisplayText = nil
            isSending = false
            add("send FAILED: session error before display was ready")
        }
    }

    // MARK: - Test 1: display (DisplayViewModel)

    func sendToGlasses() {
        let text = displayText
        guard !isSending else {
            add("send ignored: a send is already in flight")
            return
        }
        isSending = true

        if let display, displayState == .started {
            Task { await doSend(text, on: display) }
            return
        }

        // Pending-action pattern: queue, then send on DisplayState.started.
        pendingDisplayText = text
        add("send queued: \"\(text)\" waits for display .started")
        startDisplayReadinessTimeout()

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

    func clearGlassesDisplay() {
        guard let display, displayState == .started else {
            add("clear ignored: display is \(displayStateText)")
            return
        }
        Task {
            do {
                try await display.clearDisplay()
                add("clearDisplay OK")
            } catch {
                add("clearDisplay FAILED: \(Self.describe(error))")
            }
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
            if camera == nil, !wantCamera {
                session.stop()
            }
        }
    }

    private func handleDisplayState(_ state: DisplayState, capability: Display) async {
        guard display === capability || display == nil else { return }
        displayState = state
        add("display state: \(Self.describe(state))")
        switch state {
        case .starting, .stopping:
            break
        case .started:
            finishDisplayReadinessWait()
            if let text = pendingDisplayText {
                pendingDisplayText = nil
                await doSend(text, on: capability)
            }
        case .stopped:
            displayStateToken = nil
            displayStateContinuation?.finish()
            displayStateContinuation = nil
            display = nil
            displayStateTask = nil
            failPendingDisplay(reason: "display stopped before it was ready")
            // DisplayViewModel stops the session here; only do that when the
            // camera is not sharing it.
            if camera == nil, !wantCamera, let deviceSession {
                add("display stopped and camera idle: stopping session")
                deviceSession.stop()
            }
        }
    }

    private func doSend(_ text: String, on capability: Display) async {
        defer { isSending = false }
        let sentAt = sentClock.string(from: Date())
        let view = FlexBox(direction: .column, spacing: 12) {
            Text(text, style: .heading, color: .primary)
            Text("Sent at \(sentAt)", style: .body, color: .primary)
        }
        .padding(24)
        add("display.send(\"\(text)\", sent at \(sentAt))")
        do {
            try await capability.send(view)
            add("send OK")
        } catch {
            add("send FAILED: \(Self.describe(error))")
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
        if pendingDisplayText != nil {
            add("send FAILED: \(reason)")
        }
        pendingDisplayText = nil
        isSending = false
        finishDisplayReadinessWait()
    }

    // MARK: - Test 2: camera (CameraViewModel)

    func toggleCamera() {
        if cameraRequested {
            stopCamera()
        } else {
            startCamera()
        }
    }

    private func startCamera() {
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
    /// beginStream. The tap on "Start camera feed" is the user's consent for
    /// the Meta AI redirect, so no extra confirm prompt.
    private func beginCamera(on session: DeviceSession) async {
        guard camera == nil else { return }
        do {
            if try await wearables.checkPermissionStatus(.camera) != .granted {
                cameraPermissionText = "denied"
                add("camera permission not granted: requestPermission(.camera)")
                guard try await wearables.requestPermission(.camera) == .granted else {
                    add("camera FAILED: permission denied")
                    cameraRequested = false
                    return
                }
            }
            cameraPermissionText = "granted"
        } catch {
            add("camera permission check FAILED: \(error.localizedDescription)")
            cameraRequested = false
            return
        }

        guard cameraRequested, camera == nil, deviceSession === session, session.state == .started else {
            add("camera not started: session \(sessionStateText) after permission step")
            cameraRequested = false
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
                cameraRequested = false
                return
            }
            camera = newCamera
            add("addCamera OK (raw, low, 24 fps); stream.start()")
            setupStreamListeners(for: newCamera.stream)
            streamState = .starting
            newCamera.stream.start()
        } catch {
            camera = nil
            cameraRequested = false
            add("addCamera FAILED: \(error.localizedDescription) [\(error)]")
        }
    }

    private func stopCamera() {
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
        previewImage = image
        let size = image.cgImage.map { "\($0.width)x\($0.height)" }
            ?? "\(Int(image.size.width))x\(Int(image.size.height))"
        if size != resolutionText {
            resolutionText = size
            add("frame resolution: \(size)\(framesReceived == 1 ? " (first frame)" : "")")
        }
    }

    /// CameraViewModel.clearStreamResources.
    private func clearStreamResources() {
        streamTokenBag.clear()
        camera?.stop()
        camera = nil
        cameraRequested = false
        streamState = .stopped
        previewImage = nil
    }

    // MARK: - Reset

    func reset() {
        add("RESET: display.stop(), camera.stop(), session.stop()")
        pendingDisplayText = nil
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
        if wantCamera {
            add("camera FAILED: \(reason)")
        }
        wantDisplay = false
        wantCamera = false
    }

    /// DisplayViewModel.clearSessionState + CameraViewModel.cleanupSession.
    private func teardownAll() {
        isSending = false
        pendingDisplayText = nil
        finishDisplayReadinessWait()
        displayStateTask?.cancel()
        displayStateTask = nil
        displayStateContinuation?.finish()
        displayStateContinuation = nil
        displayStateToken = nil
        display = nil
        displayState = nil

        streamTokenBag.clear()
        camera = nil
        cameraRequested = false
        streamState = .stopped
        previewImage = nil

        sessionStateTask?.cancel()
        sessionStateTask = nil
        sessionErrorTask?.cancel()
        sessionErrorTask = nil
        deviceSession = nil
        sessionState = nil
    }

    // MARK: - Descriptions

    private static func describe(_ state: DisplayState) -> String {
        switch state {
        case .starting: return "starting"
        case .started: return "started"
        case .stopping: return "stopping"
        case .stopped: return "stopped"
        }
    }

    private static func describe(_ state: StreamState) -> String {
        switch state {
        case .streaming: return "streaming"
        case .starting: return "starting"
        case .waitingForDevice: return "waiting for device"
        case .stopping: return "stopping"
        case .stopped: return "stopped"
        case .paused: return "paused"
        }
    }

    private static func describe(_ error: Error) -> String {
        if let displayError = error as? DisplayError {
            return "\(displayError.description) [\(displayError)]"
        }
        return "\(error.localizedDescription) [\(error)]"
    }
}
