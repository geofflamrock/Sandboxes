import SwiftUI

/// A kit in the New Sandbox window and the arguments it declares, with an
/// input for each: a toggle, a menu of its choices, or a text field.
///
/// A mixin kit always has a section, headed by the kit with a button to
/// remove it. The workload's section only appears while its arguments are
/// read and when it has some, since the agent is already shown above it.
struct KitArgumentsSection: View {
    let kit: String
    let result: KitInspector.Result?
    @Binding var values: [String: String]
    let onRetry: () -> Void
    /// Removes a mixin kit. The workload has none.
    var onRemove: (() -> Void)?
    /// The environment file's arguments, which a value can use. Empty for a sandbox.
    var environmentArguments: [KitArgument] = []

    var body: some View {
        if isShown {
            Section {
                content
            } header: {
                header
            } footer: {
                if let footer {
                    Text(footer)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var isShown: Bool {
        guard onRemove == nil else { return true }
        switch result {
        case .loading, .failed: return true
        case let .loaded(inspection): return !inspection.arguments.isEmpty
        case nil: return false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch result {
        case .loading, nil:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading the kit’s arguments…")
                    .foregroundStyle(.secondary)
            }
        case let .failed(message):
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(message)
                        .lineLimit(4)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.callout)
                Spacer()
                Button("Try Again", action: onRetry)
            }
        case let .loaded(inspection) where inspection.arguments.isEmpty:
            Text("This kit has no arguments.")
                .foregroundStyle(.secondary)
        case let .loaded(inspection):
            ForEach(inspection.arguments) { argument in
                KitArgumentRow(
                    argument: argument,
                    isFixed: argument.buildArgument != nil && KitSource(reference: kit) == .registry,
                    values: $values,
                    environmentArguments: environmentArguments
                )
            }
        }
    }

    private var footer: String? {
        switch result {
        case .failed:
            "Couldn’t read the kit’s arguments. You can still create the sandbox, and sbx reports any argument it needs."
        case let .loaded(inspection) where !inspection.arguments.isEmpty:
            "Leave an argument empty to use its default. Values are plain text and saved with the sandbox, so store credentials as secrets instead."
        default:
            nil
        }
    }

    private var displayName: String {
        if case let .loaded(inspection) = result, let name = inspection.displayName {
            return name
        }
        return KitArgument.handle(for: kit)
    }

    @ViewBuilder
    private var header: some View {
        if let onRemove {
            let source = KitSource(reference: kit)
            HStack(spacing: 8) {
                Image(systemName: source.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                    Text(source == .local ? (kit as NSString).abbreviatingWithTildeInPath : kit)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(kit)
                }
                Spacer()
                RemoveButton(help: "Remove kit", action: onRemove)
            }
        } else {
            Text("Arguments for “\(displayName)”")
                .help(kit)
        }
    }
}

struct KitArgumentRow: View {
    let argument: KitArgument
    /// A build argument of a published kit was used when it was built, so it can't change.
    let isFixed: Bool
    @Binding var values: [String: String]
    /// An environment file's arguments, which the value can use. Empty for a sandbox.
    var environmentArguments: [KitArgument] = []

    // The label is outside the control, so a fixed argument's control is
    // disabled while its info button still opens.
    var body: some View {
        LabeledContent {
            HStack {
                control
                    .labelsHidden()
                    .accessibilityLabel(argument.name)
                if !environmentArguments.isEmpty {
                    ArgumentMenu(arguments: environmentArguments, help: "Use one of the file's arguments in “\(argument.name)”") { name in
                        // Text can have an argument within it; a switch or a menu takes its whole value from one.
                        let current = argument.input == .text ? (values[argument.name] ?? "") : ""
                        values[argument.name] = current + ArgumentReference.text(for: name)
                    }
                }
            }
            .disabled(isFixed)
        } label: {
            label
        }
    }

    /// Whether the value uses an environment file's argument, which is only
    /// known when a sandbox is created from the file.
    private var usesArgument: Bool {
        values[argument.name].map(ArgumentReference.appears(in:)) ?? false
    }

    @ViewBuilder
    private var control: some View {
        // A switch or a menu can't show an argument, so its reference is shown as text.
        switch usesArgument ? KitArgument.Input.text : argument.input {
        case .toggle:
            Toggle(argument.name, isOn: toggleBinding)
        case .choice:
            Picker(argument.name, selection: choiceBinding) {
                if (argument.defaultValue ?? "").isEmpty {
                    Text(argument.isRequired ? "Not Chosen" : "None").tag("")
                    Divider()
                }
                ForEach(argument.choices, id: \.self) { choice in
                    Text(choice == argument.defaultValue ? "\(choice) (Default)" : choice).tag(choice)
                }
            }
        case .text:
            TextField(argument.name, text: textBinding, prompt: Text(prompt))
        }
    }

    /// The name, with the description behind an info button as System
    /// Settings does, so a long one doesn't stretch the row. A problem with
    /// the value stays in view.
    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(argument.name)
                    .font(.body.monospaced())
                if !details.isEmpty {
                    InfoButton(text: details.joined(separator: "\n\n"))
                }
            }
            if !usesArgument, let problem = argument.problem(with: values[argument.name]),
               values[argument.name]?.isEmpty == false || argument.input != .text {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var details: [String] {
        var details: [String] = []
        if let description = argument.description {
            details.append(description)
        }
        if isFixed {
            details.append("Set when the kit was published.")
        } else if let variable = argument.environmentVariable {
            details.append("Sets \(variable) in the sandbox.")
        }
        return details
    }

    private var prompt: String {
        if let defaultValue = argument.defaultValue, !defaultValue.isEmpty { return defaultValue }
        return argument.isRequired ? "Required" : "Optional"
    }

    /// Stores a value only when it differs from what sbx would use anyway,
    /// so an untouched argument isn't passed. A required one always is.
    private func store(_ value: String) {
        let untouched = argument.input == .toggle ? (argument.defaultValue ?? "false") : (argument.defaultValue ?? "")
        values[argument.name] = value == untouched && !argument.isRequired ? nil : value
    }

    private var textBinding: Binding<String> {
        Binding {
            values[argument.name] ?? ""
        } set: {
            if $0.isEmpty { values[argument.name] = nil } else { values[argument.name] = $0 }
        }
    }

    private var choiceBinding: Binding<String> {
        Binding {
            values[argument.name] ?? argument.defaultValue ?? ""
        } set: {
            store($0)
        }
    }

    private var toggleBinding: Binding<Bool> {
        Binding {
            (values[argument.name] ?? argument.defaultValue) == "true"
        } set: {
            store($0 ? "true" : "false")
        }
    }
}

/// An ⓘ button that shows `text` in a popover, and as a tooltip on hover.
private struct InfoButton: View {
    let text: String
    @State private var isShowing = false

    var body: some View {
        Button("More Information", systemImage: "info.circle") {
            isShowing.toggle()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(text)
        .popover(isPresented: $isShowing, arrowEdge: .trailing) {
            Text(text)
                .frame(width: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding()
        }
    }
}
