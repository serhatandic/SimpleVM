import SimpleVMCore
import SwiftUI

struct KeyboardProfileEditor: View {
    @Bindable var model: AppModel
    @Bindable var store: KeyboardProfileStore

    @State private var selectedID: UUID?
    @State private var draftName = ""
    @State private var draftBase = MachineInputProfile.macOSWindows
    @State private var draftRules = ""
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Profile", selection: $selectedID) {
                    Text("Select a profile").tag(UUID?.none)
                    ForEach(store.profiles) { profile in
                        Text(profile.name).tag(UUID?.some(profile.id))
                    }
                }
                Button("New") {
                    do {
                        let profile = try store.create(
                            baseProfile: .macOSWindows
                        )
                        selectedID = profile.id
                    } catch {
                        validationMessage = error.localizedDescription
                    }
                }
                .accessibilityIdentifier("keyboardProfiles.new")
                Button("Duplicate") {
                    guard let selectedProfile else { return }
                    do {
                        let profile = try store.duplicate(selectedProfile)
                        selectedID = profile.id
                    } catch {
                        validationMessage = error.localizedDescription
                    }
                }
                .disabled(selectedProfile == nil)
                Button("Delete", role: .destructive) {
                    guard let id = selectedID else { return }
                    Task {
                        do {
                            try store.delete(id: id)
                            await model.removeCustomInputProfile(id: id)
                            selectedID = store.profiles.first?.id
                        } catch {
                            validationMessage = error.localizedDescription
                        }
                    }
                }
                .disabled(selectedProfile == nil)
            }

            if selectedProfile != nil {
                TextField("Profile name", text: $draftName)
                Picker("Inherits from", selection: $draftBase) {
                    ForEach(KeyboardProfileStore.allowedBaseProfiles) {
                        profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                TextEditor(text: $draftRules)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 130)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.quaternary)
                    }
                    .accessibilityLabel("Keyboard profile mapping rules")
                    .accessibilityIdentifier("keyboardProfiles.rules")
                Text(
                    "One override per line: host shortcut -> guest shortcut. Example: cmd+semicolon -> shift+semicolon, or cmd+return -> command+return. Supported names include colon, tab, escape, arrows, delete, and F1–F12."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier(
                            "keyboardProfiles.validation"
                        )
                }
                Button("Save Profile") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("keyboardProfiles.save")
            } else {
                Text(
                    "Built-in profiles remain unchanged. Create a custom profile to inherit from one and override any shortcuts."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if selectedID == nil {
                selectedID = store.profiles.first?.id
            }
            loadSelected()
        }
        .onChange(of: selectedID) { _, _ in
            loadSelected()
        }
    }

    private var selectedProfile: CustomKeyboardProfile? {
        store.profile(id: selectedID)
    }

    private func loadSelected() {
        guard let selectedProfile else {
            draftName = ""
            draftBase = .macOSWindows
            draftRules = ""
            validationMessage = nil
            return
        }
        draftName = selectedProfile.name
        draftBase = selectedProfile.baseProfile
        draftRules = selectedProfile.rules
        validationMessage = nil
    }

    private func save() {
        guard let selectedID else { return }
        do {
            try store.save(
                id: selectedID,
                name: draftName,
                baseProfile: draftBase,
                rules: draftRules
            )
            validationMessage = "Saved."
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}
