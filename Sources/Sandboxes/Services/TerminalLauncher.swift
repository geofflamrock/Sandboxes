import AppKit

/// Opens the user's terminal running an sbx command. Uses a throwaway `.command`
/// file so the app doesn't need Automation permission, and opens it with
/// whichever app handles `.command` files (Terminal unless changed in Finder).
enum TerminalLauncher {
    static func open(sbxArguments: [String]) throws {
        guard let executable = SbxCLI.executableURL() else {
            throw SbxError.executableNotFound
        }
        let command = ([executable.path] + sbxArguments).map(shellQuote).joined(separator: " ")
        let script = """
            #!/bin/zsh -l
            rm -f "$0"
            clear
            \(command)

            """

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("sbx-app", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(UUID().uuidString).command")
        try script.write(to: file, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)

        NSWorkspace.shared.open(file)
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
