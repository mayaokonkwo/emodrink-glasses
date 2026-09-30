//
// BuildCheckView.swift
//
// Build Check home: procedures (import, review, start), run settings, past
// runs. A running run takes over the screen with BuildRunView.
//

import SwiftUI
import UniformTypeIdentifiers

struct BuildCheckView: View {
    @Bindable var vm: BuildCheckViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var showPaste = false
    @State private var pasteTitle = ""
    @State private var pasteText = ""
    @State private var editing: Procedure?
    @State private var reviewing: BuildRun?

    init(vm: BuildCheckViewModel) { self.vm = vm }

    var body: some View {
        NavigationStack {
            Group {
                if vm.activeRun != nil {
                    BuildRunView(vm: vm)
                } else {
                    home
                }
            }
            .navigationTitle("Build Check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.pdf, .plainText, UTType(filenameExtension: "md") ?? .plainText]) { result in
                guard case .success(let url) = result else { return }
                Task { if let p = await vm.importDocument(at: url) { editing = p } }
            }
            .sheet(isPresented: $showPaste) { pasteSheet }
            .sheet(item: $editing) { p in ProcedureEditorView(vm: vm, procedure: p) }
            .sheet(item: $reviewing) { run in BuildRunReviewView(vm: vm, run: run) }
            .alert("Build Check", isPresented: Binding(get: { vm.errorMessage != nil },
                                                       set: { if !$0 { vm.errorMessage = nil } })) {
                Button("OK") { vm.errorMessage = nil }
            } message: { Text(vm.errorMessage ?? "") }
        }
    }

    private var home: some View {
        HermesScrollPage {
            HermesSection(header: "Procedures",
                          footer: "A procedure can run once you've reviewed it and marked it ready.") {
                ForEach(vm.procedures) { p in
                    Button { editing = p } label: {
                        HermesRow(p.title, icon: p.ready ? "checkmark.seal" : "pencil",
                                  subtitle: "\(p.steps.count) steps · v\(p.version)\(p.ready ? "" : " · draft")")
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if p.ready {
                            Button("Start run") { Task { await vm.startRun(p) } }
                        }
                        Button("Delete", role: .destructive) { vm.delete(p) }
                    }
                    HermesDivider()
                }
                Button { showImporter = true } label: {
                    HermesRow("Import a document", icon: "doc.badge.plus", subtitle: "PDF, text or Markdown")
                }.buttonStyle(.plain)
                HermesDivider()
                Button { showPaste = true } label: {
                    HermesRow("Paste or type steps", icon: "text.badge.plus")
                }.buttonStyle(.plain)
            }
            if vm.importing {
                HStack { ProgressView(); Text("Reading the document…").foregroundStyle(.secondary) }
                    .padding(.horizontal, 32)
            }
            if let ready = vm.procedures.first(where: \.ready) {
                HermesPrimaryButton(title: "Start run: \(ready.title)", systemImage: "play.fill") {
                    Task { await vm.startRun(ready) }
                }
                .padding(.horizontal, 16)
            }
            settingsSection
            runsSection
        }
    }

    private var settingsSection: some View {
        HermesSection(header: "Run settings",
                      footer: "Photos are always logged. The AI sees a photo only when the scene has changed and settled, at most once every 15 seconds and within the hourly budget.") {
            HermesRow(title: "Operator", showsChevron: false) {
                TextField("Name", text: $vm.operatorName)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 180)
            }
            HermesDivider()
            HermesRow(title: "Photo every", showsChevron: false) {
                Stepper("\(vm.intervalSeconds) s", value: $vm.intervalSeconds, in: 2...60)
                    .fixedSize()
            }
            HermesDivider()
            HermesRow(title: "AI checks per hour", showsChevron: false) {
                Stepper("\(vm.budgetPerHour)", value: $vm.budgetPerHour, in: 10...600, step: 10)
                    .fixedSize()
            }
            HermesDivider()
            HermesRow(title: "AI checks", subtitle: "Off = log photos and speech only", showsChevron: false) {
                Toggle("", isOn: $vm.checksEnabled).labelsHidden().tint(HermesTheme.accent)
            }
        }
    }

    private var runsSection: some View {
        HermesSection(header: "Past runs") {
            if vm.runs.isEmpty {
                HermesRow("No runs yet", showsChevron: false)
            }
            ForEach(vm.runs) { run in
                Button { reviewing = run } label: {
                    HermesRow(run.procedure.title, icon: "clock",
                              subtitle: "\(run.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(BuildRunSummary.flags(in: run).count) flags\(run.endedAt == nil ? " · unfinished" : "")")
                }
                .buttonStyle(.plain)
                .contextMenu { Button("Delete", role: .destructive) { vm.deleteRun(run) } }
                HermesDivider()
            }
        }
    }

    private var pasteSheet: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $pasteTitle)
                TextEditor(text: $pasteText).frame(minHeight: 280)
            }
            .hermesFormStyle()
            .navigationTitle("Paste steps")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showPaste = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        let text = pasteText, title = pasteTitle
                        showPaste = false
                        Task {
                            if let p = await vm.importText(text, title: title) {
                                editing = p
                                pasteText = ""; pasteTitle = ""
                            }
                        }
                    }
                    .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
