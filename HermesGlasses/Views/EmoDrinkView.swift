//
// EmoDrinkView.swift
//
// The one EmoDrink screen: today's body data (and where it came from), the
// current pick with its three replies, drink mode with its counters, and
// the catalogue. Settings live here too, so the gift is a single sheet.
//

import SwiftUI

struct EmoDrinkView: View {
    @Bindable var vm: EmoDrinkViewModel
    @Environment(\.dismiss) private var dismiss

    init(vm: EmoDrinkViewModel) { self.vm = vm }

    var body: some View {
        NavigationStack {
            HermesScrollPage {
                todaySection
                pickSection
                drinkModeSection
                catalogueSection
            }
            .navigationTitle("EmoDrink")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("EmoDrink", isPresented: Binding(get: { vm.errorMessage != nil },
                                                   set: { if !$0 { vm.errorMessage = nil } })) {
                Button("OK") { vm.errorMessage = nil }
            } message: { Text(vm.errorMessage ?? "") }
            .task { await vm.refreshSnapshot() }
        }
        .tint(HermesTheme.accent)
    }

    // MARK: Today

    private var snapshot: PhysiologySnapshot? {
        vm.useMock ? vm.mockProfile.snapshot(date: EmoDrinkDay.string()) : vm.currentSnapshot
    }

    private var todaySection: some View {
        HermesSection(header: "Today",
                      footer: vm.snapshotNotice.map { "Using \($0)." } ?? "Fetched from the feed URL below. Last night's sleep and this morning's HRV drive the pick.") {
            if let s = snapshot {
                HStack(spacing: 12) {
                    HermesStatTile(value: String(format: "%.1f h", s.sleep.hours), caption: "sleep")
                    HermesStatTile(value: s.sleep.score.map(String.init) ?? "–", caption: "score")
                    HermesStatTile(value: s.hrvMs.map { "\(Int($0.rounded()))" } ?? "–", caption: "HRV ms")
                    HermesStatTile(value: s.restingHR.map { "\(Int($0.rounded()))" } ?? "–", caption: "rest HR")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                HermesDivider()
                HermesRow("Source", icon: "antenna.radiowaves.left.and.right", subtitle: s.date,
                          value: vm.useMock ? s.source : (vm.snapshotNotice ?? (vm.cached?.sourceLabel ?? s.source)), showsChevron: false)
            } else {
                HermesRow("No data yet", icon: "moon.zzz", subtitle: vm.fetching ? "Fetching…" : "Pull the feed or switch to sample data",
                          showsChevron: false)
            }
            HermesDivider()
            Button { Task { await vm.refreshSnapshot(force: true) } } label: {
                HermesRow("Fetch again", icon: "arrow.clockwise", showsChevron: false)
            }
            .buttonStyle(.plain)
            .disabled(vm.useMock || vm.fetching)
            HermesDivider()
            Toggle(isOn: $vm.useMock) {
                HermesRow("Use sample data", icon: "testtube.2", subtitle: "Works offline", showsChevron: false)
            }
            .padding(.trailing, 16)
            .onChange(of: vm.useMock) { _, _ in Task { await vm.refreshSnapshot() } }
            if vm.useMock {
                HermesDivider()
                Picker("Profile", selection: $vm.mockProfile) {
                    ForEach(MockProfile.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .onChange(of: vm.mockProfile) { _, _ in Task { await vm.refreshSnapshot() } }
            } else {
                HermesDivider()
                TextField("Feed URL", text: $vm.sourceURLString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
    }

    // MARK: Pick

    private var pickSection: some View {
        HermesSection(header: "Pick",
                      footer: vm.aiNotice.map { "AI: \($0)." } ?? "Say \"what should I drink\" on the glasses, or tap below.") {
            if let pick = vm.currentPick, let rec = vm.recommendation {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pick.name).font(.system(size: 22, weight: .bold))
                    Text(pick.nameJa).foregroundStyle(.secondary)
                    Text(rec.reasons.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                if vm.momentActive {
                    HStack(spacing: 10) {
                        Button("Why") { vm.why() }
                        Button("Something else") { vm.somethingElse() }
                        Button("Thanks") { vm.thanks() }
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
                HermesDivider()
            }
            HermesPrimaryButton(title: vm.momentActive ? "Pick again" : "Pick a drink now",
                                systemImage: "cup.and.saucer", enabled: vm.hasCatalog) {
                Task { await vm.pickNow() }
            }
            .padding(16)
        }
    }

    // MARK: Drink mode

    private var drinkModeSection: some View {
        HermesSection(header: "Drink mode",
                      footer: "Watches the camera and offers the pick when a vending machine comes into view. One small vision call only when the scene changes and settles.") {
            Toggle(isOn: Binding(get: { vm.drinkModeOn }, set: { _ in vm.toggleDrinkMode() })) {
                HermesRow(vm.drinkModeOn ? "Watching" : "Off", icon: "eye", showsChevron: false)
            }
            .padding(.trailing, 16)
            if vm.drinkModeOn {
                HermesDivider()
                HStack(spacing: 12) {
                    HermesStatTile(value: "\(vm.frameCount)", caption: "frames")
                    HermesStatTile(value: "\(vm.sentCount)", caption: "sent to AI")
                    HermesStatTile(value: "\(vm.budgetUsed)/\(VendingMachineGate.defaultConfig.budgetPerHour)", caption: "budget / h")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                if let until = vm.restingUntil {
                    HermesDivider()
                    HermesRow("Resting until \(until.formatted(date: .omitted, time: .shortened))", icon: "zzz", showsChevron: false)
                }
                if let image = vm.liveImage {
                    HermesDivider()
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(16)
                }
            }
            HermesDivider()
            Stepper("Check every \(vm.intervalSeconds) s", value: $vm.intervalSeconds, in: 2...30)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
    }

    // MARK: Catalogue

    private var catalogueGroups: [(function: DrinkFunction, drinks: [Drink])] {
        guard let drinks = vm.catalog?.drinks else { return [] }
        return DrinkFunction.allCases.compactMap { f in
            let group = drinks.filter { $0.functions.first == f }
            return group.isEmpty ? nil : (function: f, drinks: group)
        }
    }

    private var catalogueSection: some View {
        HermesSection(header: "Catalogue", footer: "Public Asahi Group soft drinks, grouped by what they are for. Edit asahi-drinks.json to change the list.") {
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
