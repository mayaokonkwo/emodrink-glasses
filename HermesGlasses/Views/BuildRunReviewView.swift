//
// BuildRunReviewView.swift
//
// One run, grouped by step with a status each; tap a step to scrub its
// frames, with every check and the AI's reasoning beside the frame it
// judged. Exports the PDF report and the raw zip.
//

import SwiftUI

struct BuildRunReviewView: View {
    let vm: BuildCheckViewModel
    let run: BuildRun
    @Environment(\.dismiss) private var dismiss
    @State private var shareURL: URL?

    private struct ShareItem: Identifiable { let id = UUID(); let url: URL }

    var body: some View {
        let statuses = BuildRunSummary.stepStatuses(run)
        NavigationStack {
            HermesScrollPage {
                HermesSection(header: "\(run.operatorName.isEmpty ? "" : run.operatorName + " · ")\(run.startedAt.formatted(date: .abbreviated, time: .shortened))",
                              footer: "\(ByteCountFormatter.string(fromByteCount: vm.runStore.diskSize(runID: run.id), countStyle: .file)) on this iPhone") {
                    ForEach(Array(run.procedure.steps.enumerated()), id: \.offset) { i, step in
                        NavigationLink {
                            StepDetail(vm: vm, run: run, step: i)
                        } label: {
                            HermesRow(step.text, icon: icon(statuses[i]), subtitle: label(statuses[i]))
                        }
                        .buttonStyle(.plain)
                        HermesDivider()
                    }
                }
                HStack(spacing: 8) {
                    HermesPrimaryButton(title: "PDF report", systemImage: "doc.richtext") {
                        let url = FileManager.default.temporaryDirectory
                            .appendingPathComponent("\(run.procedure.title)-\(run.id.uuidString.prefix(8)).pdf")
                        try? BuildRunPDF.make(run: run, store: vm.runStore).write(to: url)
                        shareURL = url
                    }
                    HermesPrimaryButton(title: "Raw zip", systemImage: "archivebox") {
                        shareURL = BuildRunPDF.zip(runID: run.id, store: vm.runStore)
                    }
                }
                .padding(.horizontal, 16)
            }
            .navigationTitle(run.procedure.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: Binding(get: { shareURL.map { ShareItem(url: $0) } },
                                 set: { if $0 == nil { shareURL = nil } })) { item in
                ShareSheet(items: [item.url])
            }
        }
    }

    private func icon(_ s: StepStatus) -> String {
        switch s {
        case .passed: return "checkmark.circle"
        case .flagResolved: return "exclamationmark.triangle"
        case .unresolved: return "xmark.octagon"
        case .unchecked: return "forward.end"
        }
    }

    private func label(_ s: StepStatus) -> String {
        switch s {
        case .passed: return "Passed end-of-step check"
        case .flagResolved: return "Flag resolved"
        case .unresolved: return "Unresolved or overridden"
        case .unchecked: return "Not checked"
        }
    }
}

private struct StepDetail: View {
    let vm: BuildCheckViewModel
    let run: BuildRun
    let step: Int

    var body: some View {
        let events = run.events.filter { $0.step == step && ($0.kind == .frame || $0.kind == .check || $0.kind == .speech || $0.kind == .reply) }
        List(Array(events.enumerated()), id: \.offset) { _, e in
            VStack(alignment: .leading, spacing: 4) {
                Text(e.t.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
                switch e.kind {
                case .frame:
                    if let name = e.filename,
                       let image = UIImage(contentsOfFile: vm.runStore.frameURL(runID: run.id, filename: name).path) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                        if e.sentToAI == true { Text("Sent to AI").font(.caption2) }
                    }
                case .check:
                    Text("\(e.checkKind == .full ? "End-of-step" : "Quick") check: \(e.result?.verdict.rawValue ?? "failed")\(e.result.map { String(format: " (%.0f%%)", $0.confidence * 100) } ?? "")")
                        .font(.subheadline.weight(.semibold))
                    if let r = e.result {
                        if !r.observed.isEmpty { Text("Saw: \(r.observed)").font(.footnote) }
                        if !r.issue.isEmpty { Text(r.issue).font(.footnote).foregroundStyle(HermesTheme.destructive) }
                    }
                    if let err = e.error { Text(err).font(.footnote).foregroundStyle(.secondary) }
                case .speech:
                    Text("“\(e.text ?? "")”").font(.footnote).italic()
                case .reply:
                    Text("Reply: \(e.reply?.rawValue ?? "")").font(.footnote.weight(.semibold))
                        .foregroundStyle(e.reply == .override ? HermesTheme.destructive : .primary)
                default:
                    EmptyView()
                }
            }
        }
        .hermesFormStyle()
        .navigationTitle("Step \(step + 1)")
    }
}
