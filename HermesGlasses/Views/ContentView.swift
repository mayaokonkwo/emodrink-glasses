//
// ContentView.swift
//
// The EmoDrink home. Interim version while the Hermes features are being
// deleted: the phone-mode stage when the iPhone is the eye, otherwise the
// EmoDrink panel, plus one Start / Stop button. Task 14 of the EmoDrink
// Focus plan replaces this with the final one-screen layout.
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

    @State private var showSettings = false
    @State private var settingsRoute: SettingsRoute?

    var body: some View {
        VStack(spacing: 0) {
            if hermesVM.phoneModeActive {
                PhoneModeSessionView(
                    hermesVM: hermesVM,
                    onShowTranscript: {},
                    onOpenDevices: { openGlasses() }
                )
            } else {
                EmoDrinkView(vm: emoDrinkVM)
            }
            HStack(spacing: 12) {
                HermesPrimaryButton(
                    title: hermesVM.connectionState == .disconnected ? "Start" : "Stop",
                    systemImage: hermesVM.connectionState == .disconnected ? "play.fill" : "stop.fill"
                ) {
                    if hermesVM.connectionState == .disconnected {
                        Task {
                            await hermesVM.startSession()
                            await emoDrinkVM.startDrinkMode()
                        }
                    } else {
                        emoDrinkVM.stopDrinkMode()
                        hermesVM.endSession()
                    }
                }
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 20))
                }
                .accessibilityLabel("Settings")
            }
            .padding(16)
        }
        .tint(HermesTheme.accent)
        .sheet(isPresented: $showSettings, onDismiss: { settingsRoute = nil }) {
            SettingsView(hermesVM: hermesVM, wearablesVM: wearablesVM, emoDrinkVM: emoDrinkVM,
                         initialRoute: settingsRoute)
        }
        .alert("Glasses", isPresented: Binding(
            get: { wearablesVM.showError },
            set: { if !$0 { wearablesVM.dismissError() } }
        )) {
            Button("Open Glasses") {
                wearablesVM.dismissError()
                openGlasses()
            }
            Button("OK", role: .cancel) { wearablesVM.dismissError() }
        } message: {
            Text(wearablesVM.errorMessage)
        }
        .task {
            hermesVM.logVisionDiagnostics("app-launch")
            await hermesVM.refreshGlassesCameraStatus()
        }
        .onChange(of: wearablesVM.registrationState) { _, state in
            guard state == .registered else { return }
            Task { await hermesVM.ensureGlassesCameraAfterPairing() }
        }
    }

    private func openGlasses() {
        settingsRoute = .glasses
        showSettings = true
    }
}
