import Foundation

/// A value in an environment file. Mappings keep their keys in order, so a
/// file reads back the way it was written.
enum YAMLValue: Equatable {
    case scalar(String)
    /// A scalar written without quotes, such as a number or a boolean. Reading
    /// a file only produces `.scalar`.
    case plain(String)
    case list([YAMLValue])
    case map([YAMLEntry])

    var string: String? {
        switch self {
        case let .scalar(value), let .plain(value): value
        case .list, .map: nil
        }
    }

    var list: [YAMLValue]? {
        if case let .list(items) = self { return items }
        return nil
    }

    var map: [YAMLEntry]? {
        if case let .map(entries) = self { return entries }
        return nil
    }

    subscript(key: String) -> YAMLValue? {
        map?.first { $0.key == key }?.value
    }

    var bool: Bool? {
        switch string?.lowercased() {
        case "true"?: true
        case "false"?: false
        default: nil
        }
    }
}

struct YAMLEntry: Equatable {
    let key: String
    let value: YAMLValue
}

/// Reads and writes the YAML in `sbxenv.yaml` files without a third-party
/// parser. It reads block mappings and lists, quoted and plain scalars,
/// comments, empty and simple flow collections, and `|` and `>` blocks,
/// which covers environment files as the docs write them. Anything else
/// fails with the line it's on, and the file can still be opened in an editor.
enum EnvironmentYAML {
    struct ParseError: LocalizedError {
        let line: Int
        let message: String

        var errorDescription: String? { "Line \(line): \(message)" }
    }

    // MARK: Reading

    static func parse(_ text: String) throws -> YAMLValue {
        var parser = Parser(lines: lines(in: text))
        guard !parser.isAtEnd else { return .map([]) }
        let value = try parser.parseBlock(indent: parser.current.indent)
        if !parser.isAtEnd {
            throw ParseError(line: parser.current.number, message: "Unexpected indentation.")
        }
        return value
    }

    fileprivate struct Line {
        let number: Int
        /// -1 for a line with nothing but a comment or spaces.
        let indent: Int
        let text: String
        /// The line as written, for `|` and `>` blocks, which keep their spacing.
        let raw: String

        var isBlank: Bool { indent < 0 }
        var isListItem: Bool { text == "-" || text.hasPrefix("- ") }
    }

    private static func lines(in text: String) -> [Line] {
        text.components(separatedBy: .newlines).enumerated().map { offset, raw in
            let indent = raw.prefix { $0 == " " }.count
            let content = stripComment(String(raw.dropFirst(indent))).trimmingCharacters(in: .whitespaces)
            let isBlank = content.isEmpty || content == "---" || content == "..."
            return Line(number: offset + 1, indent: isBlank ? -1 : indent, text: isBlank ? "" : content, raw: raw)
        }
    }

    /// Removes a `#` comment that isn't inside quotes. YAML only starts a
    /// comment at the start of a line or after a space.
    private static func stripComment(_ text: String) -> String {
        let characters = Array(text)
        var quote: Character?
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if let open = quote {
                if character == "\\" && open == "\"" {
                    index += 1
                } else if character == open {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" && (index == 0 || characters[index - 1].isWhitespace) {
                return String(characters[..<index])
            }
            index += 1
        }
        return text
    }

    fileprivate struct Parser {
        let lines: [Line]
        var position = 0

        init(lines: [Line]) {
            self.lines = lines
            skipBlank()
        }

        var isAtEnd: Bool { position >= lines.count }
        var current: Line { lines[position] }

        mutating func skipBlank() {
            while position < lines.count && lines[position].isBlank {
                position += 1
            }
        }

        mutating func parseBlock(indent: Int) throws -> YAMLValue {
            if current.isListItem {
                return try parseList(indent: indent)
            }
            return try parseMap(indent: indent, first: nil)
        }

        mutating func parseList(indent: Int) throws -> YAMLValue {
            var items: [YAMLValue] = []
            while !isAtEnd && current.indent == indent && current.isListItem {
                let line = current
                let rest = String(line.text.dropFirst()).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty {
                    position += 1
                    skipBlank()
                    if !isAtEnd && current.indent > indent {
                        items.append(try parseBlock(indent: current.indent))
                    } else {
                        items.append(.scalar(""))
                    }
                } else if !rest.hasPrefix("\"") && !rest.hasPrefix("'") && !rest.hasPrefix("[") && !rest.hasPrefix("{")
                            && EnvironmentYAML.splitKey(rest) != nil {
                    // `- key: value` starts a mapping whose keys line up after the dash.
                    let column = indent + line.text.count - rest.count
                    items.append(try parseMap(indent: column, first: (line, rest)))
                } else {
                    position += 1
                    skipBlank()
                    items.append(try EnvironmentYAML.scalarOrFlow(rest, line: line.number))
                }
            }
            return .list(items)
        }

        /// A mapping at `indent`. `first` is a `- key: value` line whose
        /// mapping starts after the dash.
        mutating func parseMap(indent: Int, first: (line: Line, text: String)?) throws -> YAMLValue {
            var entries: [YAMLEntry] = []
            var pending = first
            while true {
                let line: Line
                let text: String
                if let start = pending {
                    line = start.line
                    text = start.text
                    pending = nil
                } else {
                    guard !isAtEnd, current.indent == indent, !current.isListItem else { break }
                    line = current
                    text = current.text
                }
                guard let pair = EnvironmentYAML.splitKey(text) else {
                    throw ParseError(line: line.number, message: "Expected “key: value”.")
                }
                if entries.contains(where: { $0.key == pair.key }) {
                    throw ParseError(line: line.number, message: "“\(pair.key)” appears twice.")
                }
                position += 1
                let value: YAMLValue
                if ["|", "|-", ">", ">-"].contains(pair.value) {
                    value = .scalar(blockScalar(parentIndent: indent, folded: pair.value.hasPrefix(">"), keepsNewline: !pair.value.hasSuffix("-")))
                } else if !pair.value.isEmpty {
                    skipBlank()
                    value = try EnvironmentYAML.scalarOrFlow(pair.value, line: line.number)
                } else {
                    skipBlank()
                    // A list may sit at the same indentation as its key.
                    if !isAtEnd && (current.indent > indent || (current.indent == indent && current.isListItem)) {
                        value = try parseBlock(indent: current.indent)
                    } else {
                        value = .scalar("")
                    }
                }
                entries.append(YAMLEntry(key: pair.key, value: value))
            }
            return .map(entries)
        }

        /// The lines of a `|` or `>` block: everything indented further than its key.
        mutating func blockScalar(parentIndent: Int, folded: Bool, keepsNewline: Bool) -> String {
            var collected: [String] = []
            var blockIndent: Int?
            while position < lines.count {
                let line = lines[position]
                if line.isBlank {
                    collected.append("")
                } else {
                    guard line.indent > parentIndent else { break }
                    let indent = blockIndent ?? line.indent
                    blockIndent = indent
                    collected.append(String(line.raw.dropFirst(min(indent, line.raw.count))))
                }
                position += 1
            }
            // Trailing blank lines belong to whatever follows.
            while collected.last == "" {
                collected.removeLast()
            }
            skipBlank()
            let text: String
            if folded {
                text = collected.split(separator: "", omittingEmptySubsequences: false)
                    .map { $0.joined(separator: " ") }
                    .joined(separator: "\n")
            } else {
                text = collected.joined(separator: "\n")
            }
            return keepsNewline && !text.isEmpty ? text + "\n" : text
        }
    }

    /// Splits `key: value` at the first colon followed by a space or the end
    /// of the line, outside quotes.
    fileprivate static func splitKey(_ text: String) -> (key: String, value: String)? {
        let characters = Array(text)
        var quote: Character?
        for index in characters.indices {
            let character = characters[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if index == 0 && (character == "\"" || character == "'") {
                quote = character
            } else if character == ":" && (index + 1 == characters.count || characters[index + 1] == " ") {
                var key = String(characters[..<index]).trimmingCharacters(in: .whitespaces)
                if let unquoted = try? unquote(key, line: 0) {
                    key = unquoted
                }
                guard !key.isEmpty else { return nil }
                let value = String(characters[(index + 1)...]).trimmingCharacters(in: .whitespaces)
                return (key, value)
            }
        }
        return nil
    }

    fileprivate static func scalarOrFlow(_ text: String, line: Int) throws -> YAMLValue {
        if text.hasPrefix("[") || text.hasPrefix("{") {
            let isList = text.hasPrefix("[")
            guard text.hasSuffix(isList ? "]" : "}") else {
                throw ParseError(line: line, message: "Unclosed “\(text.prefix(1))”.")
            }
            let inner = text.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            guard !inner.contains("[") && !inner.contains("{") else {
                throw ParseError(line: line, message: "Nested flow collections aren't supported.")
            }
            let parts = splitFlow(inner)
            if isList {
                return .list(try parts.map { YAMLValue.scalar(try unquote($0, line: line)) })
            }
            return .map(try parts.map { part in
                guard let pair = splitKey(part) else {
                    throw ParseError(line: line, message: "Expected “key: value”.")
                }
                return YAMLEntry(key: pair.key, value: .scalar(try unquote(pair.value, line: line)))
            })
        }
        return .scalar(try unquote(text, line: line))
    }

    /// Splits flow items at commas outside quotes.
    private static func splitFlow(_ text: String) -> [String] {
        var parts: [String] = []
        var part = ""
        var quote: Character?
        for character in text {
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "," {
                parts.append(part.trimmingCharacters(in: .whitespaces))
                part = ""
                continue
            }
            part.append(character)
        }
        parts.append(part.trimmingCharacters(in: .whitespaces))
        return parts.filter { !$0.isEmpty }
    }

    private static func unquote(_ text: String, line: Int) throws -> String {
        guard let first = text.first, first == "\"" || first == "'" else {
            return text
        }
        guard text.count >= 2, text.last == first else {
            throw ParseError(line: line, message: "Unclosed quote.")
        }
        let inner = text.dropFirst().dropLast()
        if first == "'" {
            return inner.replacingOccurrences(of: "''", with: "'")
        }
        var result = ""
        var iterator = inner.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            switch iterator.next() {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "0": result.append("\0")
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            case "/": result.append("/")
            case "u":
                let hex = String((0..<4).compactMap { _ in iterator.next() })
                guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else {
                    throw ParseError(line: line, message: "Invalid “\\u” escape.")
                }
                result.unicodeScalars.append(scalar)
            case let other?:
                result.append("\\")
                result.append(other)
            case nil:
                result.append("\\")
            }
        }
        return result
    }

    // MARK: Writing

    /// Block-style YAML with every `.scalar` in double quotes, so values such
    /// as `yes`, `1.0` or `a: b` stay strings, and `.plain` values as they are.
    static func write(_ value: YAMLValue) -> String {
        var output = ""
        write(value, indent: 0, into: &output)
        return output
    }

    private static func write(_ value: YAMLValue, indent: Int, into output: inout String) {
        let padding = String(repeating: " ", count: indent)
        switch value {
        case let .map(entries):
            for entry in entries {
                output += padding + quoteKey(entry.key) + ":"
                switch entry.value {
                case let .map(children) where !children.isEmpty:
                    output += "\n"
                    write(entry.value, indent: indent + 2, into: &output)
                case let .list(items) where !items.isEmpty:
                    output += "\n"
                    write(entry.value, indent: indent + 2, into: &output)
                default:
                    output += " " + inline(entry.value) + "\n"
                }
            }
        case let .list(items):
            for item in items {
                switch item {
                case let .map(entries) where !entries.isEmpty:
                    // The first key goes on the dash's line, the rest line up under it.
                    var nested = ""
                    write(item, indent: indent + 2, into: &nested)
                    output += padding + "- " + String(nested.dropFirst(indent + 2))
                case let .list(inner) where !inner.isEmpty:
                    output += padding + "-\n"
                    write(item, indent: indent + 2, into: &output)
                default:
                    output += padding + "- " + inline(item) + "\n"
                }
            }
        case .scalar, .plain:
            output += padding + inline(value) + "\n"
        }
    }

    private static func inline(_ value: YAMLValue) -> String {
        switch value {
        case let .scalar(text): quote(text)
        case let .plain(text): text
        case .list: "[]"
        case .map: "{}"
        }
    }

    /// Keys are left bare when they're plain words, as environment variable
    /// names and field names are.
    private static func quoteKey(_ key: String) -> String {
        key.wholeMatch(of: #/[A-Za-z_][A-Za-z0-9_.\-]*/#) != nil ? key : quote(key)
    }

    static func quote(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}
