import Darwin
import Foundation
import SitrepCore

/// The background agent.
///
/// Everything substantive lives in `Collector`; this file owns only the things
/// that cannot be tested in-process — the run loop, signal handling, and the
/// rollup schedule.
///
/// Deliberately not built on `Task`/async. The loop is one sequential cycle
/// separated by a sleep, with no concurrency to reason about, and the QoS that
/// matters is set process-wide by launchd's `ProcessType: Background` rather
/// than per-task.

let store: SampleStore
do {
    try DaemonPaths.createSupportDirectory()
    store = try SampleStore.open(path: DaemonPaths.databasePath)
} catch {
    FileHandle.standardError.write(Data("sitrepd: cannot open history: \(error)\n".utf8))
    exit(1)
}

_ = try? store.recordMachine(.current())
try? store.record(.daemonStart, detail: "sitrepd \(SitrepVersion.current)")

/// Set by the signal handler; checked between ticks.
///
/// `sig_atomic_t` because a handler may only touch async-signal-safe state.
/// Draining on the next tick boundary rather than exiting inside the handler
/// means the current transaction commits rather than being rolled back.
nonisolated(unsafe) var shouldStop: sig_atomic_t = 0

for terminationSignal in [SIGTERM, SIGINT] {
    signal(terminationSignal) { _ in shouldStop = 1 }
}

let collector = Collector(store: store)

/// Rollup runs on a wall-clock schedule rather than a tick count, so its cost
/// does not scale with the alert cadence.
let rollupInterval: TimeInterval = 600
var lastRollup = Date()

while shouldStop == 0 {
    let now = Date()
    var wait = Collector.Cadence.default.resting

    do {
        let result = try collector.tick(at: now)
        wait = result.nextInterval
    } catch {
        // A failed tick must not kill the daemon: a transient SQLite lock or a
        // sysctl that momentarily fails should cost one sample, not the whole
        // history. Persistent failure shows up as a gap plus these log lines.
        FileHandle.standardError.write(Data("sitrepd: tick failed: \(error)\n".utf8))
    }

    if now.timeIntervalSince(lastRollup) >= rollupInterval {
        do {
            try Rollup.run(store: store, now: now)
            lastRollup = now
        } catch {
            FileHandle.standardError.write(Data("sitrepd: rollup failed: \(error)\n".utf8))
        }
    }

    // Wake early to check the stop flag rather than sleeping a full interval,
    // so termination is prompt without a signal-safe wakeup mechanism.
    let deadline = Date().addingTimeInterval(wait)
    while shouldStop == 0, Date() < deadline {
        Thread.sleep(forTimeInterval: min(0.25, max(0, deadline.timeIntervalSinceNow)))
    }
}

try? store.record(.daemonStop)
exit(0)
