import Foundation

/// A destination a sandbox tried to reach that's waiting for the user to
/// respond, from `sbx policy approval ls`.
struct NetworkApproval: Identifiable, Hashable {
    struct Option: Hashable {
        /// Passed to `sbx policy approval respond --option`, e.g. `allow`.
        let id: String
        let label: String
    }

    let id: String
    let sandbox: String?
    /// The destination, e.g. `api.example.com:443`.
    let title: String
    /// Why it needs approval, e.g. the protocol and the policy that requires it.
    let detail: String?
    let options: [Option]

    var approveOption: Option? {
        options.first { NetworkDecision($0.id) == .allow }
    }

    /// Leaves the destination blocked until the sandbox asks for it again.
    var dismissOption: Option? {
        options.first { $0.id.lowercased().contains("dismiss") }
    }

    static func respondArguments(approval: NetworkApproval, option: Option) -> [String] {
        ["policy", "approval", "respond", approval.id, "--option", option.id]
    }

    /// What the sandbox asked for. A request an HTTP rule matched is titled
    /// like `GET api.example.com:443/v1/data`; others are just the host.
    var target: (host: String, method: String?, path: String?) {
        var text = Substring(title.trimmingCharacters(in: .whitespaces))
        var method: String?
        if let space = text.firstIndex(of: " ") {
            method = String(text[..<space])
            text = text[text.index(after: space)...].drop { $0 == " " }
        }
        guard let slash = text.firstIndex(of: "/") else {
            return (String(text), nil, nil)
        }
        return (String(text[..<slash]), method ?? "ANY", String(text[slash...]))
    }

    /// Adds a deny rule covering what the sandbox asked for, scoped to
    /// `sandbox`, or for every sandbox when it's nil.
    static func denyArguments(approval: NetworkApproval, sandbox: String?) -> [String] {
        let target = approval.target
        var arguments = ["policy", "deny", "network"]
        if let sandbox {
            arguments += ["--sandbox", sandbox]
        }
        arguments.append(target.host)
        if let method = target.method, let path = target.path {
            arguments += ["--method", method, "--path", path]
        }
        return arguments
    }

    /// Pending approvals for every sandbox.
    static func fetch() async throws -> [NetworkApproval] {
        let jsonArguments = ["policy", "approval", "ls", "--json"]
        let result = try await SbxCLI.run(jsonArguments)
        if result.succeeded, let json = try? NetworkPolicyParser.document(result.output) {
            return NetworkApprovalParser.approvals(inJSON: json)
        }
        if result.succeeded {
            // Plain text, such as a message saying nothing is pending.
            return NetworkApprovalParser.approvals(inTable: result.output)
        }
        guard result.output.lowercased().contains("unknown flag") else {
            throw SbxError.commandFailed(arguments: jsonArguments, exitCode: result.exitCode, output: result.output)
        }
        // Older versions of sbx only print a table.
        return NetworkApprovalParser.approvals(inTable: try await SbxCLI.runChecked(["policy", "approval", "ls"]))
    }
}

/// Parses `sbx policy approval ls`, either its JSON or its table:
///
///     APPROVAL          SANDBOX      TITLE                 DETAIL              OPTIONS
///     network:cWtN-4x…  my-sandbox   api.example.com:443   Protocol: TCP …     allow (Allow), dismiss (Dismiss)
enum NetworkApprovalParser {
    typealias JSON = SandboxListParser

    // MARK: JSON

    static func approvals(inJSON json: Any) -> [NetworkApproval] {
        if let array = json as? [Any] {
            return array.flatMap { approvals(inJSON: $0) }
        }
        guard let object = json as? [String: Any] else { return [] }
        if let approval = approval(from: object) {
            return [approval]
        }
        return object.values
            .filter { $0 is [Any] || $0 is [String: Any] }
            .flatMap { approvals(inJSON: $0) }
    }

    private static func approval(from object: [String: Any]) -> NetworkApproval? {
        guard let options = JSON.value(in: object, for: ["options", "choices"]),
              let id = JSON.string(JSON.value(in: object, for: ["id", "approval_id", "approval"])), !id.isEmpty
        else {
            return nil
        }
        let parsedOptions: [NetworkApproval.Option]
        if let text = options as? String {
            parsedOptions = self.options(fromText: text)
        } else {
            parsedOptions = (options as? [Any] ?? []).compactMap { item in
                if let object = item as? [String: Any] {
                    guard let id = JSON.string(JSON.value(in: object, for: ["id", "option_id", "option", "value", "name"])) else { return nil }
                    let label = JSON.string(JSON.value(in: object, for: ["label", "title", "name"])) ?? id.capitalized
                    return NetworkApproval.Option(id: id, label: label)
                }
                return JSON.string(item).map { NetworkApproval.Option(id: $0, label: $0.capitalized) }
            }
        }
        let title = JSON.string(JSON.value(in: object, for: ["title", "subject", "resource", "destination", "host"]))
        return NetworkApproval(
            id: id,
            sandbox: JSON.string(JSON.value(in: object, for: ["sandbox", "sandbox_name", "sandbox_id"])),
            title: title.flatMap { $0.isEmpty ? nil : $0 } ?? id,
            detail: JSON.string(JSON.value(in: object, for: ["detail", "details", "description", "summary", "reason"])),
            options: parsedOptions
        )
    }

    // MARK: Table

    static func approvals(inTable output: String) -> [NetworkApproval] {
        let lines = output.components(separatedBy: .newlines)
        guard let headerIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("APPROVAL") }) else {
            return []
        }
        let header = lines[headerIndex]
        let names = ["APPROVAL", "SANDBOX", "TITLE", "DETAIL", "OPTIONS"]
        // Columns are padded to line up with the header, so slice rows at the
        // offsets where each heading starts.
        let starts = names.compactMap { name -> (String, Int)? in
            guard let range = header.range(of: name) else { return nil }
            return (name, header.distance(from: header.startIndex, to: range.lowerBound))
        }
        .sorted { $0.1 < $1.1 }

        return lines[(headerIndex + 1)...].compactMap { line -> NetworkApproval? in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            var columns: [String: String] = [:]
            let characters = Array(line)
            for (index, (name, start)) in starts.enumerated() {
                let end = index + 1 < starts.count ? starts[index + 1].1 : characters.count
                guard start < characters.count else { continue }
                columns[name] = String(characters[start..<min(end, characters.count)]).trimmingCharacters(in: .whitespaces)
            }
            guard let id = columns["APPROVAL"], !id.isEmpty else { return nil }
            let title = columns["TITLE"] ?? ""
            let detail = columns["DETAIL"] ?? ""
            return NetworkApproval(
                id: id,
                sandbox: columns["SANDBOX"],
                title: title.isEmpty ? id : title,
                detail: detail.isEmpty ? nil : detail,
                options: options(fromText: columns["OPTIONS"] ?? "")
            )
        }
    }

    /// Reads options written as `allow (Allow), dismiss (Dismiss)`.
    static func options(fromText text: String) -> [NetworkApproval.Option] {
        text.split(separator: ",").compactMap { part in
            let part = part.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { return nil }
            guard let open = part.firstIndex(of: "("), part.hasSuffix(")") else {
                return NetworkApproval.Option(id: part, label: part.capitalized)
            }
            let id = part[..<open].trimmingCharacters(in: .whitespaces)
            let label = part[part.index(after: open)..<part.index(before: part.endIndex)].trimmingCharacters(in: .whitespaces)
            return NetworkApproval.Option(id: id, label: label.isEmpty ? id.capitalized : label)
        }
    }
}
