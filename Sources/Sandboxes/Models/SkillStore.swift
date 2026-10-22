import Foundation
import Observation

/// The skills in sbx's shared store, which every sandbox's agent can use
/// unless it's created with skills off.
@MainActor
@Observable
final class SkillStore {
    /// Thrown by `add` when sbx won't replace an installed skill without
    /// `--force`, so the Add Skills sheet can ask first.
    struct NeedsReplacing: LocalizedError {
        let output: String
        var errorDescription: String? { output }
    }

    private(set) var skills: [AgentSkill] = []
    private(set) var hasLoaded = false
    private(set) var loadError: String?
    /// Skills with an action in flight.
    private(set) var busyNames: Set<String> = []
    private(set) var isUpdatingAll = false
    var actionError: SandboxStore.ActionError?

    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var refreshAgain = false

    func isBusy(_ skill: AgentSkill) -> Bool {
        (isUpdatingAll && skill.canUpdate) || busyNames.contains(skill.name)
    }

    /// Reloads the list. Calls made while a reload is in flight queue one
    /// more reload, so a change just made always shows.
    func refresh() async {
        if isRefreshing {
            refreshAgain = true
            return
        }
        isRefreshing = true
        repeat {
            refreshAgain = false
            await load()
        } while refreshAgain
        isRefreshing = false
    }

    private func load() async {
        do {
            let latest = try await AgentSkill.fetch()
            if latest != skills {
                skills = latest
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        hasLoaded = true
    }

    /// Adds skills from a repository. Throws so the Add Skills sheet stays
    /// open with the error, or `NeedsReplacing` when one is already installed.
    func add(_ draft: SkillDraft, replacing: Bool) async throws {
        let arguments = draft.addArguments(replacing: replacing)
        let result = try await SbxCLI.run(arguments)
        guard result.succeeded else {
            // Without a terminal, sbx asks for --force rather than prompting.
            if !replacing && result.output.contains("--force") {
                throw NeedsReplacing(output: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            throw SbxError.commandFailed(arguments: arguments, exitCode: result.exitCode, output: result.output)
        }
        await refresh()
    }

    /// What `sbx skills import` would copy and replace, as sbx describes it.
    func previewImport() async throws -> String {
        try await SbxCLI.runChecked(AgentSkill.importPreviewArguments)
    }

    /// Imports skills from the agents' folders on this Mac, replacing ones
    /// already in the store. Throws so the Import Skills sheet shows the error.
    func importSkills() async throws {
        try await SbxCLI.runChecked(AgentSkill.importArguments)
        await refresh()
    }

    func update(_ skill: AgentSkill) async {
        await perform(on: skill) {
            try await SbxCLI.runChecked(skill.updateArguments)
        } failure: { "Couldn't Update “\(skill.name)”" }
    }

    func updateAll() async {
        isUpdatingAll = true
        do {
            try await SbxCLI.runChecked(AgentSkill.updateAllArguments)
        } catch {
            actionError = SandboxStore.ActionError(title: "Couldn't Update Skills", message: error.localizedDescription)
        }
        isUpdatingAll = false
        await refresh()
    }

    func remove(_ skill: AgentSkill) async {
        await perform(on: skill) {
            try await SbxCLI.runChecked(skill.removeArguments)
        } failure: { "Couldn't Remove “\(skill.name)”" }
    }

    private func perform(on skill: AgentSkill, _ action: () async throws -> Void, failure title: () -> String) async {
        busyNames.insert(skill.name)
        do {
            try await action()
        } catch {
            actionError = SandboxStore.ActionError(title: title(), message: error.localizedDescription)
        }
        busyNames.remove(skill.name)
        await refresh()
    }
}
