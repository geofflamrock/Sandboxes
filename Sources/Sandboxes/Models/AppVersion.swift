import Foundation

/// A dotted version number, such as "1.2.0", compared part by part so that
/// 1.10.0 is newer than 1.9.0.
struct AppVersion: Comparable, CustomStringConvertible {
    let parts: [Int]

    /// Accepts a leading "v", as release tags have. Returns nil for anything
    /// that isn't numbers separated by dots.
    init?(_ string: String) {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "v" || trimmed.first == "V" {
            trimmed.removeFirst()
        }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    var description: String {
        parts.map(String.init).joined(separator: ".")
    }

    /// Missing parts count as zero, so 1.2 equals 1.2.0.
    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
