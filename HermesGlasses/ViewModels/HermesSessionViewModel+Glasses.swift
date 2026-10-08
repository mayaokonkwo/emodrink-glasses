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

extension HermesSessionViewModel {
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

        let session = try wearables.createSession(deviceSelector: deviceSelector)
        try session.start()

        // Wait until the session actually starts - the camera stream is
        // rejected before that. Polling beats a state-stream subscription
        // here: no replay races, and Lens has no ongoing observer needs.
        let deadline = Date().addingTimeInterval(15)
        while session.state != .started {
            if case .stopped = session.state {
                throw DeviceSessionError.unexpectedError(
                    description: "Glasses session stopped before starting"
                )
            }
            if Date() >= deadline {
                session.stop()
                throw HermesCameraError.timeout
            }
            try await Task.sleep(nanoseconds: 150_000_000)
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

    /// Step 1 for the glasses route: create the DeviceSession, hand the
    /// camera its session, and surface camera permission. Returns false
    /// (having already shown the reason) if the glasses can't be reached.
    func connectGlassesSession() async -> Bool {
        // 1. Create and start a device session with the glasses
        let session: DeviceSession
        do {
            session = try wearables.createSession(deviceSelector: deviceSelector)
        } catch {
            NSLog("[Hermes] createSession failed: \(error.localizedDescription)")
            return false
        }
        deviceSession = session

        // Single state observer - use a continuation to signal readiness
        do {
            // Boxed flag so both the Task and outer scope can access it
            let done = OSAllocatedUnfairLock(initialState: false)

            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let stateStream = session.stateStream()
                let errorStream = session.errorStream()

                sessionObserverTask = Task { [weak self] in
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for await state in stateStream {
                                if Task.isCancelled { return }
                                switch state {
                                case .started:
                                    done.withLock { finished in
                                        if !finished {
                                            finished = true
                                            cont.resume()
                                        }
                                    }
                                    await self?.handleSessionState(state)
                                case .stopped, .stopping:
                                    done.withLock { finished in
                                        if !finished {
                                            finished = true
                                            cont.resume(
                                                throwing: DeviceSessionError.unexpectedError(
                                                    description: "Session stopped unexpectedly"
                                                )
                                            )
                                            return
                                        }
                                    }
                                    await self?.handleSessionState(state)
                                    return
                                case .paused:
                                    await self?.handleSessionState(state)
                                case .starting, .idle:
                                    break
                                @unknown default:
                                    break
                                }
                            }
                        }
                        group.addTask {
                            for await error in errorStream {
                                if Task.isCancelled { return }
                                done.withLock { finished in
                                    if !finished {
                                        finished = true
                                        cont.resume(throwing: error)
                                        return
                                    }
                                }
                                await self?.handleSessionError(error)
                                return
                            }
                        }
                    }
                }

                // Now start the session
                do {
                    try session.start()
                } catch {
                    done.withLock { finished in
                        if !finished {
                            finished = true
                            cont.resume(throwing: error)
                        }
                    }
                    return
                }

                // Check if already started (race: started before streams iterate)
                done.withLock { finished in
                    if !finished && session.state == .started {
                        finished = true
                        cont.resume()
                    }
                }
            }
        } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
            show("Glasses app needs update. Please update in Meta AI app.")
            connectionState = .disconnected
            return false
        } catch {
            // Caller decides whether this is fatal or a cue to use the phone,
            // so no alert here - just the breadcrumb.
            NSLog("[Hermes] glasses session failed: \(error.localizedDescription)")
            deviceSession = nil
            return false
        }

        // Session is started - set up Hermes and audio
        isGlassesConnected = true
        cameraManager.configure(session: session)
        // Surface camera permission state early (non-interactive)
        Task { await ensureCameraPermission(interactive: false) }

        return true
    }

    func handleSessionState(_ state: DeviceSessionState) async {
        switch state {
        case .started:
            isGlassesConnected = true
        case .stopped, .stopping:
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
        show(error.localizedDescription)
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

    func ensureCameraPermission(interactive: Bool) async -> Bool {
        do {
            let status = try await wearables.checkPermissionStatus(.camera)
            if status == .granted {
                cameraPermissionGranted = true
                return true
            }
            if interactive {
                let result = try await wearables.requestPermission(.camera)
                cameraPermissionGranted = (result == .granted)
                return result == .granted
            }
            cameraPermissionGranted = false
            return false
        } catch {
            cameraPermissionGranted = false
            return false
        }
    }
}
