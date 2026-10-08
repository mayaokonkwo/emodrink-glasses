//
// GlassesBasicsView.swift
// EmoDrink Glasses
//
// Settings › Glasses › Developer › Glasses basics, full screen: text on
// the glasses display, the glasses camera feed on the phone, and a frame
// to the vending machine check. Plain list, no app styling. Driven by
// GlassesBasicsViewModel over GlassesLink (a near-copy of Meta's
// DisplayAccess and CameraAccess samples), the path EmoDrink itself uses.
//

import SwiftUI

struct GlassesBasicsView: View {
    @Bindable var viewModel: GlassesBasicsViewModel
    /// Presented full screen from Settings: show a Done button.
    var showsDone = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                statusSection
                displaySection
                cameraSection
                vendingSection
                resetSection
                logSection
            }
            .navigationTitle("Glasses basics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .task { await viewModel.refreshCameraPermission() }
        }
    }

    // MARK: - 1. Status

    private var statusSection: some View {
        Section("Status") {
            row("Registration", viewModel.registrationText)
            if !viewModel.isRegistered {
                Button("Connect glasses") { viewModel.connectGlasses() }
                    .disabled(viewModel.isRegistering)
            }
            if viewModel.devices.isEmpty {
                row("Device", "none")
            }
            ForEach(viewModel.devices) { device in
                row("Device", device.name)
                row("Link", device.linkText)
                row("Compatibility", device.compatibilityText)
                row("Display capable", device.supportsDisplay ? "yes" : "no")
                if device.needsFirmwareUpdate {
                    Button("Update glasses firmware") { viewModel.openFirmwareUpdate() }
                }
            }
            row("Device session", viewModel.sessionStateText)
            if viewModel.requiresDATAppUpdate {
                Button("Update DAT app on glasses") { viewModel.openDATGlassesAppUpdate() }
            }
            row("Camera permission", viewModel.cameraPermissionText)
            Button("Request camera permission") { viewModel.requestCameraPermission() }
        }
    }

    // MARK: - 2. Display

    private var displaySection: some View {
        Section("Test 1: Glasses display") {
            TextField("Text to show", text: $viewModel.displayText)
            Button {
                viewModel.sendToGlasses()
            } label: {
                Text(viewModel.isSending ? "Sending..." : "Send to glasses")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewModel.isSending)
            Button("Clear glasses display") { viewModel.clearGlassesDisplay() }
            row("Display state", viewModel.displayStateText)
        }
    }

    // MARK: - 3. Camera

    private var cameraSection: some View {
        Section("Test 2: Glasses camera") {
            Button {
                viewModel.toggleCamera()
            } label: {
                Text(viewModel.cameraRequested ? "Stop camera feed" : "Start camera feed")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            BasicsPreview(viewModel: viewModel)
                .listRowInsets(EdgeInsets())
            row("Stream state", viewModel.streamStateText)
            row("Frames received", "\(viewModel.framesReceived)")
            row("Measured fps", String(format: "%.1f", viewModel.measuredFPS))
            row("Resolution", viewModel.resolutionText)
        }
    }

    // MARK: - 4. Vending machine check

    private var vendingSection: some View {
        Section("Test 3: Vending machine check") {
            if let reason = viewModel.visionBlockedReason {
                Text("Unavailable: \(reason)")
                    .foregroundStyle(.red)
            }
            Button {
                viewModel.checkNow()
            } label: {
                Text(viewModel.isChecking ? "Checking..." : "Check now")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.canCheckNow)
            Toggle("Check every 5 s", isOn: Binding(
                get: { viewModel.autoCheck },
                set: { viewModel.setAutoCheck($0) }
            ))
            .disabled(viewModel.visionBlockedReason != nil || !viewModel.cameraRequested)
            row("Last result", viewModel.checkResultText)
            row("Time taken", viewModel.checkDurationText)
            row("Checks run", "\(viewModel.checkCount)")
        }
    }

    // MARK: - 5. Reset

    private var resetSection: some View {
        Section {
            Button("Reset (stop display, camera and session)", role: .destructive) {
                viewModel.reset()
            }
        }
    }

    // MARK: - Log

    private var logSection: some View {
        Section("Log (newest first)") {
            if viewModel.log.isEmpty {
                Text("empty").foregroundStyle(.secondary)
            }
            ForEach(viewModel.log) { line in
                Text(line.text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
    }
}

/// Isolated so ~24 fps frame updates re-render only the preview.
private struct BasicsPreview: View {
    let viewModel: GlassesBasicsViewModel

    var body: some View {
        Color.black
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let image = viewModel.previewImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Text("No frames")
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .clipped()
    }
}
