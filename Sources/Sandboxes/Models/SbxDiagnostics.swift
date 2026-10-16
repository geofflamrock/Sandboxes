import Foundation

/// The results of `sbx diagnose --output json`, which checks the installation,
/// platform, storage and connection to the daemon.
struct SbxDiagnostics: Sendable {
    struct Check: Identifiable, Sendable {
        enum Status: String, Sendable {
            case pass, warn, fail, skip
        }

        let id: Int
        /// Such as "Socket" or "Disk space".
        let name: String
        let status: Status
        /// A short result, such as "responsive" or "51 GiB free".
        let message: String
        /// More about the result, such as a path. May be empty.
        let detail: String
        /// What to do about a warning or failure. May be empty.
        let hint: String
        /// The group sbx shows it under, such as "Installation", when the JSON
        /// includes one.
        let category: String?
    }

    let checks: [Check]

    var failures: [Check] { checks.filter { $0.status == .fail } }
    var warnings: [Check] { checks.filter { $0.status == .warn } }

    func count(_ status: Check.Status) -> Int {
        checks.filter { $0.status == status }.count
    }

    static let arguments = ["diagnose", "--output", "json"]

    /// Runs the checks. sbx exits with an error when a check fails, so the
    /// output is parsed whatever the exit code.
    static func run() async throws -> SbxDiagnostics {
        let result = try await SbxCLI.run(arguments)
        do {
            return try parse(result.output)
        } catch {
            guard result.succeeded else {
                throw SbxError.commandFailed(arguments: arguments, exitCode: result.exitCode, output: result.output)
            }
            throw error
        }
    }

    static func parse(_ output: String) throws -> SbxDiagnostics {
        // Skip anything printed before the JSON, such as a notice on stderr.
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}") else {
            throw ParseError()
        }
        let report = try JSONDecoder().decode(Report.self, from: Data(output[start...end].utf8))
        guard !report.checks.isEmpty else { throw ParseError() }
        return SbxDiagnostics(
            checks: report.checks.enumerated().map { index, check in
                Check(
                    id: index,
                    name: check.name,
                    status: Check.Status(rawValue: check.status.lowercased()) ?? .warn,
                    message: check.message ?? "",
                    detail: check.detail ?? "",
                    hint: check.hint ?? "",
                    category: check.category ?? check.group
                )
            }
        )
    }

    struct ParseError: LocalizedError {
        var errorDescription: String? {
            "sbx diagnose didn't return results Sandboxes understands. Run “sbx diagnose” in Terminal to see them."
        }
    }

    private struct Report: Decodable {
        let checks: [RawCheck]
    }

    private struct RawCheck: Decodable {
        let name: String
        let status: String
        let message: String?
        let detail: String?
        let hint: String?
        let category: String?
        let group: String?
    }
}
