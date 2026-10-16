import Foundation

/// Reads the YAML that environment files are written in, into nested
/// `[String: Any]`, `[Any]` and `String` values. It covers what such files
/// use: block mappings and lists, inline `[a, b]` and `{a: b}`, quoted and
/// plain scalars, `|` and `>` blocks, and comments. Anchors, tags and
/// multiple documents aren't supported; sbx reads the file itself, so this
/// only has to be good enough to show what's in it.
enum YAMLReader {
    struct ParseError: LocalizedError {
        let line: Int
        let message: String
        var errorDescription: String? { "Line \(line): \(message)" }
    }

    static func parse(_ text: String) throws -> Any? {
        var parser = Parser(lines: Line.split(text))
        guard parser.index < parser.lines.count else { return nil }
        let value = try parser.block(indent: parser.lines[parser.index].indent)
        parser.skipBlank()
        if parser.index < parser.lines.count {
            let line = parser.lines[parser.index]
            throw ParseError(line: line.number, message: "Unexpected indentation.")
        }
        return value
    }

    // MARK: Lines

    fileprivate struct Line {
        var number: Int
        var indent: Int
        var text: String
        /// The line as written, for `|` and `>` blocks, which keep comments and spacing.
        var raw: String

        var isListItem: Bool { text == "-" || text.hasPrefix("- ") }

        static func split(_ text: String) -> [Line] {
            var lines: [Line] = []
            for (offset, raw) in text.components(separatedBy: .newlines).enumerated() {
                let indent = raw.prefix { $0 == " " }.count
                let content = stripComment(String(raw.dropFirst(indent))).trimmingCharacters(in: .whitespaces)
                if content == "---" || content == "..." { continue }
                // Blank lines are kept for blocks, which need them, and skipped elsewhere.
                lines.append(Line(number: offset + 1, indent: content.isEmpty ? -1 : indent, text: content, raw: raw))
            }
            return lines
        }

        /// Drops a `#` comment: one at the start or after a space, outside quotes.
        private static func stripComment(_ text: String) -> String {
            var quote: Character?
            var previous: Character = " "
            for index in text.indices {
                let character = text[index]
                if let open = quote {
                    if character == open { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == "#" && previous.isWhitespace {
                    return String(text[..<index])
                }
                previous = character
            }
            return text
        }
    }

    // MARK: Blocks

    private struct Parser {
        var lines: [Line]
        var index = 0

        init(lines: [Line]) {
            self.lines = lines
            skipBlank()
        }

        mutating func skipBlank() {
            while index < lines.count && lines[index].indent < 0 { index += 1 }
        }

        mutating func block(indent: Int) throws -> Any {
            skipBlank()
            return lines[index].isListItem ? try list(indent: indent) : try mapping(indent: indent)
        }

        mutating func list(indent: Int) throws -> [Any] {
            var items: [Any] = []
            while index < lines.count, lines[index].indent == indent, lines[index].isListItem {
                let line = lines[index]
                let rest = String(line.text.dropFirst()).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty {
                    index += 1
                    skipBlank()
                    if index < lines.count && lines[index].indent > indent {
                        items.append(try block(indent: lines[index].indent))
                    } else {
                        items.append("")
                    }
                } else if YAMLReader.keyAndValue(rest) != nil && !rest.hasPrefix("[") && !rest.hasPrefix("{") {
                    // `- key: value` starts a mapping indented to where the key is.
                    let offset = line.text.count - rest.count
                    lines[index] = Line(number: line.number, indent: indent + offset, text: rest, raw: line.raw)
                    items.append(try mapping(indent: indent + offset))
                } else {
                    index += 1
                    items.append(try YAMLReader.inline(rest, line: line.number))
                }
                skipBlank()
            }
            return items
        }

        mutating func mapping(indent: Int) throws -> [String: Any] {
            var mapping: [String: Any] = [:]
            while index < lines.count, lines[index].indent == indent, !lines[index].isListItem {
                let line = lines[index]
                guard let (key, value) = YAMLReader.keyAndValue(line.text) else {
                    throw ParseError(line: line.number, message: "Expected “key: value”.")
                }
                index += 1
                if value == "|" || value == ">" || value.hasPrefix("|") || value.hasPrefix(">") {
                    mapping[key] = blockScalar(folded: value.hasPrefix(">"), parentIndent: indent)
                } else if value.isEmpty {
                    skipBlank()
                    // A list may sit at the same indent as its key.
                    if index < lines.count && (lines[index].indent > indent || (lines[index].indent == indent && lines[index].isListItem)) {
                        mapping[key] = try block(indent: lines[index].indent)
                    } else {
                        mapping[key] = NSNull()
                    }
                } else {
                    mapping[key] = try YAMLReader.inline(value, line: line.number)
                }
                skipBlank()
            }
            return mapping
        }

        mutating func blockScalar(folded: Bool, parentIndent: Int) -> String {
            var collected: [String] = []
            var blockIndent: Int?
            while index < lines.count {
                let line = lines[index]
                let indent = line.raw.prefix { $0 == " " }.count
                let isBlank = line.raw.trimmingCharacters(in: .whitespaces).isEmpty
                if !isBlank && indent <= parentIndent { break }
                if !isBlank && blockIndent == nil { blockIndent = indent }
                collected.append(isBlank ? "" : String(line.raw.dropFirst(min(indent, blockIndent ?? indent))))
                index += 1
            }
            while collected.last == "" { collected.removeLast() }
            return collected.joined(separator: folded ? " " : "\n")
        }
    }

    // MARK: Scalars

    /// Splits `key: value` at the first colon followed by a space or the end, outside quotes.
    fileprivate static func keyAndValue(_ text: String) -> (String, String)? {
        var quote: Character?
        for index in text.indices {
            let character = text[index]
            if let open = quote {
                if character == open { quote = nil }
                continue
            }
            if (character == "\"" || character == "'") && index == text.startIndex {
                quote = character
            } else if character == ":" {
                let next = text.index(after: index)
                if next == text.endIndex || text[next] == " " {
                    let key = unquote(String(text[..<index]).trimmingCharacters(in: .whitespaces))
                    let value = String(text[next...]).trimmingCharacters(in: .whitespaces)
                    return key.isEmpty ? nil : (key, value)
                }
            } else if character == "[" || character == "{" {
                if index == text.startIndex { return nil }
            }
        }
        return nil
    }

    /// A value on one line: an inline list or mapping, or a scalar.
    fileprivate static func inline(_ text: String, line: Int) throws -> Any {
        if text.hasPrefix("[") {
            guard text.hasSuffix("]") else { throw ParseError(line: line, message: "Unclosed “[”.") }
            return try splitInline(String(text.dropFirst().dropLast())).map { try inline($0, line: line) }
        }
        if text.hasPrefix("{") {
            guard text.hasSuffix("}") else { throw ParseError(line: line, message: "Unclosed “{”.") }
            var mapping: [String: Any] = [:]
            for entry in splitInline(String(text.dropFirst().dropLast())) {
                guard let (key, value) = keyAndValue(entry) else {
                    throw ParseError(line: line, message: "Expected “key: value” in “{…}”.")
                }
                mapping[key] = value.isEmpty ? NSNull() : try inline(value, line: line)
            }
            return mapping
        }
        return unquote(text)
    }

    /// Splits the inside of `[…]` or `{…}` at top-level commas.
    private static func splitInline(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        for character in text {
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "[" || character == "{" {
                depth += 1
            } else if character == "]" || character == "}" {
                depth -= 1
            } else if character == "," && depth == 0 {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(character)
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts
    }

    private static func unquote(_ text: String) -> String {
        if text.count >= 2 && text.hasPrefix("'") && text.hasSuffix("'") {
            return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if text.count >= 2 && text.hasPrefix("\"") && text.hasSuffix("\"") {
            // Double-quoted strings have JSON's escapes, and a few more JSON doesn't.
            if let data = text.data(using: .utf8),
               let string = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String {
                return string
            }
            return String(text.dropFirst().dropLast())
        }
        return text
    }
}
