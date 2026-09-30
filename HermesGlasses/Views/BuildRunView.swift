//
// BuildRunView.swift
//
// The live run: camera feed, current step, controls that mirror the voice
// commands (so a run is operable with gloves on OR with the phone), the
// AI-call count, and any checks notice.
//

import SwiftUI

struct BuildRunView: View {
    @Bindable var vm: BuildCheckViewModel

    var body: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(HermesTheme.lensStage)
                if let image = vm.liveImage {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Text("Waiting for the camera…").foregroundStyle(HermesTheme.cream.opacity(0.6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack(spacing: 6) {
                    HermesStatusPill(text: "\(vm.aiCallCount) AI checks", icon: "sparkles")
                    if let notice = vm.checksNotice {
                        HermesStatusPill(text: notice, dot: HermesTheme.destructive)
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 320)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 16)

            if let run = vm.activeRun, let t = vm.tracker {
                let index = min(t.current, run.procedure.steps.count - 1)
                let step = run.procedure.steps[index]
                HermesSection(header: "Step \(index + 1) of \(run.procedure.steps.count)\(step.critical ? " · critical" : "")") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(step.text).font(.body)
                        if t.phase == .checking {
                            Label("Checking…", systemImage: "hourglass").foregroundStyle(.secondary)
                        }
                        if t.phase == .blocked {
                            Label("Blocked - fix it, or override", systemImage: "exclamationmark.octagon.fill")
                                .foregroundStyle(HermesTheme.destructive)
                        }
                        if let warning = vm.lastWarning {
                            Text(warning).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                controls(blocked: t.phase == .blocked)
            }
            Spacer(minLength: 0)
            HermesDestructiveButton(title: "End run") { vm.endRun() }
                .padding(.horizontal, 16)
        }
        .padding(.top, 8)
        .background(HermesTheme.groupedCanvas.ignoresSafeArea())
    }

    private func controls(blocked: Bool) -> some View {
        VStack(spacing: 8) {
            HermesPrimaryButton(title: "Step done", systemImage: "checkmark") {
                vm.command(.stepDone, via: .button)
            }
            HStack(spacing: 8) {
                chip("Confirmed") { vm.command(.confirmed, via: .button) }
                chip("Ignore") { vm.command(.ignore, via: .button) }
                chip("Fixed") { vm.command(.fixed, via: .button) }
                if blocked { chip("Override") { vm.command(.override, via: .button) } }
            }
        }
        .padding(.horizontal, 16)
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(HermesTheme.card, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
