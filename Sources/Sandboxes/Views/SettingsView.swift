import SwiftUI

struct SettingsView: View {
    @AppStorage(SbxCLI.executablePathKey) private var customPath = ""
    @State private var resolvedPath: String?
    @State private var hasResolved = false

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
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: customPath) {
            resolvedPath = await Task.detached { SbxCLI.executableURL()?.path }.value
            hasResolved = true
        }
    }
}
