import ArgumentParser
import Foundation
import SitrepCore

/// Top resource consumers.
struct Processes: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "processes",
        abstract: "Top resource consumers by memory or CPU.",
        discussion: """
        Memory is physical footprint — what Activity Monitor shows — not RSS, \
        which overcounts shared pages.

        Processes owned by other users cannot be read without root, which \
        mac-sitrep does not use. The count of unreadable processes is always \
        reported so a partial list is never mistaken for a complete one.
        """
    )

    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json = false

    @Option(name: .shortAndLong, help: "Rows to show.")
    var limit: Int = 10

    @Option(name: .long, help: "Sort by 'ram' or 'cpu'.")
    var sort: String = "ram"

    @Option(name: .long, help: "Seconds between the two readings.")
    var interval: Double = SystemSampler.defaultInterval

    func validate() throws {
        guard ProcessSampler.Sort(rawValue: sort) != nil else {
            let options = ProcessSampler.Sort.allCases.map(\.rawValue).joined(separator: ", ")
            throw ValidationError("--sort must be one of: \(options)")
        }
        guard limit > 0 else { throw ValidationError("--limit must be positive.") }
        guard interval > 0, interval <= 60 else {
            throw ValidationError("--interval must be greater than 0 and at most 60 seconds.")
        }
    }

    func run() throws {
        let snapshot = ProcessSampler.snapshot(
            interval: interval,
            sort: ProcessSampler.Sort(rawValue: sort) ?? .ram,
            limit: limit
        )

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(snapshot), as: UTF8.self))
        } else {
            print(Self.render(snapshot))
        }
    }

    static func render(_ snapshot: ProcessSnapshot) -> String {
        var lines: [String] = []

        lines.append(
            "PID".padding(8) + "PROCESS".padding(28) + "MEMORY".padding(12)
                + "PEAK".padding(12) + "CPU"
        )
        lines.append(String(repeating: "─", count: 68))

        for process in snapshot.processes {
            lines.append(
                "\(process.pid)".padding(8)
                    + process.name.truncated(to: 26).padding(28)
                    + Format.bytes(process.physicalFootprint).padding(12)
                    + Format.bytes(process.peakFootprint).padding(12)
                    + Format.percent(process.cpuUtilization)
            )
        }

        lines.append("")
        lines.append(
            "\(snapshot.processes.count) shown · "
                + "\(Format.bytes(snapshot.readableFootprint)) across readable processes"
        )

        if snapshot.unreadableProcessCount > 0 {
            lines.append(
                "\(snapshot.unreadableProcessCount) processes not readable without root "
                    + "(see 'sitrep doctor' → process.other_users)"
            )
        }

        return lines.joined(separator: "\n")
    }
}

private extension String {
    func padding(_ width: Int) -> String {
        count >= width ? self + " " : self + String(repeating: " ", count: width - count)
    }

    func truncated(to width: Int) -> String {
        count <= width ? self : String(prefix(width - 1)) + "…"
    }
}
