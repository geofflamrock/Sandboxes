import SwiftUI

/// The arguments a kit declares, in the New Sandbox window, with an input
/// for each: a toggle, a menu of its choices, or a text field.
struct KitArgumentsSection: View {
    let kit: String
    let result: KitInspector.Result?
    @Binding var values: [String: String]
    let onRetry: () -> Void

    var body: some View {
        switch result {
        case .loading:
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading the kit’s arguments…")
                        .foregroundStyle(.secondary)
                }
            } header: {
                header(nil)
            }
        case let .failed(message):
            Section {
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
            } header: {
                header(nil)
            } footer: {
                Text("Couldn’t read the kit’s arguments. You can still create the sandbox, and sbx reports any argument it needs.")
                    .foregroundStyle(.secondary)
            }
        case let .loaded(inspection) where !inspection.arguments.isEmpty:
            Section {
                ForEach(inspection.arguments) { argument in
                    KitArgumentRow(
                        argument: argument,
                        isFixed: argument.buildArgument != nil && KitSource(reference: kit) == .registry,
                        values: $values
                    )
                }
            } header: {
                header(inspection.displayName)
            } footer: {
                Text("Leave an argument empty to use its default. Values are plain text and saved with the sandbox, so store credentials as secrets instead.")
                    .foregroundStyle(.secondary)
            }
        case .loaded, nil:
            EmptyView()
        }
    }

    private func header(_ displayName: String?) -> some View {
        Text("Arguments for “\(displayName ?? KitArgument.handle(for: kit))”")
            .help(kit)
    }
}

private struct KitArgumentRow: View {
    let argument: KitArgument
    /// A build argument of a published kit was used when it was built, so it can't change.
    let isFixed: Bool
    @Binding var values: [String: String]

    // The label is outside the control, so a fixed argument's control is
    // disabled while its info button still opens.
    var body: some View {
        LabeledContent {
            control
                .labelsHidden()
                .accessibilityLabel(argument.name)
                .disabled(isFixed)
        } label: {
            label
        }
    }

    @ViewBuilder
    private var control: some View {
        switch argument.input {
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
            if let problem = argument.problem(with: values[argument.name]),
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
