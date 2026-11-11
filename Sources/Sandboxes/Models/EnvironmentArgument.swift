import Foundation

/// `${{ env.args.NAME }}`, which uses one of an environment file's arguments
/// in a value. sbx accepts it anywhere a YAML value can appear, apart from
/// inside the `args` block itself, and writes `$${{ … }}` literally
/// (https://docs.docker.com/ai/sandboxes/configuration/environment-files/#parameterize-an-environment).
enum ArgumentReference {
    static var pattern: Regex<(Substring, Substring)> { #/\$\{\{\s*env\.args\.([A-Za-z_][A-Za-z0-9_\-]*)\s*\}\}/# }

    static func text(for name: String) -> String {
        "${{ env.args.\(name) }}"
    }

    /// The names of the arguments `text` uses.
    static func names(in text: String) -> [String] {
        references(in: text).map(\.name)
    }

    static func appears(in text: String) -> Bool {
        !references(in: text).isEmpty
    }

    /// The argument `text` is, when it's a reference and nothing else, as a
    /// number or a boolean has to be.
    static func name(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let found = references(in: trimmed)
        guard found.count == 1, found[0].range == trimmed.startIndex..<trimmed.endIndex else { return nil }
        return found[0].name
    }

    /// Whether every `${{ … }}` in `text` is an argument, which the New
    /// Sandbox window keeps as it is. Others, such as `${{ env.projectDir }}`
    /// or an escaped `$${{ … }}`, aren't.
    static func isEditable(_ text: String) -> Bool {
        !replacing(in: text) { _ in "" }.contains("${{")
    }

    /// `text` with every use of `old` changed to use `new`.
    static func renaming(_ old: String, to new: String, in text: String) -> String {
        replacing(in: text) { $0 == old ? Self.text(for: new) : nil }
    }

    /// Where each argument is used in `document`, as the dotted paths of the
    /// fields that use it, such as `env.API_ENDPOINT`. The `args` block is
    /// left out: sbx doesn't expand references there.
    static func usages(in document: YAMLValue) -> [String: [String]] {
        var usages: [String: [String]] = [:]
        func visit(_ value: YAMLValue, path: String) {
            switch value {
            case let .scalar(text), let .plain(text):
                for name in names(in: text) where !(usages[name]?.contains(path) ?? false) {
                    usages[name, default: []].append(path)
                }
            case let .list(items):
                for item in items {
                    visit(item, path: path)
                }
            case let .map(entries):
                for entry in entries where !(path.isEmpty && entry.key == "args") {
                    visit(entry.value, path: path.isEmpty ? entry.key : "\(path).\(entry.key)")
                }
            }
        }
        visit(document, path: "")
        return usages
    }

    /// The references in `text`, leaving out escaped ones.
    private static func references(in text: String) -> [(range: Range<String.Index>, name: String)] {
        text.matches(of: pattern).compactMap { match in
            let start = match.range.lowerBound
            if start > text.startIndex && text[text.index(before: start)] == "$" { return nil }
            return (match.range, String(match.output.1))
        }
    }

    /// `text` with each reference replaced by what `replacement` gives for its
    /// name, or left as it is when that's nil.
    private static func replacing(in text: String, with replacement: (String) -> String?) -> String {
        var result = ""
        var cursor = text.startIndex
        for reference in references(in: text) {
            result += text[cursor..<reference.range.lowerBound]
            result += replacement(reference.name) ?? String(text[reference.range])
            cursor = reference.range.upperBound
        }
        result += text[cursor...]
        return result
    }
}

extension KitArgument {
    /// Why sbx won't accept this under an environment file's `args:`, if it
    /// won't. Each argument has exactly one of a default and `required: true`,
    /// and can't have both choices and a pattern.
    var declarationProblem: String? {
        if name.isEmpty {
            return "Enter a name for each argument."
        }
        if name.wholeMatch(of: #/[A-Za-z_][A-Za-z0-9_\-]*/#) == nil {
            return "“\(name)” isn't a valid argument name. Names start with a letter or underscore, and contain only letters, numbers, underscores and hyphens."
        }
        if isRequired && defaultValue != nil {
            return "“\(name)” can't be required and have a default."
        }
        if !isRequired && defaultValue == nil {
            return "Give “\(name)” a default, or make it required."
        }
        if !choices.isEmpty && pattern != nil {
            return "“\(name)” can't have both choices and a pattern."
        }
        if let pattern, (try? NSRegularExpression(pattern: pattern)) == nil {
            return "The pattern for “\(name)” isn't a valid regular expression."
        }
        if let defaultValue {
            if !choices.isEmpty && !choices.contains(defaultValue) {
                return "The default for “\(name)” must be one of its choices."
            }
            if let problem = problem(with: defaultValue) {
                return problem
            }
        }
        return nil
    }

    /// The declaration as `args:` writes it, in the order the docs use.
    var declarationDocument: YAMLValue {
        var fields: [YAMLEntry] = []
        if isRequired {
            fields.append(YAMLEntry(key: "required", value: .plain("true")))
        } else {
            fields.append(YAMLEntry(key: "default", value: .scalar(defaultValue ?? "")))
        }
        if let description, !description.isEmpty {
            fields.append(YAMLEntry(key: "description", value: .scalar(description)))
        }
        if !choices.isEmpty {
            fields.append(YAMLEntry(key: "enum", value: .list(choices.map(YAMLValue.scalar))))
        }
        if let pattern {
            fields.append(YAMLEntry(key: "pattern", value: .scalar(pattern)))
        }
        return .map(fields)
    }

    /// The fields an `args:` declaration can have, which the New Sandbox window shows.
    static let declarationFields: Set<String> = ["default", "required", "description", "enum", "pattern"]

    /// An argument as an environment file's `args:` declares it.
    init(name: String, declaration: YAMLValue) {
        self.init(
            name: name,
            description: declaration["description"]?.string,
            defaultValue: declaration["default"]?.string,
            isRequired: declaration["required"]?.bool ?? false,
            choices: (declaration["enum"]?.list ?? []).compactMap(\.string),
            pattern: declaration["pattern"]?.string
        )
    }
}
