import Darwin
import Foundation

/// mac-sitrep's declared resource budget.
///
/// SPEC principle 6 requires the monitor to disclose its own cost and hold
/// itself to the same kind of contract it applies to other projects. If the
/// measured figure ever exceeds these, the budget is corrected in public rather
/// than quietly dropped.
public enum SelfBudget {
    /// 100 MB, per SPEC's self-observability section.
    public static let memoryBytes: UInt64 = 100 * 1 << 20

    /// 2% sustained CPU. Not checkable from a one-shot CLI invocation — see
    /// ``SelfFootprint/cpuBudgetNote``.
    public static let cpuFraction: Double = 0.02
}

/// What mac-sitrep itself is consuming, measured through the same code path any
/// other process gets.
public struct SelfFootprint: Sendable, Equatable {

    public let physicalFootprint: UInt64
    public let peakFootprint: UInt64
    public let cpuSeconds: Double

    public var budgetBytes: UInt64 { SelfBudget.memoryBytes }

    /// Whether the *peak* is within budget. Checking the instantaneous value
    /// would let a process that already spiked report itself compliant.
    public var withinMemoryBudget: Bool { peakFootprint <= SelfBudget.memoryBytes }

    /// Why no CPU percentage is reported here.
    ///
    /// A percentage needs an interval. A CLI invocation lasting milliseconds
    /// would produce a meaningless ratio — trivially 0% or, worse, a startup
    /// spike near 100%. The sustained figure is a daemon property and is
    /// checked by `sitrepd` from Milestone 3.
    public static let cpuBudgetNote =
        "2% sustained CPU is a daemon figure; a one-shot CLI run cannot measure it."

    public static func current() -> SelfFootprint? {
        guard let usage = Rusage.current() else { return nil }

        return SelfFootprint(
            physicalFootprint: usage.physicalFootprint,
            // The kernel's high-water mark is refreshed at task-accounting
            // boundaries, not synchronously with the footprint itself, so a
            // process growing quickly can momentarily report a current
            // footprint *above* its own recorded peak. Taking the max keeps
            // the reported peak monotonic and errs toward over-reporting,
            // which is the safe direction for a budget check and for a
            // published requirement. See ARCHITECTURE #17.
            peakFootprint: max(usage.lifetimePeakFootprint, usage.physicalFootprint),
            cpuSeconds: usage.cpuSeconds
        )
    }
}

extension SelfFootprint: Encodable {
    private enum CodingKeys: String, CodingKey {
        case physicalFootprintBytes, peakFootprintBytes, cpuSeconds
        case memoryBudgetBytes, withinMemoryBudget, cpuBudgetNote
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(physicalFootprint, forKey: .physicalFootprintBytes)
        try container.encode(peakFootprint, forKey: .peakFootprintBytes)
        try container.encode(cpuSeconds, forKey: .cpuSeconds)
        try container.encode(budgetBytes, forKey: .memoryBudgetBytes)
        try container.encode(withinMemoryBudget, forKey: .withinMemoryBudget)
        try container.encode(Self.cpuBudgetNote, forKey: .cpuBudgetNote)
    }
}
