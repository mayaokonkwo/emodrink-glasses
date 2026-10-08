//
// GlassesBasicsViewModel.swift
// EmoDrink Glasses
//
// The three on-device diagnostics (Settings › Developer › Glasses basics):
//   Test 1  a card on the lens
//   Test 2  the glasses camera feed on the phone
//   Test 3  a glasses frame to the vending machine check, result on the lens
//
// A thin wrapper over GlassesLink, which holds the proven session, display
// and camera code (a near-copy of Meta's DisplayAccess and CameraAccess
// samples). This file keeps only the tests' own state: the text to send,
// the send-in-flight guard, the camera toggle, and the vending checks.
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

// MARK: - Lens card

/// What Test 1's send path puts on the glasses: a heading and a smaller
/// line. `detail == nil` means "Sent at <time>" (Test 1's own wording).
struct BasicsLensCard {
    let heading: String
    let detail: String?
}

// MARK: - View model

@Observable
@MainActor
final class GlassesBasicsViewModel {
    /// Camera consumer key for Test 2's feed.
    static let cameraConsumer = "basics"

    let link: GlassesLink

    // MARK: Status (from GlassesLink)

    var devices: [BasicsDeviceRow] { link.devices }
    var cameraPermissionText: String { link.cameraPermissionText }
    var requiresDATAppUpdate: Bool { link.requiresDATAppUpdate }
    var isRegistered: Bool { link.isRegistered }
    var isRegistering: Bool { link.isRegistering }
    var registrationText: String { link.registrationText }
    var sessionStateText: String { link.sessionStateText }
    var log: [BasicsLogLine] { link.log }

    // MARK: Test 1: display

    var displayText = "Hello from EmoDrink"
    private(set) var isSending = false
    var displayStateText: String { link.displayStateText }

    // MARK: Test 2: camera

    var previewImage: UIImage? { cameraRequested ? link.latestFrame : nil }
    var framesReceived: Int { link.framesReceived }
    var measuredFPS: Double { link.measuredFPS }
    var resolutionText: String { link.resolutionText }
    var streamStateText: String { link.streamStateText }
    /// Test 2 asked for the camera and it is not yet torn down (drives the
    /// toggle label).
    var cameraRequested: Bool { link.isCameraConsumer(Self.cameraConsumer) }

    // MARK: Test 3: vending machine check

    /// Last result line: "YES: vending machine", "NO" or "Failed: <reason>".
    var checkResultText = "-"
    var checkDurationText = "-"
    var checkCount = 0
    private(set) var isChecking = false
    private(set) var autoCheck = false
    /// FrameTools.canRunVisionChecks reason when checks cannot run.
    private(set) var visionBlockedReason: String?

    /// "Check now": camera feed running, a frame exists, vision available.
    var canCheckNow: Bool {
        cameraRequested && previewImage != nil && visionBlockedReason == nil && !isChecking
    }

    // MARK: Private

    @ObservationIgnored private var autoCheckTask: Task<Void, Never>?
    /// Bumped when the camera stops or on Reset, so a check still in flight
    /// does not put a stale result on the lens (or reopen a session).
    @ObservationIgnored private var checkGeneration = 0

    @ObservationIgnored private let sentClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init(link: GlassesLink) {
        self.link = link
        refreshVisionPreflight()
        // Session gone (Reset, glasses folded, registration lost): end the
        // 5 s loop and drop in-flight lens sends, as the teardown did.
        link.observeSession("basics") { [weak self] state in
            guard state == nil else { return }
            self?.stopVendingChecks(reason: "teardown")
        }
    }

    isolated deinit {
        autoCheckTask?.cancel()
    }

    func add(_ message: String) {
        link.add(message)
    }

    // MARK: - Registration and devices

    func connectGlasses() { link.connectGlasses() }
    func openFirmwareUpdate() { link.openFirmwareUpdate() }
    func openDATGlassesAppUpdate() { link.openDATGlassesAppUpdate() }
    func refreshCameraPermission() async { await link.refreshCameraPermission() }
    func requestCameraPermission() { link.requestCameraPermission() }

    // MARK: - Test 1: display

    func sendToGlasses() {
        sendToLens(BasicsLensCard(heading: displayText, detail: nil))
    }

    /// Test 1's send path, shared with Test 3: GlassesLink attaches the
    /// display if it is not attached yet, then sends the card.
    private func sendToLens(_ card: BasicsLensCard) {
        guard !isSending else {
            add("send ignored: a send is already in flight")
            return
        }
        isSending = true
        let clock = sentClock
        Task {
            defer { isSending = false }
            await link.send(label: "\"\(card.heading)\"") {
                let detail = card.detail ?? "Sent at \(clock.string(from: Date()))"
                return FlexBox(direction: .column, spacing: 12) {
                    Text(card.heading, style: .heading, color: .primary)
                    Text(detail, style: .body, color: .primary)
                }
                .padding(24)
            }
        }
    }

    func clearGlassesDisplay() {
        Task { await link.clear() }
    }

    // MARK: - Test 2: camera

    func toggleCamera() {
        if cameraRequested {
            stopCamera()
        } else {
            startCamera()
        }
    }

    private func startCamera() {
        link.startCamera(
            consumer: Self.cameraConsumer,
            onFrame: { _ in },
            onStop: { [weak self] in self?.stopVendingChecks(reason: "camera stream stopped") }
        )
    }

    private func stopCamera() {
        stopVendingChecks(reason: "camera stopped")
        link.stopCamera(consumer: Self.cameraConsumer)
    }

    // MARK: - Test 3: vending machine check

    func refreshVisionPreflight() {
        let check = FrameTools.canRunVisionChecks
        visionBlockedReason = check.ok ? nil : (check.reason ?? "vision checks unavailable")
        if let reason = visionBlockedReason {
            add("vending check unavailable: \(reason)")
            setAutoCheck(false)
        }
    }

    func checkNow() {
        guard visionBlockedReason == nil else {
            add("check ignored: \(visionBlockedReason ?? "vision unavailable")")
            return
        }
        guard !isChecking else {
            add("check ignored: a check is already in flight")
            return
        }
        guard cameraRequested, let frame = previewImage else {
            add("check ignored: no camera frame")
            return
        }
        guard let jpeg = FrameTools.downscaledJPEG(frame, maxSide: 1024, quality: 0.7) else {
            finishCheck(result: "Failed: could not encode frame", heading: "Check failed", seconds: 0, generation: checkGeneration)
            return
        }

        isChecking = true
        let generation = checkGeneration
        let number = checkCount + 1
        add("check #\(number): request sent (\(jpeg.count / 1024) KB JPEG, \(DirectClient.provider.displayName))")
        let started = Date()
        Task { [weak self] in
            do {
                let reply = try await DirectClient().askOneShot(
                    systemPrompt: VendingMachineDetector.systemPrompt,
                    userText: VendingMachineDetector.userText,
                    photoJPEG: jpeg,
                    timeout: 20)
                let seconds = Date().timeIntervalSince(started)
                guard let self else { return }
                let yes = VendingMachineDetector.isYes(reply)
                let oneLine = reply.replacingOccurrences(of: "\n", with: " ")
                self.add("check #\(number): reply \"\(oneLine.prefix(120))\" in \(String(format: "%.2f", seconds)) s")
                self.finishCheck(
                    result: yes ? "YES: vending machine" : "NO",
                    heading: yes ? "Vending machine" : "No machine",
                    seconds: seconds, generation: generation)
            } catch {
                let seconds = Date().timeIntervalSince(started)
                guard let self else { return }
                let reason = error.localizedDescription
                self.add("check #\(number): ERROR \(reason) [\(error)] after \(String(format: "%.2f", seconds)) s")
                self.finishCheck(result: "Failed: \(reason)", heading: "Check failed", seconds: seconds, generation: generation)
            }
        }
    }

    private func finishCheck(result: String, heading: String, seconds: Double, generation: Int) {
        isChecking = false
        checkCount += 1
        checkResultText = result
        checkDurationText = String(format: "%.2f s", seconds)
        guard generation == checkGeneration else {
            add("check result not sent to lens: camera stopped or reset meanwhile")
            return
        }
        let at = sentClock.string(from: Date())
        sendToLens(BasicsLensCard(
            heading: heading,
            detail: "Checked at \(at) (\(String(format: "%.1f", seconds)) s)"))
    }

    func setAutoCheck(_ on: Bool) {
        if on {
            guard !autoCheck else { return }
            guard visionBlockedReason == nil, cameraRequested else {
                add("auto check not started: \(visionBlockedReason ?? "camera feed not running")")
                return
            }
            autoCheck = true
            add("auto check ON (every 5 s)")
            autoCheckTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard let self, self.autoCheck else { return }
                    if self.isChecking {
                        self.add("auto check: tick skipped, a check is in flight")
                    } else if self.previewImage == nil {
                        self.add("auto check: tick skipped, no frame")
                    } else {
                        self.checkNow()
                    }
                }
            }
        } else {
            autoCheckTask?.cancel()
            autoCheckTask = nil
            guard autoCheck else { return }
            autoCheck = false
            add("auto check OFF")
        }
    }

    /// Camera stop or Reset: end the 5 s loop and drop in-flight lens sends.
    private func stopVendingChecks(reason: String) {
        checkGeneration += 1
        if autoCheck { add("auto check stopped: \(reason)") }
        setAutoCheck(false)
    }

    // MARK: - Reset

    func reset() {
        stopVendingChecks(reason: "teardown")
        link.reset()
    }
}
