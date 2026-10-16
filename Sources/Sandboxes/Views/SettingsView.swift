import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @AppStorage(SbxCLI.executablePathKey) private var customPath = ""
    @State private var resolvedPath: String?
    @State private var hasResolved = false
    @AppStorage(ApprovalNotifier.enabledKey) private var notifiesAboutApprovals = true
    @State private var loginItemStatus = SMAppService.mainApp.status
    @State private var loginItemError: String?
    @AppStorage(EnvironmentStore.directoryKey) private var environmentsPath = ""
    @State private var environmentsError: String?

    var body: some View {
        Form {
            Section {
                TextField("sbx location", text: $customPath, prompt: Text("Automatic"))
                    .font(.body.monospaced())
                LabeledContent("Using") {
                    if !hasResolved {
                        ProgressView().controlSize(.small)
                    } else if let resolvedPath {
                        Text(resolvedPath)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    } else {
                        Label("sbx not found", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Command Line Tool")
            } footer: {
                Text("Leave empty to find sbx on your login shell's PATH.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Folder") {
                    HStack {
                        TextField(
                            "Folder",
                            text: $environmentsPath,
                            prompt: Text((EnvironmentStore.defaultDirectory.path as NSString).abbreviatingWithTildeInPath)
                        )
                        .labelsHidden()
                        .font(.body.monospaced())
                        Button("Choose…", action: chooseEnvironmentsFolder)
                    }
                }
                HStack {
                    Spacer()
                    Button("Show in Finder", action: showEnvironmentsFolder)
                }
            } header: {
                Text("Environments")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let environmentsError {
                        Text("Couldn't open the folder: \(environmentsError)")
                    }
                    Text("Environments saved from the create sheet go here, each as a folder with an sbxenv.yaml file for sbx env create. Leave empty to use the default folder.")
                }
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Notify me when a sandbox is waiting for approval", isOn: $notifiesAboutApprovals)
                Toggle("Open at login", isOn: Binding(
                    get: { loginItemStatus == .enabled || loginItemStatus == .requiresApproval },
                    set: setOpensAtLogin
                ))
                if loginItemStatus == .requiresApproval {
                    LabeledContent("Allow Sandboxes to open at login in System Settings.") {
                        Button("Open Login Items…") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let loginItemError {
                        Text("Couldn't change whether Sandboxes opens at login: \(loginItemError)")
                    }
                    Text("Sandboxes keeps running in the menu bar when you close its window, so it can notify you. Click a notification to review the request. Choose how notifications appear in System Settings › Notifications.")
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .background(WindowReader(kind: .settings))
        .onChange(of: notifiesAboutApprovals) { _, isOn in
            if isOn {
                ApprovalNotifier.shared.requestAuthorization()
            }
        }
        .onAppear {
            // It can change in System Settings while Settings is closed.
            loginItemStatus = SMAppService.mainApp.status
        }
        .task(id: customPath) {
            resolvedPath = await Task.detached { SbxCLI.executableURL()?.path }.value
            hasResolved = true
        }
    }

    private func chooseEnvironmentsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = EnvironmentStore.directory
        panel.prompt = "Choose"
        panel.message = "Choose the folder to save sandbox environments in."
        if panel.runModal() == .OK, let url = panel.url {
            environmentsPath = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }

    private func showEnvironmentsFolder() {
        do {
            NSWorkspace.shared.open(try EnvironmentStore.createDirectory())
            environmentsError = nil
        } catch {
            environmentsError = error.localizedDescription
        }
    }

    private func setOpensAtLogin(_ isOn: Bool) {
        do {
            if isOn {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        loginItemStatus = SMAppService.mainApp.status
    }
}
