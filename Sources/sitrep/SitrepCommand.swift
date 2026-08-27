import ArgumentParser
import Foundation
import SitrepCore

@main
struct SitrepCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sitrep",
        abstract: "macOS observability and resource accountability.",
        discussion: """
        Measures what software actually costs to run, and publishes those \
        measurements. Runs entirely unprivileged: metrics requiring root are \
        omitted and disclosed rather than silently dropped.
        """,
        version: SitrepVersion.current,
        subcommands: [
            Status.self, Processes.self, History.self,
            Run.self, Init.self,
            Export.self, Compare.self, CanIRun.self,
            Daemon.self, Doctor.self, Version.self,
        ],
        defaultSubcommand: Status.self
    )
}

/// Health check for the scaffold: exercises the CLI, SitrepCore, and the
/// sysctl bridge in one command. Replaced as the primary entry point by
/// `sitrep` status output in Milestone 2.
struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print version and the machine this build is running on."
    )

    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json = false

    func run() throws {
        let machine = Machine.current()

        if json {
            let payload = VersionPayload(version: SitrepVersion.current, machine: machine)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            print(String(decoding: data, as: UTF8.self))
        } else {
            print("sitrep \(SitrepVersion.current)")
            print(machine.summary)
        }
    }
}

private struct VersionPayload: Encodable {
    let version: String
    let machine: Machine
}
