import Foundation

/// Health state with hysteresis.
///
/// `HealthState.classify` answers "what is true at this instant", which is right
/// for a one-shot CLI. A continuously updating display needs more: a value
/// oscillating around a threshold would alternate states on every tick, and an
/// alert that fires forty times is noise rather than signal.
///
/// So a state must *hold* before it is entered, and must *clear for longer*
/// before it is left. The asymmetry is deliberate — escalate promptly, de-escalate
/// reluctantly. A machine that recovers for two seconds mid-incident has not
/// recovered.
public struct HealthTracker: Sendable {

    public struct Dwell: Sendable {
        /// How long a worse state must persist before it is entered.
        public let escalate: TimeInterval
        /// How long conditions must be clear before a better state is entered.
        public let deescalate: TimeInterval

        public static let `default` = Dwell(escalate: 15, deescalate: 60)
    }

    public private(set) var current: HealthState = .healthy
    public private(set) var reasons: [String] = []

    private let dwell: Dwell
    /// The instantaneous state, and when it was first continuously observed.
    private var pending: (state: HealthState, since: Date)?

    public init(dwell: Dwell = .default, initial: HealthState = .healthy) {
        self.dwell = dwell
        self.current = initial
    }

    /// Feeds one observation. Returns the confirmed state if it changed.
    @discardableResult
    public mutating func observe(sample: Sample, at now: Date = Date()) -> HealthState? {
        let (observed, observedReasons) = HealthState.classify(sample: sample)
        return observe(state: observed, reasons: observedReasons, at: now)
    }

    /// Feeds a pre-classified observation. Split out so the dwell logic is
    /// testable without constructing whole samples.
    @discardableResult
    public mutating func observe(
        state observed: HealthState, reasons observedReasons: [String], at now: Date
    ) -> HealthState? {
        guard observed != current else {
            // Back to the confirmed state; any pending transition is abandoned.
            pending = nil
            reasons = observedReasons
            return nil
        }

        if pending?.state != observed {
            pending = (observed, now)
            return nil
        }

        guard let pending else { return nil }
        let required = severity(of: observed) > severity(of: current)
            ? dwell.escalate
            : dwell.deescalate

        guard now.timeIntervalSince(pending.since) >= required else { return nil }

        current = observed
        reasons = observedReasons
        self.pending = nil
        return current
    }

    private func severity(of state: HealthState) -> Int {
        switch state {
        case .healthy: 0
        case .warning: 1
        case .critical: 2
        }
    }
}
