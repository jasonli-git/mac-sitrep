import Foundation
import MachO

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

    /// Absolute path of the running binary, however it was invoked.
    ///
    /// `CommandLine.arguments[0]` is whatever the caller typed. Invoked through
    /// `PATH` it is the bare word `sitrep`, which resolves against the *current
    /// directory* — so locating a sibling binary from it hunted inside whatever
    /// project the user happened to be standing in, and only worked when sitrep
    /// was invoked by absolute path.
    public static func runningExecutablePath() -> String? {
        var size = UInt32(0)
        _ = _NSGetExecutablePath(nil, &size)

        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return String(cString: buffer)
    }

    public static func createSupportDirectory() throws {
        try FileManager.default.createDirectory(
            atPath: supportDirectory, withIntermediateDirectories: true
        )
    }
}
