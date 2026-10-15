import Foundation

/// A snapshot of a running sandbox's resource use. `sbx` doesn't report usage,
/// so this is read from `/proc` and `df` inside the sandbox with `sbx exec`.
struct SandboxUsage: Hashable {
    var cpuCount: Int?
    /// Busy time across all of the sandbox's CPUs, from 0 to 100.
    var cpuPercent: Double?
    var memoryUsed: Int64?
    var memoryTotal: Int64?
    var diskUsed: Int64?
    var diskTotal: Int64?
    var uptime: TimeInterval?

    /// Samples `/proc/stat` a second apart to work out CPU use, then reads
    /// memory, root filesystem and uptime. Each line is tagged so warnings
    /// printed by `sbx` don't get in the way.
    private static let script = """
        echo "cpu1 $(head -n1 /proc/stat)"; sleep 1; echo "cpu2 $(head -n1 /proc/stat)"
        echo "ncpu $(nproc)"
        grep -E '^(MemTotal|MemAvailable):' /proc/meminfo
        echo "disk $(df -Pk / | tail -n1)"
        echo "uptime $(cat /proc/uptime)"
        """

    /// Only call this for a running sandbox: `sbx exec` starts a stopped one.
    static func fetch(for sandbox: Sandbox) async throws -> SandboxUsage {
        let arguments = ["exec", sandbox.name, "sh", "-c", script]
        let result = try await SbxCLI.run(arguments)
        guard result.succeeded else {
            throw SbxError.commandFailed(arguments: arguments, exitCode: result.exitCode, output: result.output)
        }
        return parse(result.output)
    }

    static func parse(_ output: String) -> SandboxUsage {
        var usage = SandboxUsage()
        var cpuSamples: [String: [Int64]] = [:]
        var memoryAvailable: Int64?
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let tag = fields.first else { continue }
            let values = fields.dropFirst()
            switch tag {
            case "cpu1", "cpu2":
                // cpu1 cpu user nice system idle iowait irq softirq steal ...
                cpuSamples[tag] = values.dropFirst().compactMap { Int64($0) }
            case "ncpu":
                usage.cpuCount = values.first.flatMap { Int($0) }
            case "MemTotal:":
                usage.memoryTotal = values.first.flatMap { Int64($0) }.map { $0 * 1024 }
            case "MemAvailable:":
                memoryAvailable = values.first.flatMap { Int64($0) }.map { $0 * 1024 }
            case "disk":
                // disk FILESYSTEM 1024-BLOCKS USED AVAILABLE CAPACITY MOUNT
                let numbers = values.dropFirst().prefix(2).compactMap { Int64($0) }
                if numbers.count == 2 {
                    usage.diskTotal = numbers[0] * 1024
                    usage.diskUsed = numbers[1] * 1024
                }
            case "uptime":
                usage.uptime = values.first.flatMap { TimeInterval($0) }
            default:
                continue
            }
        }
        if let total = usage.memoryTotal, let memoryAvailable {
            usage.memoryUsed = max(0, total - memoryAvailable)
        }
        if let first = cpuSamples["cpu1"], let second = cpuSamples["cpu2"],
           first.count >= 4, first.count == second.count {
            func idle(_ sample: [Int64]) -> Int64 { sample[3] + (sample.count > 4 ? sample[4] : 0) }
            // Guest time is already counted in user and nice.
            let counted = min(first.count, 8)
            let total = second.prefix(counted).reduce(0, +) - first.prefix(counted).reduce(0, +)
            let busy = total - (idle(second) - idle(first))
            if total > 0 {
                usage.cpuPercent = min(100, max(0, Double(busy) / Double(total) * 100))
            }
        }
        return usage
    }
}

enum DurationFormat {
    /// The two largest units of a duration, e.g. "2d 6h", "3h 12m" or "5m".
    static func short(_ interval: TimeInterval) -> String {
        let minutes = Int(max(0, interval)) / 60
        let days = minutes / 1440
        let hours = minutes / 60 % 24
        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            let remainder = minutes % 60
            return remainder > 0 ? "\(hours)h \(remainder)m" : "\(hours)h"
        }
        return minutes > 0 ? "\(minutes)m" : "<1m"
    }
}
