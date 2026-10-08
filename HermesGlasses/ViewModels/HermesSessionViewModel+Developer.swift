//
// HermesSessionViewModel+Developer.swift
//
// The Developer test panel (Settings › Glasses › Developer). Every test
// works from a cold start: GlassesLink opens the session when none runs.
//

import Foundation
import MWDATCore
import UIKit

extension HermesSessionViewModel {
    // MARK: - Test panel

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
            // The glasses source opens GlassesLink's camera for the photo
            // when nothing is streaming, so this works from a cold start.
            let photo = try await captureVisionPhoto()
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
            // The capture happens inside submitQuery; the glasses source
            // opens GlassesLink's camera for it when nothing is streaming.
            try await awaitTestReply {
                submitQuery("What am I looking at? Answer in one short sentence.")
            }
        }
    }

    /// Developer panel › Display, and Test lens on the home screen. Sends
    /// the test card through GlassesLink (which opens the session and
    /// attaches the lens when needed, 10 s at most), keeps it 15 s, and
    /// reports one of: sent (with the SDK's display.state right after the
    /// send), no glasses, display session failed (with the reason), or the
    /// glasses mic hiding the HUD. Every DisplayState and step is traced
    /// with a timestamp into `displayTestTrace`.
    func testDisplay() async {
        testRunning.insert("Display")
        defer { testRunning.remove("Display") }
        displayTestTrace = []
        displayTestReport = nil
        traceDisplay("test begins")
        displayManager.onStateTrace = { [weak self] state in self?.traceDisplay(state) }
        let outcome = await runDisplayTest()
        displayTestReport = outcome.report.message(sdkState: outcome.sdkState)
        testResults["Display"] = outcome.report.isSuccess ? "" : outcome.report.message
        lastTestFailure = outcome.report.isSuccess ? nil : outcome.report.message
        if let release = outcome.release {
            // Hold the card, then give the lens back; the button spins meanwhile.
            try? await Task.sleep(nanoseconds: UInt64(DisplayTestReport.cardSeconds * 1_000_000_000))
            release()
        }
        displayManager.onStateTrace = nil
    }

    /// Developer panel › Clear lens: blank the app's lens and, when the
    /// display is attached, ask the SDK to clear it. Logged in the trace.
    func clearLensFromDeveloper() async {
        displayManager.clear()
        do {
            try await displayManager.clearDisplay()
            traceDisplay("lens cleared (display.state \(displayManager.sdkStateDescription ?? "none"))")
        } catch {
            traceDisplay("clear lens failed: \(error.localizedDescription)")
        }
    }

    /// Appends one timestamped line; keeps the newest 200.
    func traceDisplay(_ event: String) {
        displayTestTrace.append(DisplayTestReport.traceLine(event, at: Date()))
        if displayTestTrace.count > 200 { displayTestTrace.removeFirst(displayTestTrace.count - 200) }
    }

    /// The report, the SDK state read right after a send, and (after a
    /// send) what gives the lens back once the card has been held.
    private struct DisplayTestOutcome {
        let report: DisplayTestReport
        var sdkState: String? = nil
        var release: (() -> Void)? = nil
    }

    /// Through GlassesLink, the proven Test 1 path: when the lens is up it
    /// is cleared first; otherwise the send attaches it (session created if
    /// needed) and the card waits for `.started`, 10 s at most.
    private func runDisplayTest() async -> DisplayTestOutcome {
        if let early = DisplayTestReport.preflight(glassesReachable: glassesAvailable || glassesLink.sessionState != nil,
                                                   glassesMicActive: lensBlockedByCallScreen) {
            traceDisplay("preflight: \(early.message)")
            return DisplayTestOutcome(report: early)
        }
        // The test card owns the lens until it is released.
        displayManager.suppressAttachRedraw = true
        if glassesLink.isDisplayReady {
            traceDisplay("lens already attached (display.state \(displayManager.sdkStateDescription ?? "none"))")
            // Start from a blank lens; a failure here is only traced.
            do {
                try await displayManager.clearDisplay()
                traceDisplay("cleared")
            } catch {
                traceDisplay("clear failed: \(error.localizedDescription)")
            }
        } else {
            traceDisplay("attaching through GlassesLink (session \(glassesLink.sessionStateText))")
        }
        do {
            try await displayManager.sendTest()
        } catch {
            traceDisplay("send failed: \(error.localizedDescription)")
            giveLensBack()
            return DisplayTestOutcome(report: .sessionFailed(error.localizedDescription))
        }
        let sdkState = displayManager.sdkStateDescription
        traceDisplay("sent (display.state \(sdkState ?? "none"))")

        // The caller leaves the card up, then gives the lens back.
        return DisplayTestOutcome(report: .sent, sdkState: sdkState, release: { [weak self] in
            guard let self else { return }
            self.giveLensBack()
            self.traceDisplay("released")
        })
    }

    /// Undo what the display test set up: with the HUD active the owner's
    /// screen comes back through the idle handler; otherwise the lens is
    /// cleared. GlassesLink keeps its session and display either way.
    private func giveLensBack() {
        // The test card is done; attach redraws are allowed again.
        displayManager.suppressAttachRedraw = false
        if displayManager.isActive {
            displayManager.idleHandler?()
        } else {
            Task { [glassesLink] in await glassesLink.clear() }
        }
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
