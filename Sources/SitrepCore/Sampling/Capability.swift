import Foundation

/// One thing mac-sitrep can or cannot measure on this machine.
///
/// Capabilities are established by *probing* — actually attempting the read —
/// never by consulting a table of what ought to work. A `doctor` report
/// assembled from a hardcoded list would be a claim, not a measurement, and the
/// whole point of SPEC principle 11 is that gaps are disclosed honestly.
public struct Capability: Sendable, Equatable {

    /// Stable dotted identifier, e.g. `memory.pressure`. Safe to script against.
    public let id: String

    /// Human-readable name for report output.
    public let title: String

    public let category: Category

    /// The API or command this reads from, named concretely enough to audit.
    public let source: String

    public let status: Status

    public var isAvailable: Bool {
        if case .available = status { return true }
        return false
    }

    /// True only for capabilities expected to work here that did not. Drives
    /// `doctor`'s exit code; a root-gated metric being unavailable is expected
    /// and is not a failure.
    public var isFailure: Bool {
        if case .unavailable(.probeFailed) = status { return true }
        return false
    }

    public enum Category: String, Sendable, CaseIterable {
        case memory, cpu, gpu, disk, network, thermal, process, power

        /// Display order in the report — most consulted first.
        public static let displayOrder: [Category] = [
            .memory, .cpu, .gpu, .thermal, .disk, .network, .process, .power,
        ]
    }

    public enum Status: Sendable, Equatable {
        /// The probe succeeded. `sample` carries a real value read during the
        /// probe, so the reader can see the measurement rather than trust a
        /// checkmark.
        case available(sample: String)
        case unavailable(Reason)
    }

    public enum Reason: Sendable, Equatable {
        /// Readable with elevated privileges, deliberately not read.
        /// mac-sitrep never uses root (ARCHITECTURE #4), so this is a choice
        /// rather than a limitation, and says so.
        case requiresPrivilege(detail: String, alternative: String?)

        /// No public API exists at any privilege level.
        case noPublicAPI(detail: String, alternative: String?)

        /// The hardware or OS on this machine does not provide it.
        case unsupportedOnThisMac(detail: String)

        /// Expected to work here and did not. This is a real defect.
        case probeFailed(detail: String)

        public var summary: String {
            switch self {
            case let .requiresPrivilege(detail, _): detail
            case let .noPublicAPI(detail, _): detail
            case let .unsupportedOnThisMac(detail): detail
            case let .probeFailed(detail): detail
            }
        }

        /// The capability id to consult instead, when one exists.
        public var alternative: String? {
            switch self {
            case let .requiresPrivilege(_, alternative): alternative
            case let .noPublicAPI(_, alternative): alternative
            case .unsupportedOnThisMac, .probeFailed: nil
            }
        }

        /// Stable machine-readable discriminator for `--json`.
        public var kind: String {
            switch self {
            case .requiresPrivilege: "requires_privilege"
            case .noPublicAPI: "no_public_api"
            case .unsupportedOnThisMac: "unsupported_on_this_mac"
            case .probeFailed: "probe_failed"
            }
        }
    }
}

/// A capability paired with the closure that establishes its status.
public struct CapabilityProbe: Sendable {
    public let id: String
    public let title: String
    public let category: Capability.Category
    public let source: String

    private let evaluate: @Sendable () -> Capability.Status

    public init(
        id: String,
        title: String,
        category: Capability.Category,
        source: String,
        evaluate: @escaping @Sendable () -> Capability.Status
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.source = source
        self.evaluate = evaluate
    }

    public func run() -> Capability {
        Capability(
            id: id, title: title, category: category, source: source, status: evaluate()
        )
    }
}

/// The result of probing every registered capability.
public struct CapabilityReport: Sendable {
    public let machine: Machine
    public let capabilities: [Capability]
    public let selfFootprint: SelfFootprint?

    public var available: [Capability] { capabilities.filter(\.isAvailable) }
    public var unavailable: [Capability] { capabilities.filter { !$0.isAvailable } }

    /// Capabilities that should have worked and did not.
    public var failures: [Capability] { capabilities.filter(\.isFailure) }

    public func capabilities(in category: Capability.Category) -> [Capability] {
        capabilities.filter { $0.category == category }
    }
}

// MARK: - JSON

/// Encoded as a flat object per capability rather than Swift's tagged-enum
/// default, so `--json` is pleasant to script against with `jq`.
extension Capability: Encodable {
    private enum CodingKeys: String, CodingKey {
        case id, title, category, source, available, sample, reason, detail, alternative
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(category.rawValue, forKey: .category)
        try container.encode(source, forKey: .source)

        switch status {
        case let .available(sample):
            try container.encode(true, forKey: .available)
            try container.encode(sample, forKey: .sample)
        case let .unavailable(reason):
            try container.encode(false, forKey: .available)
            try container.encode(reason.kind, forKey: .reason)
            try container.encode(reason.summary, forKey: .detail)
            try container.encodeIfPresent(reason.alternative, forKey: .alternative)
        }
    }
}

extension CapabilityReport: Encodable {
    private enum CodingKeys: String, CodingKey {
        case machine, capabilities, selfFootprint, availableCount, unavailableCount, failureCount
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(machine, forKey: .machine)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encodeIfPresent(selfFootprint, forKey: .selfFootprint)
        try container.encode(available.count, forKey: .availableCount)
        try container.encode(unavailable.count, forKey: .unavailableCount)
        try container.encode(failures.count, forKey: .failureCount)
    }
}
