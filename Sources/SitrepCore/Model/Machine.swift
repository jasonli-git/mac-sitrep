import Foundation

/// Identity of the Mac a measurement was taken on.
///
/// Every profile artifact embeds one of these. A measured resource requirement
/// is meaningless without the machine it was measured on, and mac-sitrep does
/// not attempt to normalize results across hardware — see SPEC.md non-goals.
public struct Machine: Codable, Equatable, Sendable {

    /// Apple hardware identifier, e.g. `Mac16,10`.
    public let hardwareModel: String

    /// CPU brand string, e.g. `Apple M4`.
    public let cpuBrand: String

    /// Physical RAM in bytes.
    public let physicalMemoryBytes: UInt64

    /// Logical core count (performance + efficiency).
    public let coreCount: Int

    /// Marketing version, e.g. `26.6.2`.
    public let osVersion: String

    /// Kernel build identifier, e.g. `25G83`. Distinguishes point releases that
    /// share a marketing version but can differ in scheduler or VM behavior.
    public let osBuild: String

    public init(
        hardwareModel: String,
        cpuBrand: String,
        physicalMemoryBytes: UInt64,
        coreCount: Int,
        osVersion: String,
        osBuild: String
    ) {
        self.hardwareModel = hardwareModel
        self.cpuBrand = cpuBrand
        self.physicalMemoryBytes = physicalMemoryBytes
        self.coreCount = coreCount
        self.osVersion = osVersion
        self.osBuild = osBuild
    }

    /// Reads the current machine's identity.
    ///
    /// Fields fall back to `"unknown"` / `0` rather than failing: an
    /// unidentifiable machine should still be measurable, and `sitrep doctor`
    /// surfaces the gap.
    public static func current() -> Machine {
        let info = ProcessInfo.processInfo
        let v = info.operatingSystemVersion

        return Machine(
            hardwareModel: Sysctl.string("hw.model") ?? "unknown",
            cpuBrand: Sysctl.string("machdep.cpu.brand_string") ?? "unknown",
            physicalMemoryBytes: Sysctl.integer("hw.memsize") ?? info.physicalMemory,
            coreCount: Sysctl.integer("hw.logicalcpu") ?? info.activeProcessorCount,
            osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            osBuild: Sysctl.string("kern.osversion") ?? "unknown"
        )
    }

    /// Single-line form used in status output and profile headers.
    public var summary: String {
        let gib = Double(physicalMemoryBytes) / 1_073_741_824
        let ram = gib.rounded() == gib
            ? String(format: "%.0f GB", gib)
            : String(format: "%.1f GB", gib)
        return "\(hardwareModel) · \(cpuBrand) · \(ram) · \(coreCount) cores · macOS \(osVersion) (\(osBuild))"
    }
}
