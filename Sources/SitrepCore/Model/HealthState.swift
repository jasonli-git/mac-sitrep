import Foundation

/// Thresholds that classify a sample as healthy, warning, or critical.
///
/// Named constants rather than inline literals so the values are auditable and
/// so the eventual per-project overrides have somewhere obvious to slot in.
/// These are provisional: they are absolute thresholds chosen from the machine's
/// behavior, and SPEC's position is that fixed thresholds are not enough.
/// Learned per-project baselines replace most of them post-v1.
public enum HealthThresholds {
    /// Any sustained swap-out activity violates the zero-swap policy. The rate
    /// is what matters, not the swap file size (ARCHITECTURE #6).
    public static let swapOutsPerSecondWarning: Double = 0

    /// Disk free fraction below which capacity becomes a concern.
    public static let diskFreeWarning = 0.10
    public static let diskFreeCritical = 0.05

    /// Memory used fraction. High used memory alone is not a problem on macOS —
    /// the OS deliberately uses what is available — so this is set high and
    /// exists to catch the case where pressure has not yet caught up.
    public static let memoryUsedWarning = 0.90
}

/// Overall machine health.
///
/// Derived from a single sample with no hysteresis. That is correct for a
/// one-shot CLI invocation, which cannot flap, but it is **not** sufficient for
/// a continuously updating display: a value oscillating around a threshold would
/// alternate states every tick. The daemon adds hysteresis — enter a state after
/// the condition holds N seconds, leave only after it clears for longer — in
/// Milestone 3.
public enum HealthState: String, Sendable, Encodable, CaseIterable {
    case healthy
    case warning
    case critical

    public var symbol: String {
        switch self {
        case .healthy: "🟢"
        case .warning: "🟡"
        case .critical: "🔴"
        }
    }

    public var label: String { rawValue.uppercased() }

    public init(sample: Sample) {
        self = Self.classify(sample: sample).state
    }

    /// The state plus the specific conditions that produced it.
    ///
    /// Reasons are returned rather than just the verdict because "🟡 WARNING"
    /// with no explanation is an alert, not a diagnosis — and SPEC's whole
    /// position is that the tool should say *why*.
    public static func classify(sample: Sample) -> (state: HealthState, reasons: [String]) {
        var criticalReasons: [String] = []
        var warningReasons: [String] = []

        if sample.memory.pressure == .critical {
            criticalReasons.append("memory pressure critical")
        } else if sample.memory.pressure == .warning {
            warningReasons.append("memory pressure elevated")
        }

        if sample.thermal.isThrottlingLikely {
            criticalReasons.append("thermal state \(sample.thermal.rawValue)")
        } else if sample.thermal == .fair {
            warningReasons.append("thermal state fair")
        }

        if sample.memory.swapOutsPerSecond > HealthThresholds.swapOutsPerSecondWarning {
            let rate = String(format: "%.1f", sample.memory.swapOutsPerSecond)
            warningReasons.append("swapping out at \(rate)/s")
        }

        if sample.disk.freeFraction < HealthThresholds.diskFreeCritical {
            criticalReasons.append("disk \(Format.percent(sample.disk.freeFraction)) free")
        } else if sample.disk.freeFraction < HealthThresholds.diskFreeWarning {
            warningReasons.append("disk \(Format.percent(sample.disk.freeFraction)) free")
        }

        if sample.memory.usedFraction > HealthThresholds.memoryUsedWarning {
            warningReasons.append("memory \(Format.percent(sample.memory.usedFraction)) used")
        }

        if !criticalReasons.isEmpty {
            return (.critical, criticalReasons + warningReasons)
        }
        if !warningReasons.isEmpty {
            return (.warning, warningReasons)
        }
        return (.healthy, [])
    }
}
