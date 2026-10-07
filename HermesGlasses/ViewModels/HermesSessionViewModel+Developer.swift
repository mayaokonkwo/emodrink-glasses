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
        let borrowed = deviceSession == nil && lensSession == nil
        try await ensureCameraSession()
        defer { if borrowed { releaseCameraSession() } }
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
    /// audio route (glasses in glasses mode). No bridge or Hermes involved.
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

    /// Attach (if needed) and push a static screen to the lens. Works
    /// without a Hermes session: spins up a temporary device session just
    /// for the test and tears it down after a few seconds.
    func testDisplay() async {
        await runTest("Display") { [self] in
            if let session = deviceSession {
                if displayManager.status != .connected {
                    displayManager.stop()
                    displayManager.start(session: session)
                }
                // Attach is async - wait up to 5 s for the capability
                for _ in 0..<50 where displayManager.status != .connected {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try await displayManager.sendTest()
                return
            }

            // No session: temporary one, display only
            let session = try wearables.createSession(deviceSelector: deviceSelector)
            do {
                try session.start()
                for _ in 0..<50 where session.state != .started {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard session.state == .started else {
                    throw TestFailure("Glasses didn't respond (check they're awake and connected in Meta AI)")
                }
                displayManager.stop()
                displayManager.start(session: session)
                for _ in 0..<50 where displayManager.status != .connected {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try await displayManager.sendTest()
            } catch {
                displayManager.stop()
                session.stop()
                throw error
            }
            // Leave the test screen up briefly, then tear down - unless a
            // real session started meanwhile (it re-attaches the display
            // to its own session in startSession)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if let self, self.deviceSession == nil {
                    self.displayManager.stop()
                }
                session.stop()
            }
        }
    }

    /// Longest a test waits for a brain before calling it a failure. Generous
    /// on purpose: a bridge shelling out to `hermes chat` with an image
    /// attached is slow, and a false failure is as useless as a false pass.
    private static let testReplyTimeout: Double = 90

    /// Run `submit` and wait for the answer it produces.
    ///
    /// The Query and Visual tests used to report a pass the moment
    /// `submitQuery` returned - which only says the text was dispatched, not
    /// that any brain answered. A panel that exists to diagnose a broken
    /// setup must not go green on a dead bridge.
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
