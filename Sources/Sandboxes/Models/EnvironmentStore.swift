import Foundation
import Observation
import AppKit

/// Environment files: the ones saved in the app's environments folder, one
/// folder each, and ones opened from elsewhere.
@MainActor
@Observable
final class EnvironmentStore {
    /// The environments folder, when it's been moved from the default in Settings.
    nonisolated static let directoryKey = "environmentsDirectory"
    private static let openedFilesKey = "openedEnvironmentFiles"
    /// Sandbox names and the files the app created them from. sbx doesn't
    /// record which file a sandbox came from.
    private static let sandboxLinksKey = "environmentSandboxLinks"
    /// Sandboxes created with `~/.sbxenv.yaml` added, which later `sbx env`
    /// commands for them need to match.
    private static let sandboxesWithDefaultsKey = "environmentSandboxesWithDefaults"
    nonisolated static let fileName = "sbxenv.yaml"

    private(set) var environments: [EnvironmentFile] = []
    private(set) var hasLoaded = false
    var actionError: SandboxStore.ActionError?
    /// Creating a sandbox from a file, shown in a sheet over the main window.
    var run: EnvironmentRun?
    var deletionCandidate: EnvironmentFile?

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `~/Library/Application Support/Sandboxes/Environments`, unless it's
    /// been moved in Settings.
    nonisolated static var directory: URL {
        if let custom = UserDefaults.standard.string(forKey: directoryKey), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return defaultDirectory
    }

    nonisolated static var defaultDirectory: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Sandboxes", isDirectory: true)
            .appendingPathComponent("Environments", isDirectory: true)
    }

    /// Reads the environments folder and the files opened from elsewhere,
    /// most recently changed first.
    func refresh() {
        let fileManager = FileManager.default
        let directory = Self.directory
        var files: [EnvironmentFile] = []
        let folders = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let url = folder.appendingPathComponent(Self.fileName)
            if fileManager.fileExists(atPath: url.path) {
                files.append(.read(url, isInLibrary: true))
            }
        }
        // A file opened from elsewhere that has since been deleted drops off the list.
        let opened = openedFiles.filter { fileManager.fileExists(atPath: $0.path) }
        if opened != openedFiles {
            openedFiles = opened
        }
        let libraryPaths = Set(files.map(\.url.standardizedFileURL.path))
        for url in opened where !libraryPaths.contains(url.standardizedFileURL.path) {
            files.append(.read(url, isInLibrary: false))
        }
        environments = files.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        hasLoaded = true
    }

    /// Writes the New Sandbox window's options to `existing`, or to a new
    /// folder named after the environment. Throws so the window stays open
    /// with what was entered.
    @discardableResult
    func save(_ request: CreateSandboxRequest, to existing: URL?) throws -> URL {
        let fileManager = FileManager.default
        let url: URL
        if let existing {
            url = existing
        } else {
            let folder = Self.directory.appendingPathComponent(request.trimmedName, isDirectory: true)
            guard !fileManager.fileExists(atPath: folder.path) else {
                throw SaveError.exists(request.trimmedName)
            }
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            url = folder.appendingPathComponent(Self.fileName)
        }
        try request.environmentFileText.write(to: url, atomically: true, encoding: .utf8)
        refresh()
        return url
    }

    enum SaveError: LocalizedError {
        case exists(String)

        var errorDescription: String? {
            switch self {
            case let .exists(name): "There's already an environment file called “\(name)”. Choose another name."
            }
        }
    }

    /// Sets the file's `name:`, which names the sandbox it creates, and moves
    /// an environment in the environments folder to a folder of that name.
    /// Sandboxes already created from it keep their names.
    func rename(_ file: EnvironmentFile, to newName: String) throws {
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = CreateSandboxRequest.nameProblem(newName) {
            throw RenameError(message: problem)
        }
        let fileManager = FileManager.default
        let text = try String(contentsOf: file.url, encoding: .utf8)
        let renamed = try EnvironmentYAML.settingName(newName, in: text)
        var url = file.url
        if file.isInLibrary {
            let folder = file.url.deletingLastPathComponent()
            let destination = folder.deletingLastPathComponent().appendingPathComponent(newName, isDirectory: true)
            if destination.standardizedFileURL != folder.standardizedFileURL {
                // A folder differing only in case is the same one on most Macs.
                if fileManager.fileExists(atPath: destination.path) && destination.path.lowercased() != folder.path.lowercased() {
                    throw SaveError.exists(newName)
                }
                try fileManager.moveItem(at: folder, to: destination)
                url = destination.appendingPathComponent(Self.fileName)
            }
        }
        try renamed.write(to: url, atomically: true, encoding: .utf8)
        // Links to sandboxes created before keep pointing at the file.
        if url != file.url {
            let links = sandboxLinks.mapValues { $0 == file.url.path ? url.path : $0 }
            defaults.set(links, forKey: Self.sandboxLinksKey)
        }
        refresh()
    }

    struct RenameError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Adds a file chosen in an open panel to the list, and returns it.
    @discardableResult
    func open(_ url: URL) -> EnvironmentFile {
        let url = url.standardizedFileURL
        if !url.path.hasPrefix(Self.directory.standardizedFileURL.path + "/") && !openedFiles.contains(url) {
            openedFiles.insert(url, at: 0)
        }
        refresh()
        return environments.first { $0.url.standardizedFileURL == url } ?? .read(url, isInLibrary: false)
    }

    /// Moves an environment in the environments folder to the Trash, folder
    /// and all. A file opened from elsewhere is only taken off the list.
    func delete(_ file: EnvironmentFile) {
        do {
            if file.isInLibrary {
                try FileManager.default.trashItem(at: file.url.deletingLastPathComponent(), resultingItemURL: nil)
            } else {
                openedFiles.removeAll { $0.standardizedFileURL == file.url.standardizedFileURL }
            }
        } catch {
            actionError = .init(title: "Couldn't Delete “\(file.displayName)”", message: error.localizedDescription)
        }
        refresh()
    }

    /// Asks for the sandbox's name and the file's other options, then shows
    /// what applying it changes before creating the sandbox.
    func startCreating(from file: EnvironmentFile) {
        guard file.problem == nil else {
            actionError = .init(title: "Couldn't Read “\(file.displayName)”", message: file.problem ?? "")
            return
        }
        run = EnvironmentRun(file: file)
    }

    /// Runs `sbx env run` in the default terminal, where sbx asks to approve
    /// the plan and then attaches to the agent. Like the create sheet, it adds
    /// the user's defaults when they can be.
    func runInTerminal(_ file: EnvironmentFile) {
        let run = EnvironmentRun(file: file)
        do {
            try TerminalLauncher.open(sbxArguments: run.arguments("run"), in: run.directory)
            recordLink(run.sandboxName, to: file, includingDefaults: run.usesDefaults)
        } catch {
            actionError = .init(title: "Couldn't Open Terminal", message: error.localizedDescription)
        }
    }

    func openInEditor(_ file: EnvironmentFile) {
        NSWorkspace.shared.open(file.url)
    }

    func showInFinder(_ file: EnvironmentFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    /// The sandboxes the app created from `file`, and the one it creates
    /// without another name, whether or not they exist.
    func sandboxNames(for file: EnvironmentFile) -> Set<String> {
        var names = Set(sandboxLinks.filter { $0.value == file.url.path }.keys)
        if let name = file.sandboxName {
            names.insert(name)
        }
        return names
    }

    func recordLink(_ sandbox: String?, to file: EnvironmentFile, includingDefaults: Bool) {
        guard let sandbox else { return }
        var links = sandboxLinks
        links[sandbox] = file.url.path
        defaults.set(links, forKey: Self.sandboxLinksKey)
        var withDefaults = Set(defaults.stringArray(forKey: Self.sandboxesWithDefaultsKey) ?? [])
        if includingDefaults {
            withDefaults.insert(sandbox)
        } else {
            withDefaults.remove(sandbox)
        }
        defaults.set(withDefaults.sorted(), forKey: Self.sandboxesWithDefaultsKey)
    }

    private var sandboxLinks: [String: String] {
        defaults.dictionary(forKey: Self.sandboxLinksKey) as? [String: String] ?? [:]
    }

    private var openedFiles: [URL] {
        get { (defaults.stringArray(forKey: Self.openedFilesKey) ?? []).map { URL(fileURLWithPath: $0) } }
        set { defaults.set(newValue.map(\.path), forKey: Self.openedFilesKey) }
    }
}

/// Creating a sandbox from an environment file: its name and other options, then `sbx env plan` to show what it changes, then
/// `sbx env create --force` once that's approved. sbx asks for approval at a
/// prompt the app can't answer, so `--force` approves this one run.
@MainActor
@Observable
final class EnvironmentRun: Identifiable {
    enum Phase: Equatable {
        case options
        case planning
        case reviewing
        case creating
        case succeeded
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let file: EnvironmentFile
    /// The file as it is now, to show in the sheet.
    let fileText: String?
    /// Starts as the file's `name:`. Another name creates another sandbox from the same file.
    var name: String
    /// Whether to pass `--clone`, when the file doesn't set `workspace.clone` itself.
    var mode: WorkspaceMode = .direct
    /// `~/.sbxenv.yaml`, when there is one.
    let defaults: EnvironmentDefaults?
    /// The defaults file as it is now, to show in the sheet.
    let defaultsText: String?
    /// Whether to add the user's defaults: sbx runs in the file's folder
    /// rather than being given the file, as when it's run there by hand.
    var includesDefaults = true
    var argumentValues: [String: String] = [:]
    private(set) var phase: Phase = .options
    let planOutput = ConsoleOutput()
    let createOutput = ConsoleOutput()
    /// Whether the plan had already been shown when it failed, so Back can go to it.
    private(set) var didPlan = false

    @ObservationIgnored private var task: Task<Void, Never>?

    init(file: EnvironmentFile) {
        self.file = file
        fileText = try? String(contentsOf: file.url, encoding: .utf8)
        name = file.name ?? ""
        defaults = EnvironmentDefaults.read()
        defaultsText = defaults == nil ? nil : try? String(contentsOf: EnvironmentDefaults.url, encoding: .utf8)
        // A required toggle without a default starts off, which has to be passed.
        for argument in file.arguments where argument.input == .toggle && argument.isRequired && argument.defaultValue == nil {
            argumentValues[argument.name] = "false"
        }
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Whether sbx can add defaults to the file at all: run in a folder, it
    /// only reads `sbxenv.yaml`.
    var canAddDefaults: Bool { file.url.lastPathComponent == EnvironmentStore.fileName }

    /// Why the defaults can't be added, when there are some.
    var defaultsUnavailableReason: String? { defaults?.reasonNotToInclude(in: file) }

    var usesDefaults: Bool { includesDefaults && defaults != nil && defaultsUnavailableReason == nil }

    /// The workspace the sandbox mounts: the file's, or else the defaults'.
    var workspace: String? {
        file.workspace ?? (usesDefaults ? defaults?.workspace(for: file) : nil)
    }

    /// Whether to offer clone mode: a workspace is mounted without saying how.
    var offersClone: Bool {
        workspace != nil && !file.setsClone && !(usesDefaults && defaults?.setsClone == true)
    }

    /// The sandbox this creates, when it can be known before sbx creates it.
    var sandboxName: String? {
        if !trimmedName.isEmpty { return trimmedName }
        if let name = file.name, !name.isEmpty { return name }
        return EnvironmentFile.derivedSandboxName(agent: file.agent ?? (usesDefaults ? defaults?.agent : nil), workspace: workspace)
    }

    /// Where sbx runs: the file's folder when the defaults are added.
    var directory: URL? { usesDefaults ? file.projectDirectory : nil }

    /// Why the options entered can't be used yet, if they can't.
    var validationMessage: String? {
        if !trimmedName.isEmpty, let problem = CreateSandboxRequest.nameProblem(trimmedName) {
            return problem
        }
        return file.arguments.lazy.compactMap { $0.problem(with: self.argumentValues[$0.name]) }.first
    }

    /// `--name` when there is one so the sandbox is known, `--clone` when
    /// chosen, the values entered for the file's arguments, and the file,
    /// unless sbx reads it from the folder it runs in.
    static func fileArguments(name: String?, clone: Bool = false, values: [String: String], declared: [KitArgument], path: String?) -> [String] {
        var arguments: [String] = []
        if let name, !name.isEmpty {
            arguments += ["--name", name]
        }
        if clone {
            arguments.append("--clone")
        }
        let declared = Set(declared.map(\.name))
        for (name, value) in values.sorted(by: { $0.key < $1.key }) where declared.contains(name) && !value.isEmpty {
            arguments += ["--env-arg", "\(name)=\(value)"]
        }
        return arguments + (path.map { [$0] } ?? [])
    }

    /// The arguments for `sbx env <command>`, run in `directory`.
    func arguments(_ command: String) -> [String] {
        ["env", command] + Self.fileArguments(
            name: trimmedName,
            clone: offersClone && mode == .clone,
            values: argumentValues,
            declared: file.arguments,
            path: usesDefaults ? nil : file.url.path
        )
    }

    func plan() {
        didPlan = false
        phase = .planning
        stream(arguments("plan"), into: planOutput) { [weak self] in
            self?.didPlan = true
            self?.phase = .reviewing
        }
    }

    func create(onSuccess: @escaping @MainActor () -> Void) {
        phase = .creating
        stream(arguments("create") + ["--force"], into: createOutput) { [weak self] in
            self?.phase = .succeeded
            onSuccess()
        }
    }

    /// Back to the plan from a failed create, or to the options from a failed plan.
    func back() {
        phase = didPlan ? .reviewing : .options
    }

    func cancel() {
        task?.cancel()
    }

    private func stream(_ arguments: [String], into output: ConsoleOutput, onSuccess: @escaping @MainActor () -> Void) {
        output.clear()
        let directory = directory
        if let directory {
            output.append("$ cd \(CreateSandboxRequest.quoteIfNeeded((directory.path as NSString).abbreviatingWithTildeInPath))\n")
        }
        output.append("$ \(Self.commandLine(arguments))\n\n")
        task = Task {
            do {
                let exitCode = try await SbxCLI.stream(arguments, in: directory) { text in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { output.append(text) }
                    }
                }
                if Task.isCancelled {
                    phase = .cancelled
                } else if exitCode == 0 {
                    onSuccess()
                } else {
                    phase = .failed("sbx exited with code \(exitCode).")
                }
            } catch {
                phase = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
        }
    }

    private static func commandLine(_ arguments: [String]) -> String {
        (["sbx"] + arguments).map(CreateSandboxRequest.quoteIfNeeded).joined(separator: " ")
    }
}
