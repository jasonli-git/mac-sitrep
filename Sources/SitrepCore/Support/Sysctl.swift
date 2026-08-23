import Darwin

/// Typed wrappers over `sysctlbyname(3)`.
///
/// Every reader in this package goes through here rather than shelling out to
/// the `sysctl` binary. Spawning a subprocess on each sampling tick would cost
/// more CPU than the sampling itself and would perturb the measurement — see
/// ARCHITECTURE.md decision #1.
public enum Sysctl {

    /// Reads a NUL-terminated string value, e.g. `hw.model`.
    public static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }

        return String(cString: buffer)
    }

    /// Reads a fixed-width integer value, e.g. `hw.memsize`.
    ///
    /// The kernel's width for a given key is not always the width the caller
    /// wants, so the raw bytes are read first and then widened. Reading a key
    /// whose kernel width exceeds `T` fails rather than silently truncating.
    public static func integer<T: FixedWidthInteger>(_ name: String, as type: T.Type = T.self) -> T? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        switch size {
        case MemoryLayout<UInt32>.size:
            var value: UInt32 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return T(exactly: value)
        case MemoryLayout<UInt64>.size:
            var value: UInt64 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return T(exactly: value)
        default:
            return nil
        }
    }
}
