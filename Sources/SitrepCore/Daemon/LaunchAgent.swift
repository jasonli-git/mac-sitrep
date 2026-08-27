import Foundation

/// Installs and removes the background agent.
///
/// A user `LaunchAgent`, never a `LaunchDaemon`: agents run as the user in their
/// session and need no privilege to install, which follows directly from
/// ARCHITECTURE #4. It also means `launchctl bootstrap gui/$UID` works without a
/// password, so installation is a single command with no authorization prompt.
public enum LaunchAgent {

    public enum Status: Sendable, Equatable {
        case notInstalled
        /// Plist present but launchd has no record of it loaded.
        case installedNotLoaded
        case running(pid: Int32)
        case loadedNotRunning

        public var summary: String {
            switch self {
            case .notInstalled: "not installed"
            case .installedNotLoaded: "installed, not loaded"
            case let .running(pid): "running (pid \(pid))"
            case .loadedNotRunning: "loaded, not currently running"
            }
        }
    }

    /// The plist launchd reads.
    ///
    /// `ProcessType: Background` puts the daemon in the throttled QoS band —
    /// deliberately, since a monitor that competes with the work it measures
    /// distorts its own readings and violates its budget. `KeepAlive` with
    /// `SuccessfulExit: false` restarts it if it crashes but respects a clean
    /// exit, so `sitrep daemon uninstall` is not fought by launchd.
    public static func plist(executablePath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(DaemonPaths.bundleIdentifier)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executablePath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
            <key>ThrottleInterval</key>
            <integer>30</integer>
            <key>ProcessType</key>
            <string>Background</string>
            <key>LowPriorityIO</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(DaemonPaths.logPath)</string>
            <key>StandardErrorPath</key>
            <string>\(DaemonPaths.errorLogPath)</string>
        </dict>
        </plist>
        """
    }

    /// Writes the plist and loads it.
    ///
    /// - Parameter executablePath: absolute path to the `sitrepd` binary. Taken
    ///   as a parameter rather than discovered, because a plist pointing at a
    ///   moved or deleted binary fails in a way that is tedious to diagnose.
    public static func install(executablePath: String) throws {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw InstallError.executableNotFound(executablePath)
        }

        try DaemonPaths.createSupportDirectory()
        try FileManager.default.createDirectory(
            atPath: DaemonPaths.launchAgentDirectory, withIntermediateDirectories: true
        )
        try plist(executablePath: executablePath)
            .write(toFile: DaemonPaths.launchAgentPath, atomically: true, encoding: .utf8)

        // Unload first so install is idempotent and picks up a changed plist.
        //
        // launchd unloads asynchronously, so bootstrapping immediately after
        // bootout races it and fails with EIO. Wait for the job to actually
        // disappear rather than assuming the command was synchronous.
        _ = try? CommandRunner.run(
            "/bin/launchctl", ["bootout", "gui/\(getuid())/\(DaemonPaths.bundleIdentifier)"]
        )
        waitForUnload()

        _ = try CommandRunner.run(
            "/bin/launchctl", ["bootstrap", "gui/\(getuid())", DaemonPaths.launchAgentPath]
        )
    }

    /// Blocks until launchd no longer knows about the job, up to `timeout`.
    private static func waitForUnload(timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let stillLoaded = (try? CommandRunner.run(
                "/bin/launchctl", ["print", "gui/\(getuid())/\(DaemonPaths.bundleIdentifier)"]
            )) != nil
            if !stillLoaded { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    public static func uninstall() throws {
        _ = try? CommandRunner.run(
            "/bin/launchctl", ["bootout", "gui/\(getuid())/\(DaemonPaths.bundleIdentifier)"]
        )
        waitForUnload()
        if FileManager.default.fileExists(atPath: DaemonPaths.launchAgentPath) {
            try FileManager.default.removeItem(atPath: DaemonPaths.launchAgentPath)
        }
    }

    public static func status() -> Status {
        guard FileManager.default.fileExists(atPath: DaemonPaths.launchAgentPath) else {
            return .notInstalled
        }

        guard let output = try? CommandRunner.run(
            "/bin/launchctl", ["print", "gui/\(getuid())/\(DaemonPaths.bundleIdentifier)"]
        ) else {
            return .installedNotLoaded
        }

        // `launchctl print` reports "pid = N" only while the job is running; a
        // loaded-but-idle job omits it.
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("pid = ") else { continue }
            if let pid = Int32(trimmed.dropFirst("pid = ".count)) {
                return .running(pid: pid)
            }
        }
        return .loadedNotRunning
    }

    public enum InstallError: Error, CustomStringConvertible {
        case executableNotFound(String)

        public var description: String {
            switch self {
            case let .executableNotFound(path):
                "no executable at \(path) — build sitrepd first"
            }
        }
    }
}
