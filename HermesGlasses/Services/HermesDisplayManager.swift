//
// HermesDisplayManager.swift
//
// Renders the HUD screens (listening, thinking, replies, the EmoDrink
// cards) and sends them to the lens through GlassesLink, the proven
// display path: GlassesLink attaches the display on demand and holds a
// view until the display is `.started`. Strictly best-effort: every
// failure is logged and swallowed - the voice loop must never notice the
// display. `content` (the simulated lens) updates whether or not glasses
// are attached.
//

import Foundation
import MWDATCore
import MWDATDisplay
import os

enum DisplayHUDStatus: Equatable {
    case off                    // toggle disabled or no session
    case connecting
    case connected
    case unavailable(String)    // attach failed / update needed / dropped
}

@MainActor
final class HermesDisplayManager {
    private let logger = Logger(
        subsystem: "com.flowsxr.hermesglasses", category: "display"
    )

    private(set) var status: DisplayHUDStatus = .off {
        didSet {
            if status != oldValue { onStatusChanged?(status) }
        }
    }

    /// What the lens is showing, independent of whether any glasses are
    /// attached. Phone mode renders this in SwiftUI (SimulatedLensView),
    /// so it is assigned on EVERY screen call - including when `status` is
    /// `.off` and nothing goes out over BLE.
    private(set) var content: LensContent = .blank {
        didSet {
            if content != oldValue { onContentChanged?(content) }
        }
    }

    var onStatusChanged: ((DisplayHUDStatus) -> Void)?
    var onContentChanged: ((LensContent) -> Void)?
    var onDebug: ((String) -> Void)?
    /// On-lens button callbacks (invoked on the main actor)
    var onStop: (() -> Void)?
    var onRepeat: (() -> Void)?
    var onNewChat: (() -> Void)?
    /// The wearer tapped one of the reply's options.
    var onChooseReplyOption: ((ReplyChoice) -> Void)?
    /// What to do when a reply dwell ends. Default (nil) blanks the lens;
    /// the session sets this so EmoDrink can restore its card.
    var idleHandler: (() -> Void)?
    /// Draws the current card when the display attaches (a card sent while
    /// the display was off was dropped). Returns true when it drew.
    var attachRedraw: (() -> Bool)?
    /// Set by the Developer display test around its own attach, so the
    /// redraw cannot land after (and over) the test card.
    var suppressAttachRedraw = false
    /// Every DisplayState the SDK reports, as text ("starting", "started",
    /// ...). Set by the Developer display test to trace the attach.
    var onStateTrace: ((String) -> Void)?
    /// The SDK's own `display.state` right now; nil when not attached.
    var sdkStateDescription: String? { link.displayState.map(GlassesLink.describe) }

    /// The one path to the lens.
    private let link: GlassesLink
    /// The HUD is wanted on the real lens (glasses session running, HUD
    /// on, lens not covered by the call screen). Off: nothing goes out.
    private(set) var isActive = false
    /// GlassesLink's display state at the last change, to spot `.started`.
    private var lastLinkState: DisplayState?

    private var display: Display?
    private var stateListenerToken: AnyListenerToken?
    private var stateTask: Task<Void, Never>?
    private var stateContinuation: AsyncStream<DisplayState>.Continuation?
    /// Meta's DisplayAccess sample gives the display 10 s to reach
    /// `.started`, then gives up and says so. Without it a display that
    /// never starts sat in `.connecting` forever, silently.
    private var readinessTask: Task<Void, Never>?
    static let readinessTimeoutSeconds: Double = 10
    /// Latest view queued while the capability is still attaching
    private var pendingView: FlexBox?
    /// Serialized send pipeline: newest queued view wins, one send in
    /// flight at a time (BLE sends can complete out of order otherwise)
    private var queuedView: FlexBox?
    private var sendTask: Task<Void, Never>?
    private var dwellTask: Task<Void, Never>?
    private var throttle = DisplaySendThrottle()
    private var lastReplyText: String = ""

    init(link: GlassesLink) {
        self.link = link
        lastLinkState = link.displayState
        link.observeDisplay("hud") { [weak self] state in
            self?.linkDisplayChanged(state)
        }
    }

    // MARK: - Lifecycle (GlassesLink)

    /// Put the HUD on the real lens: attach the display through GlassesLink
    /// (session created if needed), or redraw at once when it is already up.
    func activate() {
        guard !isActive else { return }
        isActive = true
        NSLog("[EmoDrink] display activate (link display \(link.displayStateText))")
        recomputeStatus()
        if link.isDisplayReady {
            redrawAfterAttach()
        } else {
            link.ensureDisplay()
        }
    }

    /// Stop sending to the real lens and blank it. The display stays
    /// attached to GlassesLink's session for the next activate.
    func deactivate() {
        cancelDwell()
        pendingView = nil
        queuedView = nil
        lastReplyText = ""
        let wasActive = isActive
        isActive = false
        status = .off
        if wasActive, link.isDisplayReady {
            Task { [link] in await link.clear() }
        }
    }

    /// `.connected` mirrors GlassesLink's display state while active.
    private func recomputeStatus() {
        guard isActive else {
            status = .off
            return
        }
        switch link.displayState {
        case .started?:
            status = .connected
        case .starting?:
            status = .connecting
        case .stopping?, .stopped?:
            status = .unavailable(link.displayIssue ?? "Display stopped")
        case nil:
            status = link.displayIssue.map { .unavailable($0) } ?? .connecting
        }
    }

    private func linkDisplayChanged(_ state: DisplayState?) {
        let was = lastLinkState
        lastLinkState = state
        if state != was {
            NSLog("[EmoDrink] display state \(state.map(GlassesLink.describe) ?? "not attached")")
            onStateTrace?(state.map(GlassesLink.describe) ?? "not attached")
        } else if state == nil, let issue = link.displayIssue {
            onStateTrace?("not attached: \(issue)")
        }
        guard isActive else { return }
        recomputeStatus()
        if state == .started, was != .started {
            debug("Display attached")
            redrawAfterAttach()
        }
    }

    /// A card sent while the display was off was dropped: draw the current
    /// one now, unless a view is already on its way (it waited for this).
    private func redrawAfterAttach() {
        guard sendTask == nil, queuedView == nil, !suppressAttachRedraw else { return }
        _ = attachRedraw?()
    }

    // MARK: - Lifecycle (old DeviceSession attach)

    /// Attach the display capability on the shared voice session.
    func start(session: DeviceSession) {
        guard display == nil else {
            NSLog("[EmoDrink] display start skipped: already attached (status \(status))")
            return
        }
        status = .connecting
        NSLog("[EmoDrink] display addDisplay (session state \(session.state))")

        do {
            let capability = try session.addDisplay()

            let (stream, continuation) = AsyncStream.makeStream(of: DisplayState.self)
            stateContinuation = continuation
            stateListenerToken = capability.statePublisher.listen { state in
                continuation.yield(state)
            }

            stateTask = Task { [weak self] in
                for await state in stream {
                    guard let self, !Task.isCancelled else { return }
                    NSLog("[EmoDrink] display state \(state)")
                    self.onStateTrace?(String(describing: state))
                    switch state {
                    case .starting, .stopping:
                        break
                    case .started:
                        self.readinessTask?.cancel()
                        self.readinessTask = nil
                        self.status = .connected
                        self.debug("Display attached")
                        if let view = self.pendingView {
                            self.pendingView = nil
                            self.transmit(view)
                        } else if !self.suppressAttachRedraw, self.attachRedraw?() == true {
                            // The fresh card wins over anything queued.
                            self.pendingView = nil
                        }
                    case .stopped:
                        // Mid-session drop unless stop() already ran
                        if self.status != .off {
                            self.status = .unavailable("Display stopped")
                        }
                        self.cleanup()
                        return
                    }
                }
            }

            capability.start()
            display = capability
            startReadinessTimeout()
        } catch {
            status = .unavailable(error.localizedDescription)
            NSLog("[EmoDrink] display addDisplay failed: \(error)")
            debug("Display attach failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        cancelDwell()
        pendingView = nil
        lastReplyText = ""
        status = .off
        display?.stop()
        // Tear down synchronously - waiting for the async .stopped event
        // leaves `display` non-nil, and a quick start() would then bail on
        // its guard and never re-attach. cleanup() is idempotent, so the
        // late .stopped event (stream already finished) is harmless.
        cleanup()
    }

    private func startReadinessTimeout() {
        readinessTask?.cancel()
        readinessTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.readinessTimeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.status == .connecting else { return }
            let state = self.sdkStateDescription ?? "none"
            NSLog("[EmoDrink] display not started within \(Int(Self.readinessTimeoutSeconds)) s (display.state \(state)), stopping it")
            self.onStateTrace?("timed out (display.state \(state))")
            self.readinessTask = nil
            self.pendingView = nil
            self.display?.stop()
            self.cleanup()
            self.status = .unavailable("Timed out waiting for the display to become ready.")
        }
    }

    private func cleanup() {
        readinessTask?.cancel()
        readinessTask = nil
        stateListenerToken = nil
        stateContinuation?.finish()
        stateContinuation = nil
        stateTask?.cancel()
        stateTask = nil
        display = nil
        queuedView = nil
    }

    // MARK: - Screens

    func showListening(partial: String) {
        // Before the throttle: the simulated lens is local, so it can show
        // every partial even when BLE sends are being rate-limited.
        content = .listening(partial: partial)
        guard throttle.shouldSend() else { return }
        cancelDwell()
        send(HermesDisplayScreens.listening(partial: partial))
    }

    func showThinking(query: String) {
        content = .thinking(query: query)
        cancelDwell()
        send(HermesDisplayScreens.thinking(query: query))
    }

    func showPhotoCaptured() {
        content = .photoCaptured
        cancelDwell()
        send(HermesDisplayScreens.photoCaptured())
    }

    /// speaking=true keeps the card up (Stop button shown, no dwell);
    /// dwellSeconds non-nil blanks the lens after that many seconds.
    func showReply(text: String, speaking: Bool, dwellSeconds: Double?) {
        let choices = ChoiceDetector.choices(in: text)
        content = .reply(text: text, speaking: speaking, choices: choices)
        cancelDwell()
        lastReplyText = text
        send(HermesDisplayScreens.reply(
            text: text,
            speaking: speaking,
            choices: choices,
            onStop: { [weak self] in
                Task { @MainActor in self?.onStop?() }
            },
            onRepeat: { [weak self] in
                Task { @MainActor in self?.onRepeat?() }
            },
            onNewChat: { [weak self] in
                Task { @MainActor in self?.onNewChat?() }
            },
            onChoose: { [weak self] choice in
                Task { @MainActor in self?.onChooseReplyOption?(choice) }
            }
        ))
        // A reply with options must not blank itself out from under the
        // wearer while they are deciding.
        if let dwellSeconds, choices.isEmpty {
            scheduleDwell(seconds: dwellSeconds)
        }
    }

    /// TTS ended or was interrupted: re-render without Stop, start the
    /// spoken dwell, then blank (or let the idle handler restore a card).
    func replySpeakingFinished() {
        guard !lastReplyText.isEmpty else { return }
        showReply(text: lastReplyText, speaking: false, dwellSeconds: HermesDisplayLogic.spokenDwellSeconds)
    }

    /// EmoDrink pick. Buttons route through onChooseReplyOption like reply
    /// options do, so a tap submits the choice's words to the session.
    func showEmoDrink(title: String, subtitle: String, reason: String, source: String, choices: [ReplyChoice]) {
        content = .emoDrink(title: title, subtitle: subtitle, reason: reason, source: source, choices: choices)
        cancelDwell()
        lastReplyText = ""
        send(HermesDisplayScreens.emoDrink(
            title: title, subtitle: subtitle, reason: reason, source: source, choices: choices,
            onChoose: { [weak self] choice in
                Task { @MainActor in self?.onChooseReplyOption?(choice) }
            }))
    }

    func showEmoDrinkWatching(heading: String, text: String, hint: String) {
        content = .emoDrinkWatching(heading: heading, text: text, hint: hint)
        cancelDwell()
        lastReplyText = ""
        send(HermesDisplayScreens.emoDrinkWatching(heading: heading, text: text, hint: hint))
    }

    /// Step A. Buttons route through onChooseReplyOption like reply options,
    /// so a tap submits "2 Calpis Water" to the session, where the EmoDrink
    /// claimer hands it to DrinkChoiceParser. No dwell: the wearer is deciding.
    func showEmoDrinkChoices(heading: String, options: [LensDrinkOption], source: String) {
        let next = LensContent.emoDrinkChoices(heading: heading, options: options, source: source)
        content = next
        cancelDwell()
        lastReplyText = ""
        send(HermesDisplayScreens.emoDrinkChoices(
            heading: heading, status: next.statusLine ?? source, choices: next.choices,
            onChoose: { [weak self] choice in
                Task { @MainActor in self?.onChooseReplyOption?(choice) }
            }))
    }

    func showNewConversationFlash() {
        content = .newConversation
        cancelDwell()
        lastReplyText = ""
        send(HermesDisplayScreens.newConversation())
        scheduleDwell(seconds: 2)
    }

    func clear() {
        content = .blank
        cancelDwell()
        lastReplyText = ""
        send(HermesDisplayScreens.blank())
    }

    /// Test panel: the test card through GlassesLink's send (attaching the
    /// display first when needed). Throws so the button can show WHY.
    func sendTest() async throws {
        NSLog("[EmoDrink] display test card send (display.state \(link.displayStateText))")
        guard await link.send(HermesDisplayScreens.testScreen(), label: "test card") else {
            throw NSError(
                domain: "HermesDisplay", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    link.displayIssue ?? "The lens did not take the card (display \(link.displayStateText))"]
            )
        }
        NSLog("[EmoDrink] display test card send returned (display.state \(link.displayStateText))")
    }

    /// The SDK's clearDisplay(). Throws when the lens is not attached, so
    /// the Developer page can say why nothing happened.
    func clearDisplay() async throws {
        guard link.isDisplayReady else {
            throw NSError(
                domain: "HermesDisplay", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Display not attached (display \(link.displayStateText))"]
            )
        }
        guard await link.clear() else {
            throw NSError(
                domain: "HermesDisplay", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "clearDisplay failed (see the Glasses basics log)"]
            )
        }
    }

    // MARK: - Plumbing

    /// Serialized send pipeline through GlassesLink: newest queued view
    /// wins, one send in flight at a time (BLE sends can complete out of
    /// order otherwise). While the display is not started GlassesLink holds
    /// the view until it is (or 10 s pass).
    private func send(_ view: FlexBox) {
        guard isActive else { return }
        queuedView = view
        guard sendTask == nil else { return }  // drain loop already running
        sendTask = Task { [weak self] in
            while let self, self.isActive, let next = self.queuedView {
                self.queuedView = nil
                let sent = await self.link.send(next, label: "HUD")
                if !sent {
                    self.debug("Display send failed (display \(self.link.displayStateText))")
                }
            }
            self?.sendTask = nil
        }
    }

    private func transmit(_ view: FlexBox) {
        guard display != nil else { return }
        queuedView = view
        guard sendTask == nil else { return }  // drain loop already running
        sendTask = Task { [weak self] in
            while let self, let next = self.queuedView {
                self.queuedView = nil
                guard let display = self.display else { break }
                do {
                    try await display.send(next)
                } catch {
                    NSLog("[EmoDrink] display send failed: \(error)")
                    self.debug("Display send failed: \(error.localizedDescription)")
                }
            }
            self?.sendTask = nil
        }
    }

    private func scheduleDwell(seconds: Double) {
        dwellTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if let idle = self.idleHandler {
                idle()
            } else {
                self.clear()
            }
        }
    }

    private func cancelDwell() {
        dwellTask?.cancel()
        dwellTask = nil
    }

    private func debug(_ message: String) {
        logger.info("\(message, privacy: .public)")
        onDebug?(message)
    }
}
