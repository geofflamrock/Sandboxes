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

    var body: some View {
        Group {
            switch argument.input {
            case .toggle:
                Toggle(isOn: toggleBinding) { label }
            case .choice:
                Picker(selection: choiceBinding) {
                    if (argument.defaultValue ?? "").isEmpty {
                        Text(argument.isRequired ? "Not Chosen" : "None").tag("")
                        Divider()
                    }
                    ForEach(argument.choices, id: \.self) { choice in
                        Text(choice == argument.defaultValue ? "\(choice) (Default)" : choice).tag(choice)
                    }
                } label: {
                    label
                }
            case .text:
                TextField(text: textBinding, prompt: Text(prompt)) { label }
            }
        }
        .disabled(isFixed)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(argument.name)
                .font(.body.monospaced())
            ForEach(details, id: \.self) { detail in
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
