//
// HermesSessionViewModel+Glasses.swift
//
// The Ray-Ban side of the session: opening a DeviceSession (for the voice
// loop or camera-only), attaching the lens to a camera-only session, and
// the Meta AI camera grant.
//

import Foundation
import MWDATCamera
import MWDATCore
import os

/// A second button on the app notice, e.g. "Update glasses".
struct NoticeAction {
    let title: String
    let perform: @MainActor () -> Void
}

/// Why the glasses could not be used, phrased for the notice.
struct GlassesConnectIssue {
    let message: String
    let action: NoticeAction?
}

/// The `.dwaOutOfStuRange` update suggestion is shown once per app run.
@MainActor private var dwaOutOfRangeNoticeShown = false

/// Result of the pre-session readiness wait (see `waitForGlassesReady`).
enum GlassesReadiness: Equatable {
    case ready
    /// Glasses firmware too old: no session can start until it is updated.
    case firmwareUpdateRequired
    /// The SDK in this build is too old for the glasses.
    case sdkUpdateRequired
    /// No connected, compatible device within the wait. The session is
    /// still tried: the SDK may bring the link up itself.
    case timedOut
}

/// Thrown by the camera-only path when the glasses need an update.
struct GlassesNotReadyError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension HermesSessionViewModel {
    // MARK: - Readiness (Meta display-access skill)

    /// Wait (bounded) until the active device reports
    /// `linkState == .connected` and `compatibility() == .compatible`, as
    /// Meta's display-access skill requires before `createSession`. Every
    /// change in what the SDK reports is logged, so a device log shows
    /// exactly where a connect stops.
    func waitForGlassesReady(timeout: TimeInterval = 5) async -> GlassesReadiness {
        let deadline = Date().addingTimeInterval(timeout)
        var lastLine = ""
        while true {
            let id = deviceSelector.activeDevice
            let device = id.flatMap { wearables.deviceForIdentifier($0) }
            let compatibility = device?.compatibility()
            let line = "activeDevice=\(id ?? "nil") " +
                "link=\(device.map { String(describing: $0.linkState) } ?? "none") " +
                "compatibility=\(compatibility.map { String(describing: $0) } ?? "none")"
            if line != lastLine {
                NSLog("[EmoDrink] glasses readiness \(line)")
                lastLine = line
            }
            if let device, let compatibility {
                switch compatibility {
                case .deviceUpdateRequired:
                    return .firmwareUpdateRequired
                case .sdkUpdateRequired:
                    return .sdkUpdateRequired
                case .compatible where device.linkState == .connected:
                    return .ready
                default:
                    break
                }
            }
            if Date() >= deadline || Task.isCancelled {
                NSLog("[EmoDrink] glasses readiness: not ready after \(Int(timeout)) s, trying the session anyway")
                return .timedOut
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    /// The notice for a glasses firmware update, with the SDK's own
    /// "open the update" action.
    var firmwareUpdateIssue: GlassesConnectIssue {
        GlassesConnectIssue(
            message: "Your glasses need a software update before EmoDrink can use them. Update them in the Meta AI app.",
            action: NoticeAction(title: "Update glasses") { [weak self] in
                guard let self else { return }
                Task {
                    do {
                        try await self.wearables.openFirmwareUpdate()
                    } catch {
                        NSLog("[EmoDrink] openFirmwareUpdate failed: \(error.localizedDescription)")
                    }
                }
            }
        )
    }

    /// The notice for the EmoDrink app on the glasses being out of date.
    var datAppUpdateIssue: GlassesConnectIssue {
        GlassesConnectIssue(
            message: "The EmoDrink app on your glasses needs an update. Update it in the Meta AI app.",
            action: NoticeAction(title: "Update glasses app") { [weak self] in
                guard let self else { return }
                Task {
                    do {
                        try await self.wearables.openDATGlassesAppUpdate()
                    } catch {
                        NSLog("[EmoDrink] openDATGlassesAppUpdate failed: \(error.localizedDescription)")
                    }
                }
            }
        )
    }

    var sdkUpdateIssue: GlassesConnectIssue {
        GlassesConnectIssue(
            message: "This version of EmoDrink is too old for your glasses. Install the latest EmoDrink.",
            action: nil
        )
    }

    // MARK: - Camera-only session

    /// Connect the glasses camera WITHOUT starting the voice loop - no mic,
    /// no speech. The Lens view opens straight from the home
    /// screen: it reuses the live voice session when one exists, otherwise
    /// it creates its own DeviceSession, torn down by
    /// `releaseCameraSession()` when the view closes.
    ///
    /// Every successful return (including the early one when a session is
    /// already up) counts one user; pair each with `releaseCameraSession()`.
    func ensureCameraSession() async throws {
        if deviceSession != nil || lensSession != nil {
            lensUsers += 1
            return
        }

        switch await waitForGlassesReady() {
        case .firmwareUpdateRequired:
            let issue = firmwareUpdateIssue
            show(notice: issue.message, action: issue.action)
            throw GlassesNotReadyError(message: issue.message)
        case .sdkUpdateRequired:
            NSLog("[EmoDrink] camera session: SDK update required, trying anyway")
        case .ready, .timedOut:
            break
        }

        NSLog("[EmoDrink] camera session: createSession")
        let session = try wearables.createSession(deviceSelector: deviceSelector)
        do {
            try session.start()
        } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
            let issue = datAppUpdateIssue
            show(notice: issue.message, action: issue.action)
            throw GlassesNotReadyError(message: issue.message)
        }

        // Wait until the session actually starts - the camera stream is
        // rejected before that. Polling beats a state-stream subscription
        // here: no replay races, and Lens has no ongoing observer needs.
        let deadline = Date().addingTimeInterval(15)
        var lastState = session.state
        NSLog("[EmoDrink] camera session state \(lastState)")
        while session.state != .started {
            if session.state != lastState {
                lastState = session.state
                NSLog("[EmoDrink] camera session state \(lastState)")
            }
            if case .stopped = session.state {
                throw DeviceSessionError.unexpectedError(
                    description: "Glasses session stopped before starting"
                )
            }
            if Date() >= deadline {
                NSLog("[EmoDrink] camera session: not started within 15 s (state \(session.state))")
                session.stop()
                throw HermesCameraError.timeout
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        NSLog("[EmoDrink] camera session state started")

        // Observe the camera-only session like the voice one (and like
        // Meta's sample): every state is logged and async errors are
        // surfaced. Both streams finish when the session stops (SDK 0.9+).
        let lensStates = session.stateStream()
        let lensErrors = session.errorStream()
        Task { [weak self] in
            for await state in lensStates {
                NSLog("[EmoDrink] camera session state \(state)")
                if state == .stopped, let self, self.lensSession === session {
                    // The SDK ended it (glasses folded, link lost): drop it
                    // so the next ensure creates a fresh one.
                    NSLog("[EmoDrink] camera session stopped by the SDK")
                    self.lensSession = nil
                    self.lensUsers = 0
                    if self.deviceSession == nil {
                        self.displayManager.stop()
                        self.cameraManager.reset()
                    }
                }
            }
        }
        Task { [weak self] in
            for await error in lensErrors {
                NSLog("[EmoDrink] camera session error \(error)")
                await self?.handleSessionError(error)
            }
        }

        lensSession = session
        lensUsers += 1
        cameraManager.configure(session: session)
        if await ensureCameraPermission(interactive: false) == false {
            NSLog("[Hermes] glasses camera grant MISSING - streams will fail")
        }
    }

    /// Tear down the Lens-owned camera session. No-op when the camera is
    /// riding on the voice session (or nothing is connected).
    func releaseCameraSession() {
        lensUsers = max(0, lensUsers - 1)
        guard lensUsers == 0 else { return }
        tearDownCameraSession()
    }

    /// The voice session takes the glasses: close the camera-only session
    /// whoever holds it. Later releases from those holders clamp at zero.
    func dropCameraSession() {
        lensUsers = 0
        tearDownCameraSession()
    }

    private func tearDownCameraSession() {
        guard let session = lensSession else { return }
        lensSession = nil
        if deviceSession == nil { cameraManager.reset() }
        session.stop()
    }

    // MARK: - Display on a camera-only session

    /// Attach the display HUD to a camera-only session, so Lookup can put
    /// its result on the real lens without a voice session running. No-op
    /// when a voice session exists (its display is already attached) or
    /// the HUD is off. Best-effort like every display call.
    func attachDisplayToCameraSession() {
        guard displayHUDEnabled, deviceSession == nil, let session = lensSession else { return }
        displayManager.start(session: session)
    }

    /// Undo `attachDisplayToCameraSession()`. Call BEFORE
    /// `releaseCameraSession()` - the capability dies with the session.
    /// No-op when the display belongs to a voice session.
    func detachDisplayFromCameraSession() {
        guard deviceSession == nil else { return }
        displayManager.stop()
    }

    /// Step 1 for the glasses route: make sure GlassesLink (the proven
    /// session path, shared with the Glasses basics screen) has a started
    /// DeviceSession, and surface camera permission. Returns false (having
    /// recorded the reason in `glassesConnectIssue` when the SDK gave one)
    /// if the glasses can't be reached. The display is attached later, by
    /// the display manager, through the same GlassesLink.
    func connectGlassesSession() async -> Bool {
        // A firmware update blocks everything, so stop here.
        if glassesLink.needsFirmwareUpdate {
            glassesConnectIssue = firmwareUpdateIssue
            return false
        }
        if glassesLink.devices.contains(where: { $0.compatibility == .sdkUpdateRequired }) {
            // Recorded in case the session then fails; tried anyway.
            glassesConnectIssue = sdkUpdateIssue
        }

        NSLog("[EmoDrink] glasses session: GlassesLink.ensureSession (session \(glassesLink.sessionStateText))")
        guard await glassesLink.ensureSession() else {
            if glassesLink.requiresDATAppUpdate {
                // startSession shows this as the notice (with the update
                // action) instead of a bare "Glasses unreachable".
                glassesConnectIssue = datAppUpdateIssue
            }
            NSLog("[EmoDrink] glasses session failed (session \(glassesLink.sessionStateText))")
            return false
        }

        // Surface camera permission state early (non-interactive)
        Task { await ensureCameraPermission(interactive: false) }
        return true
    }

    func handleSessionState(_ state: DeviceSessionState) async {
        switch state {
        case .started:
            break
        case .stopped, .stopping:
            // While connecting, startSession sees the failure itself (and may
            // fall back to the phone); ending here would read as a Stop.
            guard connectionState != .connecting else { return }
            endSession()
        case .paused:
            connectionState = .disconnected
        case .starting, .idle:
            break
        @unknown default:
            break
        }
    }

    func handleSessionError(_ error: DeviceSessionError) async {
        NSLog("[EmoDrink] session error \(error) while \(connectionState)")
        if error == .dwaOutOfStuRange {
            // Nonblocking, and the SDK asks for a rate-limited suggestion:
            // once per app run, whatever the session is doing.
            guard !dwaOutOfRangeNoticeShown else { return }
            dwaOutOfRangeNoticeShown = true
            if let issue = noticeIssue(for: error) { show(notice: issue.message, action: issue.action) }
            return
        }
        if let issue = noticeIssue(for: error) {
            // While connecting, connectGlassesSession records it and
            // startSession shows it once, in the fallback notice.
            if connectionState == .connecting {
                glassesConnectIssue = issue
            } else {
                show(notice: issue.message, action: issue.action)
            }
            return
        }
        // While connecting the connect path reports the failure itself
        // (and may fall back to the phone); a second alert would race it.
        guard connectionState != .connecting else { return }
        show(error.localizedDescription)
    }

    /// Session errors that are news, not faults: shown as a notice, with
    /// the SDK's update action where there is one.
    func noticeIssue(for error: DeviceSessionError) -> GlassesConnectIssue? {
        switch error {
        case .datAppOnTheGlassesUpdateRequired:
            return datAppUpdateIssue
        case .insufficientSDKVersion:
            // Terminal (SDK 1.0): the glasses need an app built with a
            // newer SDK.
            return sdkUpdateIssue
        case .dwaOutOfStuRange:
            // Nonblocking (SDK 1.0): the session keeps working.
            return GlassesConnectIssue(
                message: "Your glasses software is out of date. EmoDrink still works, but updating in the Meta AI app is recommended.",
                action: firmwareUpdateIssue.action
            )
        default:
            return nil
        }
    }

    /// Check (and optionally request via Meta AI) the glasses camera
    /// permission. The interactive request switches to the Meta AI app.
    /// The Meta AI glasses-camera grant, requested interactively (it
    /// app-switches to Meta AI). Nothing in the normal flow ever asked for
    /// this - only the Photo test button did - so a user who never pressed
    /// that button had every glasses camera feature fail: Lens with "camera
    /// unavailable", "remember this person" with a note and no photo.
    @discardableResult
    func requestGlassesCameraAccess() async -> Bool {
        await ensureCameraPermission(interactive: true)
    }

    /// Asked once, the moment glasses finish pairing. This grant is what
    /// makes the glasses camera work at all, and leaving it to be discovered
    /// via a failure was the single worst bug in this app: Lens said "camera
    /// unavailable" and "remember this person" saved notes with no photo,
    /// with nothing anywhere explaining why.
    func ensureGlassesCameraAfterPairing() async {
        guard !askedForCameraGrant else { return }
        askedForCameraGrant = true
        if await glassesCameraGranted() == false {
            await requestGlassesCameraAccess()
        }
    }

    /// Non-interactive refresh, so the UI can warn before anything fails.
    func refreshGlassesCameraStatus() async {
        guard wearables.registrationState == .registered else { return }
        _ = await glassesCameraGranted()
    }

    /// Cheap check for "will the glasses camera work at all".
    func glassesCameraGranted() async -> Bool {
        return await ensureCameraPermission(interactive: false)
    }

    /// Through GlassesLink, which holds the grant for the whole app.
    func ensureCameraPermission(interactive: Bool) async -> Bool {
        await glassesLink.ensureCameraPermission(interactive: interactive)
    }
}
