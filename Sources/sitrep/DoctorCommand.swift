import ArgumentParser
import Foundation
import SitrepCore

/// Reports what this Mac can and cannot measure.
///
/// Both halves are always printed. A report that listed only working sensors
/// would let a silently missing metric look like an absent one, which SPEC
/// principle 11 treats as a defect rather than a cosmetic issue.
struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Report every metric this Mac can measure, and every one it cannot.",
        discussion: """
        Each capability is established by attempting a real read, not by \
        consulting a table. Metrics requiring root are reported as declined by \
        design, with the alternative to use instead.

        Exits non-zero if a capability expected to work here failed to probe, \
        so this is usable as a scripted health check.
        """
    )

    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json = false

    @Flag(name: .long, help: "Show only capabilities that are unavailable.")
    var gapsOnly = false

    func run() throws {
        let report = CapabilityRegistry.report()

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } else {
            print(Self.render(report, gapsOnly: gapsOnly))
        }

        // A root-gated metric being unavailable is expected and is not a
        // failure; only a probe that should have succeeded counts.
        if !report.failures.isEmpty {
            throw ExitCode(1)
        }
    }

    static func render(_ report: CapabilityReport, gapsOnly: Bool) -> String {
        var lines: [String] = []

        lines.append(report.machine.summary)
        lines.append("")

        if !gapsOnly {
            lines.append("AVAILABLE (\(report.available.count))")
            for category in Capability.Category.displayOrder {
                let items = report.capabilities(in: category).filter(\.isAvailable)
                guard !items.isEmpty else { continue }
                for capability in items {
                    guard case let .available(sample) = capability.status else { continue }
                    lines.append("  ✓ \(capability.id.padded(to: 30))\(sample)")
                    lines.append("    \(capability.source)".dimmed)
                }
            }
            lines.append("")
        }

        lines.append("UNAVAILABLE (\(report.unavailable.count))")
        for category in Capability.Category.displayOrder {
            let items = report.capabilities(in: category).filter { !$0.isAvailable }
            guard !items.isEmpty else { continue }
            for capability in items {
                guard case let .unavailable(reason) = capability.status else { continue }
                let marker = capability.isFailure ? "✗" : "–"
                lines.append("  \(marker) \(capability.id.padded(to: 30))\(capability.title)")
                lines.append(contentsOf: reason.summary.wrapped(at: 68, indent: "      "))
                if let alternative = reason.alternative {
                    lines.append("      → use \(alternative) instead")
                }
            }
        }

        if let footprint = report.selfFootprint {
            lines.append("")
            lines.append("SELF")
            let verdict = footprint.withinMemoryBudget ? "✓" : "✗ OVER BUDGET"
            lines.append(
                "  peak footprint  \(Format.bytes(footprint.peakFootprint)) of "
                    + "\(Format.bytes(footprint.budgetBytes))  \(verdict)"
            )
            lines.append("  cpu time        \(Format.seconds(footprint.cpuSeconds)) this invocation")
            lines.append(contentsOf: SelfFootprint.cpuBudgetNote.wrapped(at: 68, indent: "  "))
        }

        if !report.failures.isEmpty {
            lines.append("")
            lines.append("\(report.failures.count) capability probe(s) failed unexpectedly.")
        }

        return lines.joined(separator: "\n")
    }
}

private extension String {
    func padded(to width: Int) -> String {
        count >= width ? self + "  " : self + String(repeating: " ", count: width - count)
    }

    /// Marks supporting detail. Kept as a no-op transform rather than ANSI
    /// codes so output stays clean when piped; colour is a later concern.
    var dimmed: String { self }

    /// Wraps to `width` columns, prefixing every line with `indent`.
    func wrapped(at width: Int, indent: String) -> [String] {
        var lines: [String] = []
        var current = ""

        for word in split(separator: " ") {
            if current.isEmpty {
                current = String(word)
            } else if current.count + word.count + 1 <= width {
                current += " \(word)"
            } else {
                lines.append(indent + current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(indent + current) }

        return lines
    }
}
