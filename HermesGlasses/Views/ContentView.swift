//
// ContentView.swift
//
// The EmoDrink home: one screen, top to bottom.
//   1. Lens stage: the iPhone camera with the simulated lens over it in
//      phone mode; a dark stage with a "Glasses connected" badge and the
//      same simulated lens (mirroring the Ray-Ban) in glasses mode.
//   2. Today: sleep, score, HRV, resting HR, and where the numbers came from.
//   3. Pick: watching, the three drinks as chips, or the chosen drink with
//      Why / Thanks.
//   4. Start / Stop, with "Check now" beside it while watching.
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                LensStage(hermesVM: hermesVM)
                TodayCard(vm: emoDrinkVM)
                PickCard(vm: emoDrinkVM)
                startStopRow
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
        await emoDrinkVM.start()
    }

    private var running: Bool { hermesVM.connectionState != .disconnected }

    /// The Start button always starts the session and drink mode, whatever
    /// the auto-watch setting: `start()` only turns drink mode on when
    /// `autoWatch` is on, so drink mode is started here when it is still off.
    private func startWatching() async {
        await emoDrinkVM.start()
        guard emoDrinkVM.sessionBlocked == nil, !emoDrinkVM.drinkModeOn,
              hermesVM.connectionState != .disconnected else { return }
        await emoDrinkVM.startDrinkMode()
    }

    private var startStopRow: some View {
        HStack(spacing: 12) {
            HermesPrimaryButton(title: running ? "Stop" : "Start",
                                systemImage: running ? "stop.fill" : "play.fill") {
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
        }
    }
}

// MARK: - Lens stage

private struct LensStage: View {
    let hermesVM: HermesSessionViewModel

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
            Text(badge)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(HermesTheme.cream.opacity(0.8))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(HermesTheme.lensChrome.opacity(0.7), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .padding(10)
        }
        .environment(\.colorScheme, .dark)
    }

    private var badge: String {
        if hermesVM.phoneModeActive { return hermesVM.phoneCamera.isStreaming ? "iPhone camera · live" : "iPhone camera" }
        if hermesVM.isGlassesConnected { return "Glasses connected" }
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
                Text(vm.noMachineNotice ?? t.idleTitle)
                    .font(.system(size: 17, weight: .semibold))
                Text(t.idleHint)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
