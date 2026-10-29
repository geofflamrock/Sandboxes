import SwiftUI
import AppKit

/// Management › Skills: the skills in sbx's shared store, with ways to add
/// them from a repository, import them from this Mac, update and remove them.
struct SkillsView: View {
    @Environment(SandboxStore.self) private var store
    @Environment(SkillStore.self) private var skills
    @State private var isAdding = false
    @State private var isImporting = false
    @State private var inspected: AgentSkill?
    @State private var removal: AgentSkill?

    var body: some View {
        Form {
            Section {
                if skills.skills.isEmpty {
                    Text(skills.hasLoaded ? "No skills." : "Loading…")
                        .foregroundStyle(.secondary)
                }
                ForEach(skills.skills) { skill in
                    SkillRow(skill: skill) { action in
                        switch action {
                        case .inspect: inspected = skill
                        case .remove: removal = skill
                        }
                    }
                }
            } header: {
                Text("Skills")
            } footer: {
                footer
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Skills")
        .task {
            await skills.refresh()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Home", systemImage: "chevron.backward") {
                    store.selection = .home
                }
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to Home")
            }
            ToolbarItemGroup {
                Button("Update All", systemImage: "arrow.down.circle") {
                    Task { await skills.updateAll() }
                }
                .disabled(skills.isUpdatingAll || !skills.skills.contains(where: \.canUpdate))
                .help("Download the latest versions of skills added from repositories")
                Button("Import", systemImage: "square.and.arrow.down") {
                    isImporting = true
                }
                .help("Copy skills from your agents' skills folders on this Mac")
                Button("Add Skills", systemImage: "plus") {
                    isAdding = true
                }
                .help("Add skills from a Git repository")
            }
        }
        .sheet(isPresented: $isAdding) {
            AddSkillsSheet()
        }
        .sheet(isPresented: $isImporting) {
            ImportSkillsSheet()
        }
        .sheet(item: $inspected) { skill in
            SkillInspector(skill: skill)
        }
        .confirmationDialog(
            "Remove “\(removal?.name ?? "")”?",
            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
            presenting: removal
        ) { skill in
            Button("Remove", role: .destructive) {
                Task { await skills.remove(skill) }
            }
        } message: { _ in
            Text("It's removed from the store and from running sandboxes straight away, even if an agent is using it. This can't be undone.")
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let error = skills.loadError {
            Text("Couldn't list skills: \(error)")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } else {
            Text("Sandboxes share these skills with their agent unless they're created with skills off. A sandbox picks up added skills the next time it starts, and changes to a skill's files straight away.")
                .foregroundStyle(.secondary)
        }
    }
}

/// A skill, with its description, where it came from and a menu of actions.
private struct SkillRow: View {
    enum Action {
        case inspect
        case remove
    }

    let skill: AgentSkill
    let perform: (Action) -> Void
    @Environment(SkillStore.self) private var skills

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.book.closed")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                if let description = skill.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(description)
                }
                if let source {
                    Text(source)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if skills.isBusy(skill) {
                ProgressView()
                    .controlSize(.small)
            } else {
                Menu {
                    actions
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions for “\(skill.name)”")
            }
        }
        .contextMenu {
            actions
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Inspect…") { perform(.inspect) }
        if let folder = skill.folder {
            Button("Open in Finder") { NSWorkspace.shared.open(folder) }
        }
        Divider()
        if skill.canUpdate {
            Button("Update") {
                Task { await skills.update(skill) }
            }
            Divider()
        }
        Button("Remove…", role: .destructive) { perform(.remove) }
    }

    private var source: String? {
        switch skill.source {
        case let .repository(repository): "From \(repository)"
        case .imported: "Imported from this Mac"
        case .unknown: nil
        }
    }
}

/// A skill's details and instructions, read from its folder in the store.
/// It only reads: sbx owns the store, and changes made there reach every
/// sandbox and are lost when the skill is updated.
private struct SkillInspector: View {
    let skill: AgentSkill
    @Environment(\.dismiss) private var dismiss
    @State private var instructions: String?
    @State private var hasLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if let description = skill.description {
                        LabeledContent("Description") {
                            Text(description)
                                .textSelection(.enabled)
                        }
                    }
                    switch skill.source {
                    case let .repository(repository):
                        LabeledContent("Repository") {
                            Text(repository)
                                .textSelection(.enabled)
                        }
                        if let commit = skill.commit {
                            LabeledContent("Commit") {
                                Text(commit)
                                    .font(.callout.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    case .imported:
                        LabeledContent("Source", value: "Imported from this Mac")
                    case .unknown:
                        EmptyView()
                    }
                    if let folder = skill.folder {
                        LabeledContent("Location") {
                            Text((folder.path as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .help(folder.path)
                        }
                    }
                }

                if skill.folder == nil {
                    Section {
                        Text("sbx didn't say where its skills store is, so the skill's instructions can't be shown.")
                            .foregroundStyle(.secondary)
                    }
                } else if hasLoaded {
                    instructionsSection
                } else {
                    Section {
                        Text("Loading…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            // Sheets separate their buttons from the content with a line.
            Divider()

            HStack {
                if let folder = skill.folder {
                    Button("Open in Finder") { NSWorkspace.shared.open(folder) }
                        .help("See the skill's files, including any scripts the agent may run")
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(minWidth: 520, idealWidth: 620, minHeight: 420, idealHeight: 600)
        .navigationTitle(skill.name)
        .task {
            guard let folder = skill.folder else { return }
            instructions = await SkillFile.instructions(inSkillAt: folder)
            hasLoaded = true
        }
    }

    private var instructionsSection: some View {
        Section {
            if let instructions, !instructions.isEmpty {
                Text(Self.styled(instructions))
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(instructions == nil ? "The skill has no SKILL.md, or it couldn't be read." : "SKILL.md has no instructions after its front matter.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Instructions")
        } footer: {
            Text("From SKILL.md, which tells the agent when and how to use the skill. Sandboxes get every file in the skill's folder.")
                .foregroundStyle(.secondary)
        }
    }

    /// Bold, italics, code and links styled, with headings and lists left as
    /// written, since only inline Markdown is interpreted.
    private static func styled(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}

/// Adds skills from a Git repository with `sbx skills add`.
private struct AddSkillsSheet: View {
    @Environment(SkillStore.self) private var skills
    @Environment(\.dismiss) private var dismiss
    @State private var draft = SkillDraft()
    @State private var isSaving = false
    @State private var error: String?
    /// Set when a skill is already installed, to confirm replacing it.
    @State private var confirmsReplacing = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Repository", text: $draft.repository, prompt: Text("anthropics/skills"))
                    TextField("Skills", text: $draft.skills, prompt: Text("All"))
                } footer: {
                    Text("A Git URL, or a GitHub owner/repository. Enter skill names separated by commas to add only those; otherwise every skill in the repository is added.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text(draft.commandLine)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    Text("Command")
                } footer: {
                    if let error {
                        Text(error)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isSaving)

            // Sheets separate their buttons from the content with a line.
            Divider()

            HStack {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    Task { await add(replacing: false) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(isSaving || draft.trimmedRepository.isEmpty)
                .help(draft.trimmedRepository.isEmpty ? "Enter a repository." : "")
            }
            .padding(20)
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 320, idealHeight: 360)
        .navigationTitle("Add Skills")
        .confirmationDialog(
            "Replace Installed Skills?",
            isPresented: $confirmsReplacing
        ) {
            Button("Replace", role: .destructive) {
                Task { await add(replacing: true) }
            }
        } message: {
            Text("The repository has skills with the same names as ones already in the store. Replacing them changes them in every sandbox that uses them.")
        }
    }

    private func add(replacing: Bool) async {
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            try await skills.add(draft, replacing: replacing)
            dismiss()
        } catch is SkillStore.NeedsReplacing {
            confirmsReplacing = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Imports skills from agents' folders on this Mac, after showing what
/// `sbx skills import --dry-run` says it would copy and replace.
private struct ImportSkillsSheet: View {
    @Environment(SkillStore.self) private var skills
    @Environment(\.dismiss) private var dismiss
    @State private var preview: String?
    /// Whether sbx found anything to copy.
    @State private var hasSkills = false
    @State private var isImporting = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if let preview {
                        Text(preview)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if error == nil {
                        Text("Looking for skills…")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Skills to Import")
                } footer: {
                    if let error {
                        Text(error)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    } else {
                        Text("sbx looks in ~/.agents/skills, ~/.claude/skills, ~/.config/opencode/skills, ~/.copilot/skills, ~/.cursor/skills and ~/.factory/skills, and uses the first copy of each skill it finds. A skill already in the store is replaced completely.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            // Sheets separate their buttons from the content with a line.
            Divider()

            HStack {
                if isImporting {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    Task { await importSkills() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(isImporting || !hasSkills)
            }
            .padding(20)
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 360, idealHeight: 440)
        .navigationTitle("Import Skills")
        .task {
            do {
                let output = try await skills.previewImport()
                let summary = Self.summary(of: output)
                hasSkills = summary != nil
                preview = summary ?? "There are no skills to import."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// What would change, without sbx's notes about folders that don't exist.
    private static func summary(of output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("No skills directory found") }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func importSkills() async {
        isImporting = true
        error = nil
        defer { isImporting = false }
        do {
            try await skills.importSkills()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
