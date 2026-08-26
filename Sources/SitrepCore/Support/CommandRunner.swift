import Foundation

/// Bounded subprocess execution.
///
/// ARCHITECTURE #1 forbids spawning subprocesses in the sampling loop. This
/// exists for the two documented exceptions — `pmset -g therm` and
/// `pmset -g log` — which have no public API equivalent and are read
/// infrequently, never per sample.
///
/// Adding a caller here should be deliberate. If a metric can be read through
/// `sysctl`, `libproc`, Mach, or IOKit, it must be.
public enum CommandRunner {

    public enum Failure: Error, Equatable {
        case notExecutable(String)
        case launchFailed(String)
        case timedOut
        case exited(code: Int32)
    }

    /// Runs `executable` with `arguments`, returning trimmed stdout.
    ///
    /// - Parameter maximumBytes: output is truncated beyond this. `pmset -g log`
    ///   can emit megabytes; reading it unbounded would be a memory problem in a
    ///   tool that reports memory problems.
    public static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = 5,
        maximumBytes: Int = 1 << 20
    ) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw Failure.notExecutable(executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }

        // Read before waiting: a process filling the pipe buffer while we wait
        // on exit would deadlock.
        let data = pipe.fileHandleForReading.readDataToEndOfFile().prefix(maximumBytes)

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(10_000)
        }

        if process.isRunning {
            process.terminate()
            throw Failure.timedOut
        }

        guard process.terminationStatus == 0 else {
            throw Failure.exited(code: process.terminationStatus)
        }

        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether an executable exists and is runnable, without running it.
    public static func isAvailable(_ executable: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: executable)
    }
}
