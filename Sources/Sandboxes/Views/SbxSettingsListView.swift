import SwiftUI
import AppKit

/// Management › Settings: the settings of Docker Sandboxes from
/// `sbx settings ls`, grouped by the start of their keys, with ways to
/// change them and put them back to their defaults. Not this app's settings,
/// which are in the Settings window.
struct SbxSettingsListView: View {
    @Environment(SandboxStore.self) private var store
    @Environment(SbxSettingStore.self) private var settings
    @State private var editing: SbxSetting?

    var body: some View {
        @Bindable var settings = settings

        Form {
            if !settings.keysAwaitingRestart.isEmpty {
                Section {
                    LabeledContent {
                        Button("Restart Daemon…") {
                            settings.restartPrompt = SbxSettingStore.RestartPrompt(key: nil)
                        }
                        .disabled(settings.restart?.phase == .running)
                    } label: {
                        Label {
                            Text("Restart the daemon to finish applying your changes")
                            Text(settings.keysAwaitingRestart.sorted().joined(separator: ", "))
                                .font(.caption.monospaced())
                        } icon: {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            if settings.settings.isEmpty {
                Section {
                    if let error = settings.loadError {
                        Text("Couldn't list settings: \(error)")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else {
                        Text(settings.hasLoaded ? "sbx didn't list any settings." : "Loading…")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ForEach(settings.groups) { group in
                Section {
                    ForEach(group.settings) { setting in
                        SbxSettingRow(setting: setting, editing: $editing)
                    }
                } header: {
                    Text(Self.title(forGroup: group.name))
                }
            }

            if !settings.settings.isEmpty {
                Section {
                } footer: {
                    if let error = settings.loadError {
                        Text("Couldn't refresh settings: \(error)")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Settings from sbx settings. Environment variables take precedence over values set here, and administrator policy over both. Most changes apply within a few seconds.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task {
            await settings.refresh()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Home", systemImage: "chevron.backward") {
                    store.selection = nil
                }
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to Home")
            }
            ToolbarItem {
                Button("Restart Daemon", systemImage: "arrow.clockwise") {
                    settings.restartPrompt = SbxSettingStore.RestartPrompt(key: nil)
                }
                .disabled(settings.restart?.phase == .running)
                .help("Restart the sbx daemon, which some settings need before they apply")
            }
        }
        .sheet(item: $editing) { setting in
            SbxSettingEditor(setting: setting)
        }
        .sheet(item: $settings.restart) { run in
            SbxCommandSheet(run: run)
        }
        // Waits for the editor to close, so the dialog isn't behind it.
        .confirmationDialog(
            "Restart the sbx Daemon?",
            isPresented: Binding(
                get: { settings.restartPrompt != nil && editing == nil },
                set: { if !$0 { settings.restartPrompt = nil } }
            ),
            presenting: settings.restartPrompt
        ) { _ in
            Button("Restart Daemon") {
                settings.restartDaemon { [store] in
                    Task { await store.refresh() }
                }
            }
            Button("Not Now", role: .cancel) {}
        } message: { prompt in
            Text(restartMessage(for: prompt))
        }
    }

    private func restartMessage(for prompt: SbxSettingStore.RestartPrompt) -> String {
        var message = prompt.key.map { "“\($0)” only applies everywhere once the daemon restarts." } ?? ""
        if store.sandboxes.contains(where: { $0.state == .running }) {
            message += (message.isEmpty ? "" : " ") + "Restarting may stop your running sandboxes."
        }
        return message
    }

    /// Such as "Kit" for `kit.requireSignature`, or "No Proxy" for `no_proxy`.
    static func title(forGroup group: String) -> String {
        switch group.lowercased() {
        case "mcp": "MCP"
        case "ssh": "SSH"
        case "tls": "TLS"
        case "env": "Environments"
        default: group.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// A setting's key and description, with a switch for a boolean or its
/// value and an Edit button for anything else.
private struct SbxSettingRow: View {
    let setting: SbxSetting
    @Binding var editing: SbxSetting?
    @Environment(SbxSettingStore.self) private var settings

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(setting.key)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    badges
                }
                if !setting.description.isEmpty {
                    Text(setting.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(setting.description)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .contextMenu {
            if setting.isAvailable {
                Button("Edit…") { editing = setting }
            }
            if setting.isOverridden {
                Button("Reset to Default") {
                    Task { await settings.reset(setting) }
                }
            }
            Divider()
            Button("Copy Key") { copy(setting.key) }
            if let value = setting.value {
                Button("Copy Value") { copy(value) }
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        if settings.isBusy(setting) {
            ProgressView()
                .controlSize(.small)
        } else if !setting.isAvailable {
            Text("Unavailable")
                .foregroundStyle(.secondary)
                .help(setting.error ?? "sbx couldn't read this setting.")
        } else if setting.type == .bool, let isOn = setting.boolValue {
            Toggle(setting.key, isOn: Binding(
                get: { isOn },
                set: { value in Task { await settings.set(setting, to: value) } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            // The environment variable would win, so the switch would just
            // flip back.
            .disabled(setting.source == .environment)
            .help(setting.source == .environment
                  ? "Set by $\(setting.environmentVariable ?? "an environment variable"), which takes precedence"
                  : "")
        } else {
            HStack(spacing: 10) {
                Text(displayValue)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .trailing)
                    .help(setting.value ?? "")
                Button("Edit…") { editing = setting }
            }
        }
    }

    private var displayValue: String {
        guard let value = setting.value, !value.isEmpty else { return "Not set" }
        return value
    }

    @ViewBuilder
    private var badges: some View {
        switch setting.source {
        case .override:
            SettingBadge(text: "Set", color: .accentColor)
                .help("Set with sbx settings set. Reset it to go back to \(setting.defaultValue.map { $0.isEmpty ? "no value" : $0 } ?? "the default").")
        case .environment:
            SettingBadge(text: "Environment", color: .purple)
                .help("Set by $\(setting.environmentVariable ?? "an environment variable"), which takes precedence over a value set here")
        case .default, .unavailable, .other:
            EmptyView()
        }
        if settings.keysAwaitingRestart.contains(setting.key) {
            SettingBadge(text: "Restart Needed", color: .orange)
                .help("Changed since the daemon last restarted. Restart it to apply the change everywhere.")
        } else if setting.requiresRestart {
            Image(systemName: "arrow.clockwise")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("Changes apply everywhere once the daemon restarts")
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct SettingBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: .capsule)
    }
}

/// Changes one setting, with an input that suits its type: on or off for a
/// boolean, a number field that checks what's typed, or a JSON editor.
private struct SbxSettingEditor: View {
    let setting: SbxSetting
    @Environment(SbxSettingStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    /// The setting as `sbx settings get` returns it, with its full value.
    @State private var current: SbxSetting?
    @State private var text = ""
    @State private var isOn = false
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var error: String?

    private var shown: SbxSetting { current ?? setting }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Type", value: shown.type.title)
                    LabeledContent("Source") {
                        Text(sourceText)
                            .textSelection(.enabled)
                    }
                    if let defaultValue = shown.defaultValue {
                        LabeledContent("Default") {
                            Text(defaultValue.isEmpty ? "No value" : defaultValue)
                                .font(.callout.monospaced())
                                .lineLimit(3)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    Text(shown.key)
                        .font(.headline.monospaced())
                } footer: {
                    if !shown.description.isEmpty {
                        Text(shown.description)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Section {
                    input
                        .disabled(isLoading)
                } header: {
                    Text("Value")
                } footer: {
                    if let error {
                        Text(error)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    } else if let problem {
                        Text(problem)
                            .foregroundStyle(.red)
                    } else if let note {
                        Text(note)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isSaving)

            // Sheets separate their buttons from the content with a line.
            Divider()

            HStack {
                if shown.isOverridden {
                    Button("Reset to Default") {
                        Task { await reset() }
                    }
                    .disabled(isSaving)
                    .help("Remove the value set here, so the setting goes back to its default")
                }
                if isSaving || isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(isSaving || isLoading || problem != nil)
                .help(problem ?? "")
            }
            .padding(20)
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: shown.type == .json ? 460 : 380, idealHeight: shown.type == .json ? 540 : 420)
        .navigationTitle("Edit Setting")
        .task {
            let latest = await settings.reload(setting) ?? setting
            current = latest
            switch latest.type {
            case .bool:
                isOn = latest.boolValue ?? false
            case .json:
                text = latest.value.map(SbxSettingParser.prettyJSON) ?? ""
            case .int, .float, .string, .other:
                text = latest.value ?? ""
            }
            isLoading = false
        }
    }

    @ViewBuilder
    private var input: some View {
        switch shown.type {
        case .bool:
            Picker("Value", selection: $isOn) {
                Text("On").tag(true)
                Text("Off").tag(false)
            }
            .pickerStyle(.segmented)
        case .json:
            TextEditor(text: $text)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                .frame(minHeight: 160)
                .labelsHidden()
        case .int, .float:
            TextField("Value", text: $text, prompt: Text(shown.defaultValue ?? ""))
                .font(.body.monospaced())
        case .string, .other:
            TextField("Value", text: $text, prompt: Text(shown.defaultValue.flatMap { $0.isEmpty ? nil : $0 } ?? "No value"))
                .font(.body.monospaced())
                .autocorrectionDisabled()
        }
    }

    /// What `sbx settings set` would refuse, checked before it's asked.
    private var problem: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch shown.type {
        case .int:
            return Int(trimmed) == nil ? "Enter a whole number." : nil
        case .float:
            return Double(trimmed) == nil ? "Enter a number." : nil
        case .json:
            guard let data = trimmed.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil
            else { return trimmed.isEmpty ? "Enter a JSON value." : "This isn't valid JSON." }
            return nil
        case .bool, .string, .other:
            return nil
        }
    }

    private var note: String? {
        if shown.source == .environment {
            return "$\(shown.environmentVariable ?? "An environment variable") sets this, and takes precedence over a value set here."
        }
        if shown.requiresRestart {
            return "Applies everywhere once the sbx daemon restarts. You can restart it after saving."
        }
        return nil
    }

    private var sourceText: String {
        switch shown.source {
        case .default: "Default"
        case .override: "Set with sbx settings set"
        case .environment: shown.environmentVariable.map { "$\($0)" } ?? "Environment variable"
        case .unavailable: shown.error ?? "Unavailable"
        case let .other(name): name
        }
    }

    private var valueToSave: String {
        switch shown.type {
        case .bool: isOn ? "true" : "false"
        case .int, .float, .json: text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .string, .other: text
        }
    }

    private func save() async {
        isSaving = true
        error = nil
        do {
            try await settings.set(shown, to: valueToSave)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isSaving = false
    }

    private func reset() async {
        isSaving = true
        error = nil
        do {
            try await settings.unset(shown)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isSaving = false
    }
}
