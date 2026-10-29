import SwiftUI

/// The New Sandbox window's Arguments section for an environment file: what
/// it declares under `args:`, where each is used, and a sheet to add or edit one.
struct EnvironmentArgumentsSection: View {
    @Binding var request: CreateSandboxRequest
    @State private var draft: EnvironmentArgumentDraft?

    var body: some View {
        let usages = request.argumentUsages
        Section {
            ForEach(request.environmentArguments) { argument in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(argument.name)
                            .font(.body.monospaced())
                        Text(Self.summary(of: argument, usedIn: usages[argument.name] ?? []))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button("Edit…") { draft = EnvironmentArgumentDraft(argument) }
                    RemoveButton(help: "Remove argument") {
                        request.environmentArguments.removeAll { $0.name == argument.name }
                    }
                }
            }
            HStack {
                Button("Add Argument…", systemImage: "plus") { draft = EnvironmentArgumentDraft() }
                Spacer()
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Arguments")
        } footer: {
            Text("Values given each time a sandbox is created from the file, or else their defaults. Use one in an option with the { } menu next to it, or type \(ArgumentReference.text(for: "NAME")) in a text field.")
                .foregroundStyle(.secondary)
        }
        .sheet(item: $draft) { draft in
            EnvironmentArgumentEditor(draft: draft, others: request.environmentArguments) { argument in
                request.saveArgument(argument, replacing: draft.originalName)
            }
        }
    }

    private static func summary(of argument: KitArgument, usedIn paths: [String]) -> String {
        var parts: [String] = []
        if argument.isRequired {
            parts.append("Required")
        } else if let defaultValue = argument.defaultValue, !defaultValue.isEmpty {
            parts.append("Default “\(defaultValue)”")
        } else {
            parts.append("Empty by default")
        }
        if !argument.choices.isEmpty {
            parts.append(argument.choices.joined(separator: ", "))
        } else if let pattern = argument.pattern {
            parts.append("Matches \(pattern)")
        }
        parts.append(paths.isEmpty ? "Not used yet" : "Used in \(paths.formatted(.list(type: .and)))")
        return parts.joined(separator: " · ")
    }
}

/// An argument as the Add Argument sheet edits it.
struct EnvironmentArgumentDraft: Identifiable {
    enum Value: CaseIterable, Identifiable {
        case optional
        case required

        var id: Self { self }

        var title: String {
            switch self {
            case .optional: "Has a Default"
            case .required: "Required"
            }
        }
    }

    enum Accepts: CaseIterable, Identifiable {
        case anything
        case choices
        case pattern

        var id: Self { self }

        var title: String {
            switch self {
            case .anything: "Any Text"
            case .choices: "Choices"
            case .pattern: "Pattern"
            }
        }
    }

    let id = UUID()
    /// The argument's name before it was edited, or nil for a new one.
    let originalName: String?
    var name = ""
    var description = ""
    var value = Value.optional
    var defaultValue = ""
    var accepts = Accepts.anything
    /// One per line.
    var choices = ""
    var pattern = ""

    init(_ argument: KitArgument? = nil) {
        originalName = argument?.name
        guard let argument else { return }
        name = argument.name
        description = argument.description ?? ""
        value = argument.isRequired ? .required : .optional
        defaultValue = argument.defaultValue ?? ""
        if !argument.choices.isEmpty {
            accepts = .choices
            choices = argument.choices.joined(separator: "\n")
        } else if let pattern = argument.pattern {
            accepts = .pattern
            self.pattern = pattern
        }
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var argument: KitArgument {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = pattern.trimmingCharacters(in: .whitespaces)
        return KitArgument(
            name: trimmedName,
            description: description.isEmpty ? nil : description,
            defaultValue: value == .optional ? defaultValue : nil,
            isRequired: value == .required,
            choices: accepts == .choices
                ? choices.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : [],
            pattern: accepts == .pattern && !pattern.isEmpty ? pattern : nil
        )
    }

    /// Why the argument can't be saved, if it can't.
    func problem(among others: [KitArgument]) -> String? {
        let argument = argument
        if others.contains(where: { $0.name == argument.name && $0.name != originalName }) {
            return "There's already an argument called “\(argument.name)”."
        }
        if accepts == .choices && argument.choices.isEmpty {
            return "Enter at least one choice."
        }
        if accepts == .pattern && argument.pattern == nil {
            return "Enter a pattern."
        }
        return argument.declarationProblem
    }
}

private struct EnvironmentArgumentEditor: View {
    @State private var draft: EnvironmentArgumentDraft
    let others: [KitArgument]
    let onSave: (KitArgument) -> Void
    @Environment(\.dismiss) private var dismiss

    init(draft: EnvironmentArgumentDraft, others: [KitArgument], onSave: @escaping (KitArgument) -> Void) {
        _draft = State(initialValue: draft)
        self.others = others
        self.onSave = onSave
    }

    private var problem: String? { draft.problem(among: others) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("channel"))
                        .font(.body.monospaced())
                    TextField("Description", text: $draft.description, prompt: Text("Optional"))
                } footer: {
                    Text("Used in the file as \(ArgumentReference.text(for: draft.trimmedName.isEmpty ? "NAME" : draft.trimmedName)). The description is shown when a sandbox is created from it.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Value", selection: $draft.value) {
                        ForEach(EnvironmentArgumentDraft.Value.allCases) { value in
                            Text(value.title).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    if draft.value == .optional {
                        TextField("Default", text: $draft.defaultValue, prompt: Text("Empty"))
                            .font(.body.monospaced())
                    }
                } footer: {
                    Text(draft.value == .required
                        ? "A sandbox can only be created from the file once it's given a value."
                        : "Used when a sandbox is created from the file without a value for it.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Accepts", selection: $draft.accepts) {
                        ForEach(EnvironmentArgumentDraft.Accepts.allCases) { accepts in
                            Text(accepts.title).tag(accepts)
                        }
                    }
                    .pickerStyle(.segmented)
                    switch draft.accepts {
                    case .anything:
                        EmptyView()
                    case .choices:
                        TextEditor(text: $draft.choices)
                            .font(.body.monospaced())
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 72)
                            .overlay(alignment: .topLeading) {
                                if draft.choices.isEmpty {
                                    Text("stable\nbeta")
                                        .font(.body.monospaced())
                                        .foregroundStyle(.tertiary)
                                        .padding(.leading, 5)
                                        .allowsHitTesting(false)
                                }
                            }
                            .accessibilityLabel("Choices")
                    case .pattern:
                        TextField("Pattern", text: $draft.pattern, prompt: Text("[1-9][0-9]*"))
                            .font(.body.monospaced())
                    }
                } footer: {
                    if let problem, !draft.trimmedName.isEmpty {
                        Text(problem)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    } else {
                        Text(acceptsFooter)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            // Sheets separate their buttons from the content with a line.
            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.originalName == nil ? "Add" : "Save") {
                    onSave(draft.argument)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(problem != nil)
                .help(problem ?? "")
            }
            .padding(20)
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 480, idealHeight: 540)
        .navigationTitle(draft.originalName == nil ? "Add Argument" : "Edit Argument")
    }

    private var acceptsFooter: String {
        switch draft.accepts {
        case .anything: "Any value is accepted."
        case .choices: "One choice per line. Choices of just true and false are shown as a switch."
        case .pattern: "A regular expression the whole value must match, as Go's RE2 reads it."
        }
    }
}

/// A menu of an environment file's arguments, for using one in an option.
struct ArgumentMenu: View {
    let arguments: [KitArgument]
    /// The argument the option uses already, which is checked.
    var selection: String?
    var help = "Use one of the file's arguments"
    let onSelect: (String) -> Void
    /// Goes back to setting the option itself, for one that uses an argument.
    var onClear: (() -> Void)?

    var body: some View {
        Menu {
            Section("Arguments") {
                ForEach(arguments) { argument in
                    Toggle(argument.name, isOn: Binding {
                        argument.name == selection
                    } set: { _ in
                        onSelect(argument.name)
                    })
                }
            }
            if let onClear {
                Divider()
                Button("Don't Use an Argument", action: onClear)
            }
        } label: {
            Label("Arguments", systemImage: "curlybraces")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }
}

/// An option picked from a menu or a switch, whose value can come from one
/// of an environment file's arguments instead. Using one shows the reference
/// in place of the control.
struct ArgumentControl<Control: View>: View {
    let title: String
    @Binding var argument: String?
    /// Empty when arguments can't be used, such as for a sandbox.
    let arguments: [KitArgument]
    let control: () -> Control

    init(_ title: String, argument: Binding<String?>, arguments: [KitArgument], @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        _argument = argument
        self.arguments = arguments
        self.control = control
    }

    var body: some View {
        if let name = argument {
            LabeledContent(title) {
                HStack {
                    Text(ArgumentReference.text(for: name))
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    ArgumentMenu(
                        arguments: arguments,
                        selection: name,
                        help: "Choose the argument “\(title)” comes from",
                        onSelect: { argument = $0 },
                        onClear: { argument = nil }
                    )
                }
            }
        } else if arguments.isEmpty {
            control()
        } else {
            LabeledContent(title) {
                HStack {
                    control()
                        .labelsHidden()
                    ArgumentMenu(
                        arguments: arguments,
                        help: "Use one of the file's arguments for “\(title)”",
                        onSelect: { argument = $0 }
                    )
                }
            }
        }
    }
}
