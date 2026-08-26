import Foundation

/// Thermal pressure as macOS reports it.
///
/// This is the public, unprivileged stand-in for die temperature, which is
/// root-gated and declined by design (ARCHITECTURE #4). It answers the question
/// temperature was wanted for — is the machine thermally stressed enough to be
/// throttling — without the privilege.
public enum ThermalState: String, Sendable, Codable, CaseIterable {
    case nominal
    case fair
    case serious
    case critical

    /// Current thermal state.
    public static func current() -> ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }

    /// Whether the machine is likely limiting performance to shed heat.
    ///
    /// `serious` is where macOS begins meaningful throttling, which is the point
    /// at which a profiling run's numbers stop describing the software and start
    /// describing the thermal envelope.
    public var isThrottlingLikely: Bool {
        self == .serious || self == .critical
    }
}
