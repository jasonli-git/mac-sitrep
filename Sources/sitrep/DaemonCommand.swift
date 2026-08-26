import ArgumentParser
import Foundation
import SitrepCore

struct Daemon: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Manage the background collector.",
        discussion: """
        The collector runs as a user LaunchAgent — no root, no privileged \
        helper, no password prompt. It records history so 'sitrep history' can \
        answer what happened while you were not looking.
        """,
        subcommands: [Install.self, Uninstall.self, DaemonStatus.self],
        defaultSubcommand: DaemonStatus.self
    )
}

extension Daemon {

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Install and start the collector."
        )

        @Option(name: .long, help: "Path to the sitrepd binary. Defaults to a sibling of sitrep.")
        var executable: String?

        func run() throws {
            let path = try executable ?? Self.siblingDaemonPath()

            try LaunchAgent.install(executablePath: path)
            print("Installed \(DaemonPaths.bundleIdentifier)")
            print("  binary   \(path)")
            print("  plist    \(DaemonPaths.launchAgentPath)")
            print("  history  \(DaemonPaths.databasePath)")
            print("  status   \(LaunchAgent.status().summary)")
            print("")
            print("The first sample lands one interval after start; a tick with no")
            print("previous reading only primes the delta.")
        }

        /// Locates `sitrepd` next to the running `sitrep` binary.
        ///
        /// Resolves symlinks because a Homebrew-style symlinked `sitrep` would
        /// otherwise produce a plist pointing at a directory with no daemon in it.
        static func siblingDaemonPath() throws -> String {
            let executable = URL(fileURLWithPath: CommandLine.arguments[0])
                .resolvingSymlinksInPath()
            let candidate = executable.deletingLastPathComponent()
                .appendingPathComponent("sitrepd").path

            guard FileManager.default.isExecutableFile(atPath: candidate) else {
                throw ValidationError(
                    "could not find sitrepd next to sitrep (looked at \(candidate)). "
                        + "Pass --executable with its path."
                )
            }
            return candidate
        }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "uninstall",
            abstract: "Stop and remove the collector."
        )

        @Flag(name: .long, help: "Also delete recorded history.")
        var purgeHistory = false

        func run() throws {
            try LaunchAgent.uninstall()
            print("Removed \(DaemonPaths.bundleIdentifier)")

            if purgeHistory {
                for path in [
                    DaemonPaths.databasePath,
                    DaemonPaths.databasePath + "-wal",
                    DaemonPaths.databasePath + "-shm",
                ] where FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.removeItem(atPath: path)
                }
                print("Deleted history at \(DaemonPaths.databasePath)")
            } else {
                print("History kept at \(DaemonPaths.databasePath)")
            }
        }
    }

    struct DaemonStatus: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Show whether the collector is running, and what it costs."
        )

        @Flag(name: .long, help: "Emit machine-readable JSON.")
        var json = false

        func run() throws {
            let status = LaunchAgent.status()
            let cost = try? Self.recentCost()

            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let payload = StatusPayload(
                    installed: status != .notInstalled,
                    state: status.summary,
                    databasePath: DaemonPaths.databasePath,
                    databaseSizeBytes: Self.databaseSize(),
                    cost: cost ?? nil
                )
                print(String(decoding: try encoder.encode(payload), as: UTF8.self))
                return
            }

            print("collector   \(status.summary)")
            print("history     \(DaemonPaths.databasePath)")
            print("size        \(Format.bytes(Self.databaseSize()))")

            // Principle 6: the monitor discloses its own cost, measured by
            // itself, or says plainly that it has not measured it yet.
            if let cost = cost ?? nil {
                print("")
                print("SELF (last 24h, measured by the daemon)")
                print("  peak footprint  \(Format.bytes(cost.peakFootprint))"
                    + " of \(Format.bytes(SelfBudget.memoryBytes))")
                print("  avg footprint   \(Format.bytes(cost.averageFootprint))")
                print("  peak cpu        \(Format.percent(cost.peakCPU))"
                    + " of \(Format.percent(SelfBudget.cpuFraction))")
                print("  avg cpu         \(Format.percent(cost.averageCPU))")
                print("  budget          "
                    + (cost.withinBudget
                        ? "within"
                        : "EXCEEDED in \(cost.breachCount) of \(cost.sampleCount) samples"))
            } else {
                print("")
                print("No self-measurement recorded yet.")
            }
        }

        static func databaseSize() -> UInt64 {
            Database.totalSizeOnDisk(path: DaemonPaths.databasePath)
        }

        static func recentCost() throws -> SampleStore.DaemonCost? {
            let store = try SampleStore.openReadOnly(path: DaemonPaths.databasePath)
            return try store.daemonCost(since: Date().addingTimeInterval(-86_400))
        }
    }
}

private struct StatusPayload: Encodable {
    let installed: Bool
    let state: String
    let databasePath: String
    let databaseSizeBytes: UInt64
    let cost: SampleStore.DaemonCost?
}
