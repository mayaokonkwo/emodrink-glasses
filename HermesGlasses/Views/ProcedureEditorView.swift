//
// ProcedureEditorView.swift
//
// The review screen every procedure passes before it can run: edit, reorder,
// merge, split, delete steps; confirm the critical flags; add up to three
// reference photos per step (camera or photo library). Saving an edit bumps
// the version and returns it to draft; "Mark ready" is the only way out.
//

import PhotosUI
import SwiftUI

struct ProcedureEditorView: View {
    @Bindable var vm: BuildCheckViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var procedure: Procedure
    @State private var original: Procedure
    @State private var pickerStepID: UUID?
    @State private var pickerItem: PhotosPickerItem?
    @State private var capturing = false

    init(vm: BuildCheckViewModel, procedure: Procedure) {
        self.vm = vm
        _procedure = State(initialValue: procedure)
        _original = State(initialValue: procedure)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Title") {
                    TextField("Procedure title", text: $procedure.title)
                }
                Section {
                    ForEach($procedure.steps) { $step in
                        stepEditor($step)
                    }
                    .onMove { procedure.steps.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { procedure.steps.remove(atOffsets: $0) }
                    Button("Add step") { procedure.steps.append(ProcedureStep(text: "")) }
                } header: {
                    Text("Steps")
                } footer: {
                    Text("Critical steps hold the run until their check passes. The AI suggested these flags; confirm each one.")
                }
            }
            .hermesFormStyle()
            .environment(\.editMode, .constant(.active))
            .navigationTitle(procedure.ready ? "Procedure" : "Review procedure")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { saveAndClose(markReady: false) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Mark ready") { saveAndClose(markReady: true) }
                        .disabled(!procedure.canBeReady)
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item, let stepID = pickerStepID else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        addPhoto(image, to: stepID)
                    }
                    pickerItem = nil
                }
            }
        }
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private func stepEditor(_ step: Binding<ProcedureStep>) -> some View {
        let index = procedure.steps.firstIndex(where: { $0.id == step.wrappedValue.id }) ?? 0
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Step \(index + 1)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Toggle("Critical", isOn: step.critical).fixedSize().tint(HermesTheme.accent)
            }
            TextField("Instruction", text: step.text, axis: .vertical)
            TextField("When done it looks like… (optional)", text: step.expectedLook, axis: .vertical)
                .font(.footnote)
            ScrollView(.horizontal) {
                HStack {
                    ForEach(step.wrappedValue.referencePhotoFilenames, id: \.self) { name in
                        if let image = UIImage(contentsOfFile: vm.procedureStore.photoURL(name).path) {
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
                                .contextMenu {
                                    Button("Remove", role: .destructive) {
                                        step.wrappedValue.referencePhotoFilenames.removeAll { $0 == name }
                                    }
                                }
                        }
                    }
                    if step.wrappedValue.referencePhotoFilenames.count < Procedure.maxReferencePhotos {
                        Menu {
                            Button("From the camera") { capture(for: step.wrappedValue.id) }
                            PhotosPicker("From the photo library", selection: Binding(
                                get: { pickerItem },
                                set: { pickerStepID = step.wrappedValue.id; pickerItem = $0 }),
                                matching: .images)
                        } label: {
                            Label("Reference", systemImage: "camera").font(.footnote)
                        }
                        .disabled(capturing)
                    }
                }
            }
            HStack {
                Button("Split at end") {
                    let i = index
                    procedure.steps.insert(ProcedureStep(text: ""), at: i + 1)
                }.font(.footnote)
                if index + 1 < procedure.steps.count {
                    Button("Merge with next") {
                        let next = procedure.steps.remove(at: index + 1)
                        procedure.steps[index].text += " " + next.text
                        procedure.steps[index].critical = procedure.steps[index].critical || next.critical
                        procedure.steps[index].referencePhotoFilenames = Array(
                            (procedure.steps[index].referencePhotoFilenames + next.referencePhotoFilenames)
                                .prefix(Procedure.maxReferencePhotos))
                    }.font(.footnote)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private func capture(for stepID: UUID) {
        capturing = true
        Task {
            if let image = await vm.captureReferenceFromCamera() { addPhoto(image, to: stepID) }
            capturing = false
        }
    }

    private func addPhoto(_ image: UIImage, to stepID: UUID) {
        var copy = procedure
        if vm.addReferencePhoto(image, to: stepID, in: &copy) {
            // addReferencePhoto went through edit(); keep only the new filename
            // here - versioning happens once, on save.
            procedure.steps = copy.steps
        }
    }

    private func saveAndClose(markReady: Bool) {
        var result = original
        if procedure.title != original.title || procedure.steps != original.steps {
            result.edit { $0.title = procedure.title; $0.steps = procedure.steps }
        }
        if markReady { result.markReady() }
        vm.save(result)
        dismiss()
    }
}
