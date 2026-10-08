//
// ContentView.swift
//
// The EmoDrink home: one screen, top to bottom.
//   1. Lens stage: the iPhone camera with the simulated lens over it in
//      phone mode; in glasses mode the Ray-Ban camera's latest frame (a
//      dark stage until one arrives) under the same simulated lens. A
//      second badge names the real lens's status.
//   2. Today: sleep, score, HRV, resting HR, and where the numbers came from.
//   3. Pick: watching (or stopped), with why the AI was skipped when it
//      was; the three drinks as chips; or the chosen drink with Why / Thanks.
//   4. Start / Stop, with "Check now" beside it while watching and
//      "Test lens" whenever glasses are registered (its report shows
//      under the row for 6 s).
// Toolbar: Transcript and Settings. A plain VStack in the safe area with
// 16 pt side padding; nothing is wider than the screen.
//

import SwiftUI

// MARK: - Appearance

/// Light/dark override for the whole app. `.system` follows the phone.
/// Persisted under `appearance_mode`; read at the app root as a
/// `.preferredColorScheme`.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearance_mode"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct ContentView: View {
    let wearablesVM: WearablesViewModel
    let hermesVM: HermesSessionViewModel
    let emoDrinkVM: EmoDrinkViewModel

    @AppStorage("onboarding_complete") private var onboardingComplete = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var showTranscript = false
    @State private var settingsRoute: SettingsRoute?
    /// Auto-watch runs once per launch, not on every appear.
    @State private var didAutoStart = false
    /// The Test lens report, shown under the Start / Stop row for 6 s.
    @State private var lensTestNotice: String?
    /// Bumped per Test lens tap, so an older 6 s timer cannot clear a newer report.
    @State private var lensTestToken = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                LensStage(hermesVM: hermesVM, emoDrinkVM: emoDrinkVM)
                TodayCard(vm: emoDrinkVM)
                PickCard(vm: emoDrinkVM)
                startStopRow
                if let notice = lensTestNotice {
                    Label(notice, systemImage: "eyeglasses")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(HermesTheme.canvas.ignoresSafeArea())
            .navigationTitle("EmoDrink")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showTranscript = true } label: { Image(systemName: "list.bullet") }
                        .accessibilityLabel("Transcript")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
        }
        .tint(HermesTheme.accent)
        .sheet(isPresented: $showSettings, onDismiss: { settingsRoute = nil }) {
            SettingsView(hermesVM: hermesVM, wearablesVM: wearablesVM, emoDrinkVM: emoDrinkVM,
                         initialRoute: settingsRoute)
        }
        .sheet(isPresented: $showTranscript) {
            TranscriptSheet(hermesVM: hermesVM)
        }
        .alert("Glasses", isPresented: Binding(
            get: { wearablesVM.showError },
            set: { if !$0 { wearablesVM.dismissError() } }
        )) {
            Button("Open Glasses") {
                wearablesVM.dismissError()
                settingsRoute = .glasses
                showSettings = true
            }
            Button("OK", role: .cancel) { wearablesVM.dismissError() }
        } message: {
            Text(wearablesVM.errorMessage)
        }
        .alert("EmoDrink", isPresented: Binding(
            get: { emoDrinkVM.errorMessage != nil },
            set: { if !$0 { emoDrinkVM.errorMessage = nil } }
        )) {
            Button("OK") { emoDrinkVM.errorMessage = nil }
        } message: {
            Text(emoDrinkVM.errorMessage ?? "")
        }
        .task {
            hermesVM.logVisionDiagnostics("app-launch")
            await emoDrinkVM.refreshSnapshot()
            await autoStartIfNeeded()
            await hermesVM.refreshGlassesCameraStatus()
        }
        .onChange(of: onboardingComplete) { _, done in
            if done { Task { await autoStartIfNeeded() } }
        }
        .onChange(of: wearablesVM.registrationState) { _, state in
            guard state == .registered else { return }
            Task { await hermesVM.ensureGlassesCameraAfterPairing() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: emoDrinkVM.appDidEnterBackground()
            case .active: Task { await emoDrinkVM.appDidBecomeActive() }
            default: break
            }
        }
    }

    /// Spec section 4: once onboarding is done and "Watch for vending
    /// machines" is on, opening the app starts the session and drink mode.
    private func autoStartIfNeeded() async {
        guard !didAutoStart, onboardingComplete, emoDrinkVM.autoWatch,
              hermesVM.connectionState == .disconnected else { return }
        didAutoStart = true
        let genBefore = hermesVM.sessionGeneration
        await waitForGlassesIfPaired()
        guard !Task.isCancelled else { return }
        // A manual Start or Stop during the wait wins over the auto start.
        guard hermesVM.connectionState == .disconnected,
              hermesVM.sessionGeneration == genBefore else { return }
        await emoDrinkVM.start()
    }

    /// The SDK discovers paired glasses a moment after launch; starting at
    /// once would resolve and pin the iPhone camera before it sees them.
    /// Waits up to 3 s (every 250 ms), then starts anyway (phone fallback).
    private func waitForGlassesIfPaired() async {
        guard wearablesVM.registrationState == .registered,
              hermesVM.phoneModePreference != .always else { return }
        var polls = 0
        while !hermesVM.glassesAvailable, polls < 12 {
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(250))
            polls += 1
        }
    }

    private var running: Bool { hermesVM.connectionState != .disconnected }
    private var connecting: Bool { hermesVM.connectionState == .connecting }

    /// The Start button: `start()` starts the session, then drink mode,
    /// whatever the auto-watch setting (that gates only the on-open start).
    private func startWatching() async {
        await emoDrinkVM.start()
    }

    private var startStopRow: some View {
        HStack(spacing: 12) {
            // Disabled while connecting, so a tap cannot land mid-connect.
            HermesPrimaryButton(title: connecting ? "Starting…" : (running ? "Stop" : "Start"),
                                systemImage: running ? "stop.fill" : "play.fill",
                                enabled: !connecting) {
                if running { emoDrinkVM.stop() } else { Task { await startWatching() } }
            }
            if emoDrinkVM.drinkModeOn {
                Button {
                    Task { await emoDrinkVM.checkNow() }
                } label: {
                    if emoDrinkVM.checkingNow {
                        ProgressView()
                    } else {
                        Text("Check now").font(.system(size: 15, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(HermesTheme.accentOnCard)
                .disabled(emoDrinkVM.checkingNow || emoDrinkVM.momentActive)
                .fixedSize()
            }
            if wearablesVM.registrationState == .registered {
                Button {
                    Task { await testLens() }
                } label: {
                    if hermesVM.testRunning.contains("Display") {
                        ProgressView()
                    } else {
                        Text("Test lens").font(.system(size: 15, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(HermesTheme.accentOnCard)
                .disabled(hermesVM.testRunning.contains("Display"))
                .fixedSize()
            }
        }
    }

    /// Runs the Developer panel's Display test and shows its report under
    /// the Start / Stop row for 6 s.
    private func testLens() async {
        await hermesVM.testDisplay()
        lensTestToken += 1
        let token = lensTestToken
        lensTestNotice = hermesVM.displayTestReport
        try? await Task.sleep(for: .seconds(6))
        if lensTestToken == token { lensTestNotice = nil }
    }
}

// MARK: - Lens stage

private struct LensStage: View {
    let hermesVM: HermesSessionViewModel
    let emoDrinkVM: EmoDrinkViewModel

    var body: some View {
        ZStack(alignment: .top) {
            backdrop
            SimulatedLensView(content: hermesVM.lensContent)
                .padding(.horizontal, 14)
                .padding(.top, 28)
        }
        .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
        .background(HermesTheme.lensStage)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                badgeLabel(badge).fixedSize()
                // No lens exists in phone mode.
                if !hermesVM.phoneModeActive {
                    badgeLabel(hermesVM.lensStatusText(EmoDrinkStrings(language: hermesVM.activeLanguage)))
                }
            }
            .padding(10)
        }
        .environment(\.colorScheme, .dark)
    }

    private func badgeLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(HermesTheme.cream.opacity(0.8))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(HermesTheme.lensChrome.opacity(0.7), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var badge: String {
        if hermesVM.phoneModeActive { return hermesVM.phoneCamera.isStreaming ? "iPhone camera · live" : "iPhone camera" }
        let t = EmoDrinkStrings(language: hermesVM.activeLanguage)
        if emoDrinkVM.liveImage != nil { return t.glassesCameraLive }
        if hermesVM.isGlassesConnected { return t.glassesWaitingForCamera }
        return "Not started"
    }

    @ViewBuilder
    private var backdrop: some View {
        if hermesVM.phoneModeActive {
            if let image = hermesVM.phoneFeedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else if let error = hermesVM.phoneCameraError {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(HermesTheme.cream.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            } else {
                ProgressView()
                    .tint(HermesTheme.accentLight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let image = emoDrinkVM.liveImage {
            // Glasses mode: drink mode's latest frame from the Ray-Ban camera.
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            HermesTheme.lensStage
        }
    }
}

// MARK: - Today

private struct TodayCard: View {
    let vm: EmoDrinkViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HermesStatTile(value: vm.currentSnapshot.map { String(format: "%.1f h", $0.sleep.hours) } ?? "-", caption: "sleep")
                HermesStatTile(value: vm.currentSnapshot?.sleep.score.map(String.init) ?? "-", caption: "score")
                HermesStatTile(value: vm.currentSnapshot?.hrvMs.map { "\(Int($0.rounded()))" } ?? "-", caption: "HRV ms")
                HermesStatTile(value: vm.currentSnapshot?.restingHR.map { "\(Int($0.rounded()))" } ?? "-", caption: "rest HR")
            }
            Text(vm.fetching ? "Fetching…" : (vm.sourceLine.isEmpty ? "No data yet" : vm.sourceLine))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Pick

private struct PickCard: View {
    let vm: EmoDrinkViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(HermesTheme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        let t = vm.strings
        if let blocked = vm.sessionBlocked {
            Label(blocked, systemImage: "mic.slash")
                .font(.system(size: 15))
                .foregroundStyle(HermesTheme.destructive)
        } else {
            switch vm.step {
            case .choices:
                Text(t.choiceHeading).font(.system(size: 20, weight: .bold))
                ForEach(Array(vm.options.enumerated()), id: \.element.id) { index, drink in
                    chip("\(index + 1)  \(name(drink))") { vm.choose(index) }
                }
            case .chosen:
                if let pick = vm.currentPick {
                    Text(name(pick)).font(.system(size: 22, weight: .bold)).lineLimit(2)
                    Text(otherName(pick)).font(.system(size: 14)).foregroundStyle(.secondary)
                    if let reason = vm.recommendation?.reasonLine, !reason.isEmpty {
                        Text(reason).font(.footnote).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        chip(t.whyLabel) { vm.why() }
                        chip(t.thanksLabel) { vm.thanks() }
                    }
                }
            case nil:
                // Watching only while drink mode is on; otherwise say stopped.
                Text(vm.drinkModeOn ? (vm.noMachineNotice ?? t.idleTitle) : t.stoppedTitle)
                    .font(.system(size: 17, weight: .semibold))
                Text(vm.drinkModeOn ? t.idleHint : t.stoppedHint)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let notice = vm.aiNotice {
                    Label(notice, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func name(_ drink: Drink) -> String { vm.language == .ja ? drink.nameJa : drink.name }
    private func otherName(_ drink: Drink) -> String { vm.language == .ja ? drink.name : drink.nameJa }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
                .background(HermesTheme.accent.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(HermesTheme.accentOnCard)
    }
}

// MARK: - Transcript

private struct TranscriptSheet: View {
    let hermesVM: HermesSessionViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if hermesVM.conversationHistory.isEmpty && hermesVM.liveTranscript.isEmpty {
                    Text("Nothing said yet.").foregroundStyle(.secondary)
                }
                ForEach(hermesVM.conversationHistory) { turn in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(turn.userText).font(.system(size: 15, weight: .semibold))
                        Text(turn.agentText).font(.system(size: 15)).foregroundStyle(.secondary)
                        Text(turn.timestamp.formatted(date: .omitted, time: .shortened))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
                if !hermesVM.liveTranscript.isEmpty {
                    Text(hermesVM.liveTranscript).italic().foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Transcript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
