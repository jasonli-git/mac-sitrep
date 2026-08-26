import ArgumentParser
import Foundation
import SitrepCore

/// What happened over a window.
struct History: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Summarize recorded history over a window.",
        discussion: """
        Reads the collector's database directly, so this works whether or not \
        the daemon is currently running. Requires 'sitrep daemon install' to \
        have recorded something first.

        Windows accept a suffix: 30m, 24h, 7d.
        """
    )

    @Option(name: .long, help: "Window to summarize, e.g. 30m, 24h, 7d.")
    var since: String = "24h"

    @Option(name: .long, help: "Top processes to list.")
    var limit: Int = 10

    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json = false

    func run() throws {
        let window = try Self.parseWindow(since)
        let start = Date().addingTimeInterval(-window)

        let store = try SampleStore.openReadOnly(path: DaemonPaths.databasePath)

        guard let summary = try store.summary(since: start) else {
            throw CleanExit.message(
                "No samples recorded in the last \(since). "
                    + "Is the collector installed? Try 'sitrep daemon status'."
            )
        }

        let processes = try store.topProcesses(since: start, limit: limit)
        let events = try store.events(since: start)
        let cost = try store.daemonCost(since: start)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let payload = HistoryPayload(
                summary: summary, processes: processes, events: events, daemonCost: cost
            )
            print(String(decoding: try encoder.encode(payload), as: UTF8.self))
            return
        }

        print(Self.render(
            summary: summary, processes: processes, events: events, cost: cost, window: since
        ))
    }

    static func render(
        summary: SampleStore.Summary,
        processes: [SampleStore.ProcessTotal],
        events: [SampleStore.EventRecord],
        cost: SampleStore.DaemonCost?,
        window: String
    ) -> String {
        var lines: [String] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"

        lines.append(
            "\(window) · \(summary.sampleCount) samples · "
                + "\(formatter.string(from: summary.since)) → "
                + "\(formatter.string(from: summary.until))"
        )
        lines.append("")

        lines.append("\(summary.worstHealth.symbol) worst state  \(summary.worstHealth.label)")
        lines.append("  memory       avg \(Format.bytes(summary.memoryUsedAverage))"
            + " · peak \(Format.bytes(summary.memoryUsedPeak))")
        lines.append("  cpu          avg \(Format.percent(summary.cpuAverage))"
            + " · peak \(Format.percent(summary.cpuPeak))")
        lines.append("  swap-outs    peak \(String(format: "%.1f", summary.swapOutsPeak))/s"
            + (summary.swapOutsPeak > 0 ? "" : "  (zero-swap held)"))
        lines.append("  thermal      worst \(summary.worstThermal.rawValue)")

        if !processes.isEmpty {
            lines.append("")
            lines.append("TOP CONSUMERS")
            for process in processes {
                let name = process.name.count > 28
                    ? String(process.name.prefix(27)) + "…"
                    : process.name
                let padded = name + String(repeating: " ", count: max(0, 30 - name.count))
                lines.append(
                    "  \(padded)peak \(Format.bytes(process.peakFootprint))"
                        + " · avg \(Format.bytes(process.averageFootprint))"
                )
            }
        }

        if !events.isEmpty {
            lines.append("")
            lines.append("EVENTS")
            // Most recent last, so the timeline reads downward like a log.
            for event in events.suffix(12) {
                let detail = event.detail.map { " — \($0)" } ?? ""
                lines.append(
                    "  \(formatter.string(from: event.timestamp))  \(event.kind)\(detail)"
                )
            }
            if events.count > 12 {
                lines.append("  … \(events.count - 12) earlier events")
            }
        }

        if let cost {
            lines.append("")
            lines.append("MAC-SITREP ITSELF")
            lines.append("  peak footprint  \(Format.bytes(cost.peakFootprint))"
                + " of \(Format.bytes(SelfBudget.memoryBytes))")
            lines.append("  avg cpu         \(Format.percent(cost.averageCPU))"
                + " · peak \(Format.percent(cost.peakCPU))")
            lines.append("  budget          "
                + (cost.withinBudget ? "within" : "EXCEEDED \(cost.breachCount)×"))
        }

        return lines.joined(separator: "\n")
    }

    /// Parses `30m` / `24h` / `7d` into seconds.
    static func parseWindow(_ text: String) throws -> TimeInterval {
        guard let suffix = text.last, let value = Double(text.dropLast()), value > 0 else {
            throw ValidationError("could not parse '\(text)'; use a form like 30m, 24h, or 7d")
        }

        switch suffix {
        case "m": return value * 60
        case "h": return value * 3600
        case "d": return value * 86_400
        default:
            throw ValidationError("unknown unit '\(suffix)'; use m, h, or d")
        }
    }
}

private struct HistoryPayload: Encodable {
    let summary: SampleStore.Summary
    let processes: [SampleStore.ProcessTotal]
    let events: [SampleStore.EventRecord]
    let daemonCost: SampleStore.DaemonCost?
}
