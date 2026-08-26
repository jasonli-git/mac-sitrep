import ArgumentParser
import Foundation
import SitrepCore

/// Current machine state — the default command.
struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Current system state.",
        discussion: """
        Takes two readings a short interval apart, because CPU, disk, and \
        network figures are cumulative counters since boot and cannot yield a \
        current rate from a single read. Raise --interval for steadier numbers.
        """
    )

    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json = false

    @Option(name: .long, help: "Seconds between the two readings.")
    var interval: Double = SystemSampler.defaultInterval

    func validate() throws {
        guard interval > 0, interval <= 60 else {
            throw ValidationError("--interval must be greater than 0 and at most 60 seconds.")
        }
    }

    func run() throws {
        guard let sample = SystemSampler.sample(interval: interval) else {
            throw CleanExit.message("Could not read system state; run 'sitrep doctor'.")
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(StatusPayload(sample: sample)), as: UTF8.self))
        } else {
            print(Self.render(sample))
        }
    }

    static func render(_ sample: Sample) -> String {
        let (state, reasons) = HealthState.classify(sample: sample)
        var lines: [String] = []

        lines.append("\(state.symbol) \(state.label)")
        for reason in reasons {
            lines.append("   \(reason)")
        }
        lines.append("")

        let memory = sample.memory
        lines.append(row(
            "MEMORY",
            "\(Format.bytes(memory.usedBytes)) / \(Format.bytes(memory.totalBytes))",
            "\(Format.percent(memory.usedFraction)) used"
        ))
        lines.append(row(
            "  compressed", Format.bytes(memory.compressedBytes),
            "wired \(Format.bytes(memory.wiredBytes))"
        ))
        // Swap shows the rate first: the file size is sticky and a non-zero
        // total with a zero rate is a healthy machine (ARCHITECTURE #6).
        lines.append(row(
            "  swap",
            "\(Format.bytes(memory.swapUsedBytes)) used",
            memory.swapOutsPerSecond > 0
                ? String(format: "%.1f swap-outs/s", memory.swapOutsPerSecond)
                : "no swap-out activity"
        ))
        if let pressure = memory.pressure {
            lines.append(row("  pressure", pressure.label, ""))
        }
        lines.append("")

        lines.append(row(
            "CPU", Format.percent(sample.cpu.utilization),
            "\(sample.cpu.coreCount) cores · user \(Format.percent(sample.cpu.userFraction))"
                + " · sys \(Format.percent(sample.cpu.systemFraction))"
        ))

        if let gpu = sample.gpu {
            lines.append(row(
                "GPU", Format.percent(gpu.utilization),
                "\(Format.bytes(gpu.allocatedBytes)) allocated"
            ))
        }

        lines.append(row("THERMAL", sample.thermal.rawValue,
                         sample.thermal.isThrottlingLikely ? "throttling likely" : ""))
        lines.append("")

        lines.append(row(
            "DISK", "\(Format.bytes(sample.disk.freeBytes)) free",
            "read \(Format.rate(sample.disk.readBytesPerSecond))"
                + " · write \(Format.rate(sample.disk.writtenBytesPerSecond))"
        ))
        lines.append(row(
            "NETWORK", "",
            "in \(Format.rate(sample.network.receivedBytesPerSecond))"
                + " · out \(Format.rate(sample.network.sentBytesPerSecond))"
        ))

        lines.append("")
        lines.append("sampled over \(Format.seconds(sample.intervalSeconds))")

        return lines.joined(separator: "\n")
    }

    private static func row(_ label: String, _ value: String, _ detail: String) -> String {
        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
        }
        // Trimming the tail keeps rows with an empty detail column from
        // carrying invisible padding into piped output.
        return (pad(label, 14) + pad(value, 22) + detail)
            .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }
}

private struct StatusPayload: Encodable {
    let sample: Sample
    let health: HealthState
    let healthReasons: [String]

    init(sample: Sample) {
        let (state, reasons) = HealthState.classify(sample: sample)
        self.sample = sample
        self.health = state
        self.healthReasons = reasons
    }
}
