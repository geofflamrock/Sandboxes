import SwiftUI
import AppKit

/// The output of a command that fixes the setup, such as installing sbx,
/// starting the daemon or signing in, laid out like the output of creating a
/// sandbox.
struct SbxCommandSheet: View {
    let run: SbxCommandRun
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(20)
            // Sheets separate their buttons from the content with a line.
            Divider()
            buttons
                .padding(20)
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 360, idealHeight: 440)
        .interactiveDismissDisabled(run.phase == .running)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if run.kind == .signIn, run.phase == .running, let signIn = run.deviceSignIn {
                deviceSignIn(signIn)
            }

            ConsoleOutputView(output: run.output)

            if case .failed = run.phase {
                VStack(alignment: .leading, spacing: 8) {
                    Text("If it doesn't work here, run this in Terminal instead:")
                        .foregroundStyle(.secondary)
                    CopyableCommand(command: run.commandLine)
                }
            }
        }
    }

    private var buttons: some View {
        HStack {
            Button("Copy Output", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(run.output.text, forType: .string)
            }
            Spacer()
            switch run.phase {
            case .running:
                Button("Cancel", role: .cancel) { run.cancel() }
                    .keyboardShortcut(.cancelAction)
            case .succeeded:
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            case .failed, .cancelled:
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .controlSize(.large)
    }

    /// The code to enter and a button to open the page to enter it on.
    private func deviceSignIn(_ signIn: SbxCommandRun.DeviceSignIn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in to Docker in your browser and enter this code when asked:")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text(signIn.code)
                    .font(.title2.monospaced().weight(.semibold))
                    .textSelection(.enabled)
                Button("Copy Code", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(signIn.code, forType: .string)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Copy the code")
                Spacer()
                Button("Open Sign-In Page") { openURL(signIn.url) }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.1), in: .rect(cornerRadius: 10))
    }

    private var titles: (running: String, succeeded: String, failed: String) {
        switch run.kind {
        case .install: ("Installing sbx…", "sbx Installed", "Couldn't Install sbx")
        case .upgrade: ("Upgrading sbx…", "sbx Upgraded", "Couldn't Upgrade sbx")
        case .startDaemon: ("Starting the sbx Daemon…", "Daemon Started", "Couldn't Start the Daemon")
        case .signIn: ("Signing In to Docker…", "Signed In", "Couldn't Sign In")
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            switch run.phase {
            case .running:
                ProgressView()
                    .controlSize(.small)
                Text(titles.running)
            case .succeeded:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(titles.succeeded)
            case let .failed(message):
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(titles.failed)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            case .cancelled:
                Image(systemName: "stop.circle.fill")
                    .foregroundStyle(.secondary)
                Text("Cancelled")
            }
        }
        .font(.headline)
    }
}

/// Streamed command output in a scrolling, monospaced panel that follows the
/// latest line.
struct ConsoleOutputView: View {
    let output: ConsoleOutput

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(output.lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .padding(12)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator)
        }
    }
}
