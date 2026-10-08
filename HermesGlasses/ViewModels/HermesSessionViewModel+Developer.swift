//
// HermesSessionViewModel+Developer.swift
//
// The Developer test panel (Settings › Glasses › Developer). Every test
// works from a cold start: it brings its own camera session when none runs.
//

import Foundation
import MWDATCore
import UIKit

extension HermesSessionViewModel {
    // MARK: - Test panel

    /// Run `body` with a camera session available, creating a temporary
    /// camera-only one if nothing is running and tearing it down after.
    /// The test panel is for diagnosing a broken setup - insisting on a
    /// working session first is exactly backwards.
    func withCameraSession<T>(
        _ body: () async throws -> T
    ) async throws -> T {
        try await ensureCameraSession()
        defer { releaseCameraSession() }
        return try await body()
    }

    /// Camera alone - no Hermes involved. Runs the interactive permission
    /// flow (opens Meta AI) if camera access was never granted, and brings
    /// its own session so it works from a cold start.
    func testPhoto() async {
        await runTest("Photo") { [self] in
            if visionRoute == .glasses {
                guard await ensureCameraPermission(interactive: true) else {
                    throw TestFailure("Camera permission denied in Meta AI app")
                }
            }
            let source = vision.sourceLabel
            let photo = try await withCameraSession {
                try await captureVisionPhoto()
            }
            pendingPhoto = photo
            lastTestPhoto = UIImage(data: photo)
            lastTestPhotoSource = "\(photo.count / 1024) KB from the \(source)"
            addTurn(
                userText: "[Test Photo]",
                agentText: "Captured \(photo.count / 1024) KB from the \(source)"
            )
        }
    }

    /// Round trip through the active brain → response text (+TTS)
    func testQuery() async {
        await runTest("Query") { [self] in
            try await awaitTestReply {
                submitQuery("Respond with exactly: OK")
            }
        }
    }

    /// Pure output test: play a locally generated tone through the current
    /// audio route (glasses in glasses mode). No agent involved.
    func testSound() async {
        await runTest("Sound") { [self] in
            if connectionState == .disconnected {
                // No session: playback-only mode (phone speaker or whatever
                // route iOS picks)
                try audioManager.preparePlaybackOnly()
            } else {
                connectionState = .speaking
            }
            await audioManager.playResponse(HermesAudioManager.makeTestTone())
            lastTestAudioRoute = audioManager.currentOutputName
        }
    }

    /// Full photo pipeline via a canned visual query
    func testVisualQuery() async {
        await runTest("Visual") { [self] in
            // Borrowed for the whole round trip: the capture happens inside
            // submitQuery, so the session has to outlive this call - and
            // waiting for the answer is what tells us it did. This used to
            // call ensureCameraSession() and walk away, leaving a cold-start
            // session running with nothing on any path to release it
            // (endSession() only tears down the VOICE session).
            try await withCameraSession {
                try await awaitTestReply {
                    submitQuery("What am I looking at? Answer in one short sentence.")
                }
            }
        }
    }

    /// Developer panel › Display (spec section 8). With no session running it
    /// opens a DeviceSession for the display alone, waits up to 5 s for the
    /// lens to attach, sends the test card, keeps it 4 s, and reports one of:
    /// sent, no glasses, display session failed (with the SDK error), or the
    /// glasses mic hiding the HUD.
    func testDisplay() async {
        testRunning.insert("Display")
        defer { testRunning.remove("Display") }
        let report = await runDisplayTest()
        displayTestReport = report.message
        testResults["Display"] = report.isSuccess ? "" : report.message
        lastTestFailure = report.isSuccess ? nil : report.message
    }

    private func runDisplayTest() async -> DisplayTestReport {
        if let early = DisplayTestReport.preflight(glassesReachable: glassesAvailable || deviceSession != nil,
                                                   glassesMicActive: lensBlockedByCallScreen) {
            return early
        }
        // acquired: this test holds one camera-session use and releases it.
        // attachedHere: the test attached the lens to a camera-only session
        // that did not have it (HUD off), so it detaches it again afterwards.
        var acquired = false
        var attachedHere = false
        if let session = deviceSession {
            if displayManager.status != .connected {
                displayManager.stop()
                displayManager.start(session: session)
            }
        } else {
            do {
                try await ensureCameraSession()
            } catch {
                return .sessionFailed(error.localizedDescription)
            }
            acquired = true
            guard let session = lensSession else {
                releaseCameraSession()
                return .sessionFailed("no device session")
            }
            if displayManager.status != .connected {
                attachedHere = true
                displayManager.stop()
                displayManager.start(session: session)
            }
        }

        let deadline = Date().addingTimeInterval(DisplayTestReport.attachTimeoutSeconds)
        while displayManager.status != .connected, Date() < deadline {
            if case .unavailable = displayManager.status { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard displayManager.status == .connected else {
            let reason: String
            if case .unavailable(let why) = displayManager.status { reason = why } else { reason = "the lens did not attach within 5 s" }
            giveLensBack(acquired: acquired, attachedHere: attachedHere)
            return .sessionFailed(reason)
        }
        do {
            try await displayManager.sendTest()
        } catch {
            giveLensBack(acquired: acquired, attachedHere: attachedHere)
            return .sessionFailed(error.localizedDescription)
        }

        // Leave the card up, then give the lens back and release this
        // test's camera-session use; whoever else holds the session keeps it.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(DisplayTestReport.cardSeconds * 1_000_000_000))
            self?.giveLensBack(acquired: acquired, attachedHere: attachedHere)
        }
        return .sent
    }

    /// Undo what the display test set up. The lens is detached when the test
    /// attached it, or when this test is the session's last user (the
    /// capability dies with the session); otherwise the owner's screen
    /// comes back through the idle handler. Then the test's use is released.
    private func giveLensBack(acquired: Bool, attachedHere: Bool) {
        let sessionEnds = acquired && lensUsers <= 1
        if deviceSession == nil, attachedHere || sessionEnds {
            detachDisplayFromCameraSession()
        } else {
            displayManager.idleHandler?()
        }
        if acquired { releaseCameraSession() }
    }

    /// Longest a test waits for a brain before calling it a failure. Generous
    /// on purpose: an agent shelling out to `hermes chat` with an image
    /// attached is slow, and a false failure is as useless as a false pass.
    private static let testReplyTimeout: Double = 90

    /// Run `submit` and wait for the answer it produces.
    ///
    /// The Query and Visual tests used to report a pass the moment
    /// `submitQuery` returned - which only says the text was dispatched, not
    /// that any brain answered. A panel that exists to diagnose a broken
    /// setup must not go green on a dead agent.
    func awaitTestReply(_ submit: () -> Void) async throws {
        let timeout = Self.testReplyTimeout
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.completeTestOutcome(
                .failure(TestFailure("No answer within \(Int(timeout)) s"))
            )
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { cont in
            // A second test started while this one was waiting would strand
            // the first continuation forever - fail it instead.
            completeTestOutcome(.failure(TestFailure("Superseded by another test")))
            pendingTestOutcome = cont
            submit()
        }
    }

    func completeTestOutcome(_ result: Result<Void, Error>) {
        guard let cont = pendingTestOutcome else { return }
        pendingTestOutcome = nil
        cont.resume(with: result)
    }

    func runTest(_ name: String, _ body: () async throws -> Void) async {
        testRunning.insert(name)
        defer { testRunning.remove(name) }
        do {
            try await body()
            testResults[name] = ""
            lastTestFailure = nil
        } catch {
            testResults[name] = error.localizedDescription
            lastTestFailure = error.localizedDescription
        }
    }
}
