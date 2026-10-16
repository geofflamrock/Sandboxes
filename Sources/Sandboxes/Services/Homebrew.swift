import Foundation

/// Finds Homebrew, which installs and upgrades sbx.
enum Homebrew {
    /// The first `brew` on the search path, which includes Homebrew's usual
    /// locations even when the login shell's PATH doesn't.
    static func executableURL() -> URL? {
        let fileManager = FileManager.default
        for directory in ShellEnvironment.searchPath.split(separator: ":") {
            let path = "\(directory)/brew"
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    static let installURL = URL(string: "https://brew.sh")!
}
