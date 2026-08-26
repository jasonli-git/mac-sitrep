import Foundation
import Testing
@testable import SitrepCore

@Suite("Health hysteresis")
struct HealthTrackerTests {

    static let dwell = HealthTracker.Dwell(escalate: 15, deescalate: 60)
    static let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("A transient spike does not change state")
    func transientSpikeIsIgnored() {
        // The whole point: a value crossing a threshold for one tick is noise.
        var tracker = HealthTracker(dwell: Self.dwell)

        tracker.observe(state: .warning, reasons: ["blip"], at: Self.start)
        tracker.observe(state: .healthy, reasons: [], at: Self.start.addingTimeInterval(5))

        #expect(tracker.current == .healthy)
    }

    @Test("A sustained condition escalates after the dwell time")
    func sustainedConditionEscalates() {
        var tracker = HealthTracker(dwell: Self.dwell)

        #expect(tracker.observe(state: .warning, reasons: ["x"], at: Self.start) == nil)
        #expect(
            tracker.observe(
                state: .warning, reasons: ["x"], at: Self.start.addingTimeInterval(10)
            ) == nil,
            "10s is short of the 15s escalate dwell"
        )

        let changed = tracker.observe(
            state: .warning, reasons: ["x"], at: Self.start.addingTimeInterval(16)
        )
        #expect(changed == .warning)
        #expect(tracker.current == .warning)
    }

    @Test("De-escalation requires a longer clear period than escalation")
    func deescalationIsSlower() {
        var tracker = HealthTracker(dwell: Self.dwell, initial: .warning)

        // 30s clear is enough to escalate but not to de-escalate.
        tracker.observe(state: .healthy, reasons: [], at: Self.start)
        #expect(
            tracker.observe(
                state: .healthy, reasons: [], at: Self.start.addingTimeInterval(30)
            ) == nil,
            "a machine clear for 30s has not recovered from a warning"
        )
        #expect(tracker.current == .warning)

        let changed = tracker.observe(
            state: .healthy, reasons: [], at: Self.start.addingTimeInterval(61)
        )
        #expect(changed == .healthy)
    }

    @Test("Oscillating around a threshold does not flap")
    func oscillationDoesNotFlap() {
        // Alternating every 5s for two minutes: without hysteresis this would
        // produce ~24 state changes and 24 alerts.
        var tracker = HealthTracker(dwell: Self.dwell)
        var changes = 0

        for step in 0..<24 {
            let state: HealthState = step.isMultiple(of: 2) ? .warning : .healthy
            if tracker.observe(
                state: state, reasons: [], at: Self.start.addingTimeInterval(Double(step) * 5)
            ) != nil {
                changes += 1
            }
        }

        #expect(changes == 0, "alternating observations must not produce any confirmed change")
        #expect(tracker.current == .healthy)
    }

    @Test("Escalating past a pending state restarts the dwell")
    func changingPendingStateRestartsDwell() {
        var tracker = HealthTracker(dwell: Self.dwell)

        tracker.observe(state: .warning, reasons: [], at: Self.start)
        // Switching the pending target resets the clock rather than inheriting
        // the warning's elapsed time.
        tracker.observe(state: .critical, reasons: [], at: Self.start.addingTimeInterval(14))
        #expect(
            tracker.observe(
                state: .critical, reasons: [], at: Self.start.addingTimeInterval(20)
            ) == nil
        )

        let changed = tracker.observe(
            state: .critical, reasons: [], at: Self.start.addingTimeInterval(30)
        )
        #expect(changed == .critical)
    }

    @Test("Reasons track the latest observation")
    func reasonsTrackLatestObservation() {
        var tracker = HealthTracker(dwell: Self.dwell)
        tracker.observe(state: .healthy, reasons: ["nothing"], at: Self.start)

        #expect(tracker.reasons == ["nothing"])
    }
}

@Suite("Collector")
struct CollectorTests {

    private func withStore<T>(_ body: (SampleStore) throws -> T) throws -> T {
        let directory = NSTemporaryDirectory() + "sitrep-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        return try body(try SampleStore.open(path: directory + "/history.db"))
    }

    @Test("The first tick primes the delta and stores nothing")
    func firstTickPrimesOnly() throws {
        // Every rate needs two readings, so the first tick cannot produce one.
        try withStore { store in
            let collector = Collector(store: store)
            let result = try collector.tick()

            #expect(result.sample == nil)
            #expect(try store.sampleCount(resolution: .raw) == 0)
        }
    }

    @Test("The second tick produces a stored sample")
    func secondTickStoresSample() throws {
        try withStore { store in
            let collector = Collector(store: store)
            try collector.tick()
            let result = try collector.tick()

            #expect(result.sample != nil)
            #expect(try store.sampleCount(resolution: .raw) == 1)
        }
    }

    @Test("Ticking does not sleep to obtain a rate")
    func tickingDoesNotSleep() throws {
        // The daemon derives rates from its previous reading rather than
        // blocking, which is the reason SystemReading and Sample are separate
        // types. A tick that slept would make the resting cadence a lie.
        try withStore { store in
            let collector = Collector(store: store)
            try collector.tick()

            let began = Date()
            try collector.tick()
            let elapsed = Date().timeIntervalSince(began)

            #expect(elapsed < 0.2, "a tick took \(elapsed)s; it should not block for an interval")
        }
    }

    @Test("Cadence tightens when health degrades")
    func cadenceRespondsToHealth() {
        let cadence = Collector.Cadence.default

        #expect(cadence.interval(for: .healthy) == cadence.resting)
        #expect(cadence.interval(for: .warning) == cadence.alert)
        #expect(cadence.interval(for: .critical) == cadence.alert)
        #expect(cadence.alert < cadence.resting)
    }

    @Test("Self-measurement is recorded")
    func selfMeasurementIsRecorded() throws {
        // Principle 6 is not optional: the daemon measures itself on every tick
        // through the same rusage path any other process gets.
        try withStore { store in
            let collector = Collector(store: store)
            try collector.tick()
            try collector.tick()

            let cost = try #require(try store.daemonCost(since: Date().addingTimeInterval(-60)))
            #expect(cost.sampleCount >= 1)
            #expect(cost.peakFootprint > 0)
        }
    }

    @Test("Process detail is captured on its slower schedule")
    func processDetailIsCapturedPeriodically() throws {
        try withStore { store in
            let collector = Collector(store: store)
            for _ in 0..<Collector.processSampleEveryNTicks + 1 {
                try collector.tick()
            }

            let processes = try store.topProcesses(since: Date().addingTimeInterval(-60))
            #expect(!processes.isEmpty)
            #expect(
                processes.count <= Collector.processesPerTick + Collector.processesPerTick / 3
            )
        }
    }

    @Test("Daemon start is recorded as an event")
    func eventsAreRecorded() throws {
        try withStore { store in
            try store.record(.daemonStart, detail: "test")
            let events = try store.events(since: Date().addingTimeInterval(-60))

            #expect(events.count == 1)
            #expect(events[0].kind == "daemon_start")
            #expect(events[0].detail == "test")
        }
    }
}

@Suite("Launch agent")
struct LaunchAgentTests {

    @Test("Generated plist declares background QoS and the right label")
    func plistDeclaresBackgroundQoS() {
        let plist = LaunchAgent.plist(executablePath: "/usr/local/bin/sitrepd")

        #expect(plist.contains("<string>\(DaemonPaths.bundleIdentifier)</string>"))
        #expect(plist.contains("/usr/local/bin/sitrepd"))
        // Background QoS keeps the monitor from competing with what it measures.
        #expect(plist.contains("<string>Background</string>"))
        #expect(plist.contains("<key>LowPriorityIO</key>"))
        #expect(plist.contains("<key>RunAtLoad</key>"))
    }

    @Test("KeepAlive respects a clean exit")
    func keepAliveRespectsCleanExit() {
        // Otherwise launchd would immediately restart a daemon the user just
        // asked to stop.
        let plist = LaunchAgent.plist(executablePath: "/usr/local/bin/sitrepd")
        #expect(plist.contains("<key>SuccessfulExit</key>"))
        #expect(plist.contains("<false/>"))
    }

    @Test("Install refuses a missing executable")
    func installRefusesMissingExecutable() {
        #expect(throws: LaunchAgent.InstallError.self) {
            try LaunchAgent.install(executablePath: "/nonexistent/sitrepd")
        }
    }

    @Test("Paths live under the user's Application Support")
    func pathsAreUserScoped() {
        // Running unprivileged means there is nowhere else we could write.
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        #expect(DaemonPaths.databasePath.hasPrefix(home))
        #expect(DaemonPaths.launchAgentPath.hasPrefix(home))
        #expect(DaemonPaths.launchAgentPath.hasSuffix(".plist"))
    }
}
