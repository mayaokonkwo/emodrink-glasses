//
// HermesSessionViewModel+Glasses.swift
//
// The Ray-Ban side of the session: ensuring GlassesLink's session for the
// glasses route, the update notices, session errors as notices, and the
// Meta AI camera grant. Every DAT call goes through GlassesLink.
//

import Foundation
import MWDATCore

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

extension HermesSessionViewModel {
    // MARK: - Notices

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

    // MARK: - Glasses route

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

    /// GlassesLink's session reported an error (wired in init). Notices
    /// for update cases; other errors are shown only while an EmoDrink
    /// glasses session is running (the basics screen logs its own).
    func handleSessionError(_ error: DeviceSessionError) {
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
        guard connectionState != .connecting, glassesSessionRunning else { return }
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
