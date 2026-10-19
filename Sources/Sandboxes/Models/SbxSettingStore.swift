import Foundation
import Observation

/// The settings of Docker Sandboxes, from `sbx settings`, and the daemon
/// restarts some of them need.
@MainActor
@Observable
final class SbxSettingStore {
    /// For the dialog that offers to restart the daemon.
    struct RestartPrompt: Identifiable {
        let id = UUID()
        /// The setting just changed that only applies everywhere once the
        /// daemon restarts, or nil when the user asked to restart it.
        let key: String?
    }

    struct Group: Identifiable {
        /// Such as "kit" or "proxy".
        let name: String
        let settings: [SbxSetting]

        var id: String { name }
    }

    private(set) var settings: [SbxSetting] = []
    private(set) var hasLoaded = false
    private(set) var loadError: String?
    /// Settings with a change in flight.
    private(set) var busyKeys: Set<String> = []
    /// Settings changed since the daemon last restarted that need a restart.
    private(set) var keysAwaitingRestart: Set<String> = []
    var restartPrompt: RestartPrompt?
    /// The `sbx daemon restart` run shown in a sheet on the Settings page.
    var restart: SbxCommandRun?
    var actionError: SandboxStore.ActionError?

    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var refreshAgain = false

    /// Settings grouped by the start of their keys, such as "kit" or "proxy".
    var groups: [Group] {
        Dictionary(grouping: settings, by: \.group)
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { Group(name: $0.key, settings: $0.value) }
    }

    func setting(_ key: String) -> SbxSetting? {
        settings.first { $0.key == key }
    }

    func isBusy(_ setting: SbxSetting) -> Bool {
        busyKeys.contains(setting.key)
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
            let latest = try await SbxSetting.fetch()
            if latest != settings {
                settings = latest
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        hasLoaded = true
    }

    /// Reads one setting again with `sbx settings get`, whose value isn't
    /// shortened, and updates the list with it.
    @discardableResult
    func reload(_ setting: SbxSetting) async -> SbxSetting? {
        guard let latest = try? await setting.fetchLatest() else { return nil }
        if let index = settings.firstIndex(where: { $0.key == latest.key }), settings[index] != latest {
            settings[index] = latest
        }
        return latest
    }

    /// Sets an override, then offers to restart the daemon if the setting
    /// needs it. Throws so the editor stays open with what was entered.
    func set(_ setting: SbxSetting, to value: String) async throws {
        try await change(setting, arguments: setting.setArguments(value))
    }

    /// Sets a boolean straight from its switch, reporting failures with
    /// `actionError`.
    func set(_ setting: SbxSetting, to value: Bool) async {
        do {
            try await set(setting, to: value ? "true" : "false")
        } catch {
            actionError = SandboxStore.ActionError(title: "Couldn't Change “\(setting.key)”", message: error.localizedDescription)
        }
    }

    /// Removes the override, so the setting goes back to its environment
    /// variable or default.
    func unset(_ setting: SbxSetting) async throws {
        try await change(setting, arguments: setting.unsetArguments)
    }

    func reset(_ setting: SbxSetting) async {
        do {
            try await unset(setting)
        } catch {
            actionError = SandboxStore.ActionError(title: "Couldn't Reset “\(setting.key)”", message: error.localizedDescription)
        }
    }

    private func change(_ setting: SbxSetting, arguments: [String]) async throws {
        busyKeys.insert(setting.key)
        defer { busyKeys.remove(setting.key) }
        let output = try await SbxCLI.runChecked(arguments)
        await reload(setting)
        // sbx warns "this setting takes effect only after a daemon restart".
        if setting.requiresRestart || output.localizedCaseInsensitiveContains("daemon restart") {
            keysAwaitingRestart.insert(setting.key)
            restartPrompt = RestartPrompt(key: setting.key)
        }
    }

    /// Runs `sbx daemon restart` in a sheet, then calls `onSuccess` so the
    /// sandboxes can be reloaded.
    func restartDaemon(onSuccess: @escaping @MainActor () -> Void) {
        let run = SbxCommandRun(kind: .restartDaemon)
        run.start { [weak self] in
            self?.keysAwaitingRestart.removeAll()
            Task { await self?.refresh() }
            onSuccess()
        }
        restart = run
    }
}
