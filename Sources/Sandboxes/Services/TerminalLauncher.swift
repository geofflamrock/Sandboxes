import AppKit

/// Opens the user's terminal running an sbx command. Writes a throwaway
/// executable with no extension and opens it with whichever app handles Unix
/// executables: Terminal by default, or a terminal set as the default (e.g.
/// Ghostty). This also means the app doesn't need Automation permission.
enum TerminalLauncher {
    /// Runs `sbx` with `sbxArguments`, in `directory` when it's given.
    static func open(sbxArguments: [String], in directory: URL? = nil) throws {
        guard let executable = SbxCLI.executableURL() else {
            throw SbxError.executableNotFound
        }
        var command = ([executable.path] + sbxArguments).map(shellQuote).joined(separator: " ")
        if let directory {
            command = "cd \(shellQuote(directory.path)) && \(command)"
        }
        let script = """
            #!/bin/zsh -l
            rm -f "$0"
            clear
            \(command)

            """

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("sbx-app", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(UUID().uuidString)
        try script.write(to: file, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)

        NSWorkspace.shared.open(file)
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
