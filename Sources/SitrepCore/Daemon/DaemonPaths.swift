import Foundation

/// Where mac-sitrep keeps its files.
///
/// Everything lives under the user's Application Support directory. Nothing is
/// written outside the user's own home, which follows from running unprivileged
/// (ARCHITECTURE #4) — there is no system location we could write to anyway.
public enum DaemonPaths {

    public static let bundleIdentifier = "com.jasonli.mac-sitrep"

    public static var supportDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/mac-sitrep"
    }

    public static var databasePath: String { "\(supportDirectory)/history.db" }
    public static var logPath: String { "\(supportDirectory)/sitrepd.log" }
    public static var errorLogPath: String { "\(supportDirectory)/sitrepd.error.log" }

    public static var launchAgentDirectory: String {
        "\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/LaunchAgents"
    }

    public static var launchAgentPath: String {
        "\(launchAgentDirectory)/\(bundleIdentifier).plist"
    }

    public static func createSupportDirectory() throws {
        try FileManager.default.createDirectory(
            atPath: supportDirectory, withIntermediateDirectories: true
        )
    }
}
