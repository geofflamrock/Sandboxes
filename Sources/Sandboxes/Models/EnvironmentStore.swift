import Foundation
import Observation

/// The sandbox environments saved in the environments folder, one folder
/// each holding an `sbxenv.yaml` file.
@MainActor
@Observable
final class EnvironmentStore {
    nonisolated static let directoryKey = "environmentsDirectory"
    nonisolated static let fileName = "sbxenv.yaml"

    /// Outside any folder likely to be mounted into a sandbox, as sbx
    /// recommends for environment files, and somewhere macOS doesn't ask
    /// permission to read, unlike Documents or Desktop.
    nonisolated static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/sandboxes/environments", directoryHint: .isDirectory)

    private(set) var environments: [SandboxEnvironment] = []

    /// The folder set in Settings, or the default one.
    nonisolated static var directory: URL {
        let custom = UserDefaults.standard.string(forKey: directoryKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !custom.isEmpty else { return defaultDirectory }
        return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
    }

    func reload() async {
        let directory = Self.directory
        environments = await Task.detached { Self.load(from: directory) }.value
    }

    /// Why `name` can't be used for a new environment, if it can't.
    func validationMessage(forName name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return "Enter a name for the environment."
        }
        if name.hasPrefix(".") || name.contains("/") || name.contains(":") {
            return "Environment names can't start with a period or contain “/” or “:”."
        }
        if FileManager.default.fileExists(atPath: Self.directory.appending(path: name).path) {
            return "There's already an environment named “\(name)”."
        }
        return nil
    }

    /// Writes the create sheet's setup as a new environment and returns its file.
    @discardableResult
    func save(_ request: CreateSandboxRequest, as name: String) throws -> URL {
        let folder = Self.directory.appending(path: name.trimmingCharacters(in: .whitespacesAndNewlines), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: Self.fileName)
        try SandboxEnvironment.yaml(for: request).write(to: file, atomically: true, encoding: .utf8)
        Task { await reload() }
        return file
    }

    /// Moves the environment's folder to the Trash.
    func trash(_ environment: SandboxEnvironment) throws {
        try FileManager.default.trashItem(at: environment.fileURL.deletingLastPathComponent(), resultingItemURL: nil)
        environments.removeAll { $0.id == environment.id }
    }

    /// Creates the folder if it doesn't exist yet, so it can be shown in Finder.
    static func createDirectory() throws -> URL {
        let directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated private static func load(from directory: URL) -> [SandboxEnvironment] {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }
        return folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            // sbx prefers sbxenv.yaml when a folder has both.
            .compactMap { folder in
                [fileName, "." + fileName]
                    .map { folder.appending(path: $0) }
                    .first { fileManager.fileExists(atPath: $0.path) }
            }
            .map(SandboxEnvironment.init(fileURL:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
