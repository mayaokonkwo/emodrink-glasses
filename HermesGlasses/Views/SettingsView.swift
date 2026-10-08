//
// SettingsView.swift
//
// Four pages, EmoDrink only: Glasses (with the Developer test panel under
// it), Assistant, Language and voice, Drinks. Labels stay English; the lens
// and spoken lines follow the language setting.
//
// The typed API key is owned HERE and passed down by binding, so a
// swipe-dismiss from any page still commits it.
//

import SwiftUI

/// Sub-pages that can be opened directly from elsewhere in the app.
enum SettingsRoute: Hashable {
    case glasses
}

struct SettingsView: View {
    let hermesVM: HermesSessionViewModel
    let wearablesVM: WearablesViewModel
    let emoDrinkVM: EmoDrinkViewModel
    /// Push this page as soon as Settings appears.
    var initialRoute: SettingsRoute? = nil

    @State private var path: [SettingsRoute] = []
    @State private var providerKey: String = ""
    /// Consumes `initialRoute` exactly once, so Back really goes back.
    @State private var didConsumeInitialRoute = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack(path: $path) {
            HermesScrollPage {
                NavigationLink(value: SettingsRoute.glasses) {
                    HermesDeviceCard(
                        title: wearablesVM.glasses.first?.name ?? "Ray-Ban Display",
                        status: deviceStatus,
                        dot: hermesVM.isGlassesConnected ? HermesTheme.online : .gray
                    ) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(HermesTheme.cream.opacity(0.35))
                    }
                }
                .buttonStyle(.plain)

                HermesSection {
                    navRow("Assistant", icon: "brain", value: assistantValue) {
                        AssistantPage(hermesVM: hermesVM, providerKey: $providerKey)
                    }
                    HermesDivider()
                    navRow("Language and voice", icon: "character.bubble", value: languageLabel(hermesVM.activeLanguage)) {
                        LanguageVoicePage(hermesVM: hermesVM)
                    }
                    HermesDivider()
                    navRow("Drinks", icon: "cup.and.saucer", value: emoDrinkVM.useMock ? "Sample data" : "Feed") {
                        DrinksPage(vm: emoDrinkVM)
                    }
                }

                VStack(spacing: 4) {
                    HermesLockup(height: 13, showsSuffix: true)
                    Text("Version \(Self.appVersion) · EmoDrink picks a drink that fits how you slept and shows it on your Meta Ray-Ban Display glasses.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(HermesTheme.groupedCanvas, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        commitTypedValues()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .glasses: GlassesPage(hermesVM: hermesVM, wearablesVM: wearablesVM)
                }
            }
            .onAppear {
                if !didConsumeInitialRoute, let initialRoute {
                    didConsumeInitialRoute = true
                    path = [initialRoute]
                }
            }
            .onDisappear(perform: commitTypedValues)
        }
        .tint(HermesTheme.accent)
    }

    private func navRow<Destination: View>(
        _ title: String, icon: String, value: String?,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HermesRow(title, icon: icon, value: value)
        }
        .buttonStyle(.plain)
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
    }

    private var deviceStatus: String {
        let connection = hermesVM.isGlassesConnected ? "Connected" : "Not connected"
        let count = wearablesVM.devices.count
        return "\(connection) · \(count) device\(count == 1 ? "" : "s")"
    }

    private var assistantValue: String {
        if BundledAIKey.isActive { return "Included" }
        let model = hermesVM.directProvider.curatedModels.first { $0.id == hermesVM.directModel }?.label
        guard let model else { return hermesVM.directProvider.displayName }
        return model.components(separatedBy: " - ").first ?? model
    }

    /// Swipe-dismiss must not silently discard a typed key.
    private func commitTypedValues() {
        if !providerKey.trimmingCharacters(in: .whitespaces).isEmpty {
            hermesVM.setProviderKey(providerKey)
            providerKey = ""
        }
    }
}

// MARK: - Glasses

private struct GlassesPage: View {
    let hermesVM: HermesSessionViewModel
    let wearablesVM: WearablesViewModel

    var body: some View {
        HermesScrollPage {
            deviceSection
            cameraSection
            phoneModeSection
            HermesSection(header: "Developer") {
                NavigationLink {
                    DeveloperPage(hermesVM: hermesVM)
                } label: {
                    HermesRow("Test panel", icon: "wrench.and.screwdriver", mutedIcon: true, value: "Display test")
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Glasses")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var deviceSection: some View {
        if let active = wearablesVM.glasses.first {
            HermesDeviceCard(
                title: active.name,
                status: hermesVM.isGlassesConnected ? "In use" : "Paired · not connected",
                dot: hermesVM.isGlassesConnected ? HermesTheme.online : .gray,
                chips: active.capabilities
            ) {
                NavigationLink {
                    GlassesStatusPage(hermesVM: hermesVM, wearablesVM: wearablesVM)
                } label: {
                    Text("Manage")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(HermesTheme.cream)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(HermesTheme.cream.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        } else {
            HermesSection(header: "No glasses paired", footer: "Pairing finishes in the Meta AI app.") {
                Button {
                    wearablesVM.connectGlasses()
                } label: {
                    HermesRow("Connect glasses", icon: "eyeglasses", value: registrationText)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var cameraSection: some View {
        HermesSection(
            header: "Glasses camera",
            footer: "Meta AI grants the glasses camera separately from iOS. Without it EmoDrink cannot see the vending machine through the glasses."
        ) {
            Button {
                Task { await hermesVM.requestGlassesCameraAccess() }
            } label: {
                HermesRow(title: "Camera access", showsChevron: false) {
                    if hermesVM.cameraPermissionGranted == true {
                        HermesBadge(text: "Allowed", prominent: true)
                    } else {
                        Text("Allow")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(HermesTheme.accentOnCard)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var phoneModeSection: some View {
        HermesSection(header: "No glasses on you?", footer: hermesVM.phoneModePreference.explanation) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Use this iPhone").font(.system(size: 16, weight: .semibold))
                    if hermesVM.visionRoute == .phone { HermesBadge(text: "Active", prominent: true) }
                }
                Picker("Phone mode", selection: Binding(
                    get: { hermesVM.phoneModePreference },
                    set: { hermesVM.phoneModePreference = $0 }
                )) {
                    ForEach(PhoneModePreference.allCases) { preference in
                        Text(preference.label).tag(preference)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var registrationText: String {
        switch wearablesVM.registrationState {
        case .notRegistered: return "Not paired"
        case .registering: return "Pairing…"
        case .registered: return "Paired"
        case .unavailable: return "Unavailable"
        }
    }
}

private struct GlassesStatusPage: View {
    let hermesVM: HermesSessionViewModel
    let wearablesVM: WearablesViewModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Registration", value: registrationText)
                LabeledContent("Devices seen by SDK", value: "\(wearablesVM.devices.count)")
                LabeledContent("Camera permission", value: cameraText)
                LabeledContent("Display", value: displayText)
            } header: {
                Text("Status")
            } footer: {
                Text("0 devices with \"Registered\" means the glasses are not reachable over Bluetooth right now, or the pairing is stale.")
            }
            Section {
                Button("Re-pair Glasses", role: .destructive) {
                    Task { await wearablesVM.repairGlasses() }
                }
            }
        }
        .hermesFormStyle()
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var registrationText: String {
        switch wearablesVM.registrationState {
        case .notRegistered: return "Not registered"
        case .registering: return "Registering…"
        case .registered: return "Registered"
        case .unavailable: return "Unavailable"
        }
    }

    private var cameraText: String {
        switch hermesVM.cameraPermissionGranted {
        case .some(true): return "Granted"
        case .some(false): return "Denied - tap Allow under Glasses camera"
        case .none: return "Unknown (start a session)"
        }
    }

    /// The same five states as the home badge; Settings labels stay English.
    private var displayText: String {
        hermesVM.lensStatusText(EmoDrinkStrings(language: .en))
    }
}

// MARK: - Developer

private struct DeveloperPage: View {
    let hermesVM: HermesSessionViewModel

    private static let tests = ["Display", "Sound", "Photo", "Query", "Visual"]

    var body: some View {
        HermesScrollPage {
            HermesSection(header: "Test panel") {
                VStack(spacing: 10) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(Self.tests, id: \.self) { testButton($0) }
                    }
                    if let report = hermesVM.displayTestReport {
                        Text("Display: \(report)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(4)
                    }
                    // The Display test's outcome already shows above; show it once.
                    if let failure = hermesVM.lastTestFailure, failure != hermesVM.displayTestReport {
                        Text(failure)
                            .font(.caption2)
                            .foregroundStyle(HermesTheme.destructive)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(4)
                    }
                    if let photo = hermesVM.lastTestPhoto {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(uiImage: photo)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            if let source = hermesVM.lastTestPhotoSource {
                                Text(source).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }

            HermesSection(header: "Diagnostics") {
                HermesRow(title: "Mic level", showsChevron: false) {
                    ProgressView(value: min(1.0, Double(hermesVM.micLevel) * 8)).frame(width: 90)
                }
                HermesDivider()
                HermesRow("Vision route", value: hermesVM.visionRoute == .phone ? "iPhone camera" : "Ray-Ban camera", showsChevron: false)
                HermesDivider()
                HermesRow("Audio output", value: hermesVM.lastTestAudioRoute ?? "Run the Sound test", showsChevron: false)
                HermesDivider()
                HermesRow("Glasses display", value: displayText, showsChevron: false)
            }
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func testButton(_ name: String) -> some View {
        Button {
            Task { await run(name) }
        } label: {
            HStack(spacing: 4) {
                if hermesVM.testRunning.contains(name) {
                    ProgressView().scaleEffect(0.6)
                } else if let result = hermesVM.testResults[name] ?? nil {
                    Image(systemName: result.isEmpty ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.isEmpty ? HermesTheme.online : HermesTheme.destructive)
                }
                Text(name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(HermesTheme.accentOnCard)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(HermesTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(hermesVM.testRunning.contains(name))
    }

    private func run(_ name: String) async {
        switch name {
        case "Display": await hermesVM.testDisplay()
        case "Sound": await hermesVM.testSound()
        case "Photo": await hermesVM.testPhoto()
        case "Query": await hermesVM.testQuery()
        case "Visual": await hermesVM.testVisualQuery()
        default: break
        }
    }

    /// The same five states as the home badge; Settings labels stay English.
    private var displayText: String {
        hermesVM.lensStatusText(EmoDrinkStrings(language: .en))
    }
}

// MARK: - Assistant

private struct AssistantPage: View {
    let hermesVM: HermesSessionViewModel
    @Binding var providerKey: String
    /// Reveals the key field over a bundled (managed) key.
    @State private var useOwnKey = false

    var body: some View {
        HermesScrollPage {
            if BundledAIKey.isActive && !useOwnKey { managedKeySection } else { directSection }
        }
        .navigationTitle("Assistant")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var managedKeySection: some View {
        HermesSection(footer: "A key for the drink assistant is built into this copy. Add your own key here to use it instead.") {
            HermesRow("Assistant", value: "included (\(hermesVM.directProvider.displayName), \(shortModelLabel))", showsChevron: false)
            HermesDivider()
            Button { useOwnKey = true } label: {
                Text("Use my own key")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(HermesTheme.accentOnCard)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var directSection: some View {
        HermesSection(footer: "The phone calls \(hermesVM.directProvider.displayName) with your key. Applies from the next session.") {
            Menu {
                Picker("Provider", selection: Binding(get: { hermesVM.directProviderID }, set: { hermesVM.directProviderID = $0 })) {
                    ForEach(AIProviderRegistry.all, id: \.id) { Text($0.displayName).tag($0.id) }
                }
            } label: {
                HermesRow("Provider", value: hermesVM.directProvider.displayName)
            }
            HermesDivider()
            Menu {
                Picker("Model", selection: Binding(get: { hermesVM.directModel }, set: { hermesVM.directModel = $0 })) {
                    ForEach(hermesVM.directProvider.curatedModels, id: \.id) { Text($0.label).tag($0.id) }
                    if !hermesVM.directProvider.curatedModels.contains(where: { $0.id == hermesVM.directModel }) {
                        Text(hermesVM.directModel).tag(hermesVM.directModel)
                    }
                }
            } label: {
                HermesRow("Model", value: modelLabel)
            }
            if hermesVM.directProvider.allowsCustomBaseURL {
                HermesDivider()
                TextField("https://…", text: Binding(get: { hermesVM.directBaseURL }, set: { hermesVM.directBaseURL = $0 }))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .font(.system(size: 15, design: .monospaced))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            if hermesVM.directProvider.requiresKey {
                HermesDivider()
                SecureField("\(hermesVM.directProvider.displayName) API key", text: $providerKey)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(size: 15, design: .monospaced))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .onSubmit {
                        // An empty submit over a bundled key only folds the section back.
                        if providerKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, BundledAIKey.isActive {
                            useOwnKey = false
                            return
                        }
                        hermesVM.setProviderKey(providerKey)
                        providerKey = ""
                    }
                HermesDivider()
                HermesRow("Key status", value: hermesVM.hasDirectKey ? "Saved in Keychain" : "Not set", showsChevron: false)
            }
        }
    }

    private var shortModelLabel: String { modelLabel.components(separatedBy: " - ").first ?? modelLabel }

    private var modelLabel: String {
        hermesVM.directProvider.curatedModels.first { $0.id == hermesVM.directModel }?.label ?? hermesVM.directModel
    }
}

// MARK: - Language and voice

private struct LanguageVoicePage: View {
    let hermesVM: HermesSessionViewModel
    @State private var setting: EmoDrinkLanguage.Setting = EmoDrinkLanguage.setting()

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $setting) {
                    ForEach(EmoDrinkLanguage.Setting.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .onChange(of: setting) { _, new in
                    EmoDrinkLanguage.setSetting(new)
                    hermesVM.applyLanguage()
                }
            } header: {
                Text("Language")
            } footer: {
                Text(languageFooter)
            }

            Section {
                LabeledContent("Speaking", value: languageLabel(hermesVM.activeLanguage))
                LabeledContent("Voice in use", value: hermesVM.voiceName ?? "System default")
                if hermesVM.voiceNeedsInstallHint {
                    Text(EmoDrinkStrings(language: hermesVM.activeLanguage).voiceInstallHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Voice")
            }

            micSection

            Section {
                ForEach(VoiceCommandCatalog.groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.title).font(.system(size: 15, weight: .semibold))
                        Text(group.examples.map { "\"\($0)\"" }.joined(separator: ", "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("What you can say")
            }
        }
        .hermesFormStyle()
        .navigationTitle("Language and voice")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The mid-session note shows only while a session runs: a change then
    /// applies from the next session (applyLanguage() leaves a running
    /// recognizer alone).
    private var languageFooter: String {
        let base = "Speech both ways, the lens and the spoken lines follow this. Auto uses the iPhone's first language."
        guard hermesVM.connectionState != .disconnected else { return base }
        return base + " A session is running, so a change applies from the next session."
    }

    private var micSection: some View {
        Section {
            Picker("Voice input", selection: Binding(
                get: { hermesVM.micSource },
                set: { newValue in
                    if newValue != hermesVM.micSource { Task { await hermesVM.setMicSource(newValue) } }
                }
            )) {
                ForEach(hermesVM.availableMicSources, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
        } header: {
            Text("Microphone")
        } footer: {
            Text("The glasses mic shows a call screen on the lens and hides the drink card. Headset mode (AirPods) keeps the lens free.")
        }
    }
}

/// The resolved language's name, from the same labels as the picker.
private func languageLabel(_ language: Language) -> String {
    (language == .ja ? EmoDrinkLanguage.Setting.ja : .en).label
}

// MARK: - Drinks

private struct DrinksPage: View {
    @Bindable var vm: EmoDrinkViewModel

    var body: some View {
        HermesScrollPage {
            watchSection
            dataSection
            catalogueSection
        }
        .navigationTitle("Drinks")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.refreshSnapshot() }
    }

    private var watchSection: some View {
        HermesSection(header: "Watching", footer: "One small vision call only when the scene changes and settles.") {
            Toggle(isOn: $vm.autoWatch) {
                HermesRow("Watch for vending machines when the app opens", icon: "eye", showsChevron: false)
            }
            .padding(.trailing, 16)
            HermesDivider()
            Stepper("Check every \(vm.intervalSeconds) s", value: $vm.intervalSeconds, in: 2...30)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            HermesDivider()
            HermesRow("Checks sent", icon: "paperplane", value: "\(vm.sentCount)", showsChevron: false)
            HermesDivider()
            HermesRow("Budget used", icon: "gauge.medium",
                      value: "\(vm.budgetUsed) of \(VendingMachineGate.defaultConfig.budgetPerHour) per hour", showsChevron: false)
            if let until = vm.restingUntil {
                HermesDivider()
                HermesRow("Resting until", icon: "moon.zzz",
                          value: until.formatted(date: .omitted, time: .shortened), showsChevron: false)
            }
            if let notice = vm.aiNotice {
                HermesDivider()
                HermesRow("Last AI note", icon: "exclamationmark.circle", subtitle: notice, showsChevron: false)
            }
        }
    }

    private var dataSection: some View {
        HermesSection(header: "Body data", footer: vm.snapshotNotice.map { "Using \($0)." } ?? "Fetched from the feed URL. Last night's sleep and this morning's HRV drive the pick.") {
            Toggle(isOn: $vm.useMock) {
                HermesRow("Use sample data", icon: "testtube.2", subtitle: "Works offline", showsChevron: false)
            }
            .padding(.trailing, 16)
            .onChange(of: vm.useMock) { _, _ in Task { await vm.refreshSnapshot() } }
            HermesDivider()
            if vm.useMock {
                Picker("Profile", selection: $vm.mockProfile) {
                    ForEach(MockProfile.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .onChange(of: vm.mockProfile) { _, _ in Task { await vm.refreshSnapshot() } }
            } else {
                TextField("Feed URL", text: $vm.sourceURLString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                HermesDivider()
                Button { Task { await vm.refreshSnapshot(force: true) } } label: {
                    HermesRow("Fetch again", icon: "arrow.clockwise", showsChevron: false)
                }
                .buttonStyle(.plain)
                .disabled(vm.fetching)
            }
        }
    }

    private var catalogueGroups: [(function: DrinkFunction, drinks: [Drink])] {
        guard let drinks = vm.catalog?.drinks else { return [] }
        return DrinkFunction.allCases.compactMap { f in
            let group = drinks.filter { $0.functions.first == f }
            return group.isEmpty ? nil : (function: f, drinks: group)
        }
    }

    private var catalogueSection: some View {
        HermesSection(header: "Catalogue", footer: "Public Asahi Group soft drinks, grouped by what they are for.") {
            Toggle(isOn: $vm.lowSugar) {
                HermesRow("Prefer low sugar", icon: "leaf", showsChevron: false)
            }
            .padding(.trailing, 16)
            HermesDivider()
            if vm.catalog != nil {
                ForEach(catalogueGroups, id: \.function) { group in
                    HermesSectionHeader(title: group.function.label)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                    ForEach(Array(group.drinks.enumerated()), id: \.element.id) { index, drink in
                        if index > 0 { HermesDivider() }
                        HermesRow(drink.name, icon: "cup.and.saucer", subtitle: "\(drink.nameJa) · \(drink.kind)",
                                  value: drink.functions.map(\.label).joined(separator: ", "), showsChevron: false)
                    }
                }
            } else {
                HermesRow("Catalogue missing from this build", icon: "exclamationmark.triangle", showsChevron: false)
            }
        }
    }
}
