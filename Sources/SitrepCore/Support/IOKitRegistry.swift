import Foundation
import IOKit

/// Property lookups against the IOKit registry.
///
/// GPU utilization and whole-disk I/O counters live here and are readable
/// unprivileged, which is why they survive the no-root constraint while
/// temperature and fan speed do not (ARCHITECTURE #4).
public enum IOKitRegistry {

    /// Properties of the first service matching `className`, or `nil` if no
    /// such service exists on this Mac.
    ///
    /// Takes the first match deliberately: this reads aggregate counters from
    /// the primary accelerator or block device, and enumerating every match
    /// would double-count on machines with more than one.
    public static func firstServiceProperties(className: String) -> [String: Any]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching(className), &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                service, &properties, kCFAllocatorDefault, 0
            ) == KERN_SUCCESS else { continue }

            if let dictionary = properties?.takeRetainedValue() as? [String: Any] {
                return dictionary
            }
        }

        return nil
    }

    /// GPU performance counters from the accelerator's `PerformanceStatistics`.
    ///
    /// Matches on `IOAccelerator` rather than the Apple Silicon-specific
    /// `AGXAccelerator` so the lookup also resolves on Intel Macs, which the
    /// macOS 14 deployment target still admits (ARCHITECTURE #9).
    public static func gpuPerformanceStatistics() -> [String: Any]? {
        guard let properties = firstServiceProperties(className: "IOAccelerator") else {
            return nil
        }
        return properties["PerformanceStatistics"] as? [String: Any]
    }

    /// Cumulative bytes read and written across the primary block device.
    ///
    /// Counters are monotonic since boot; a rate requires two reads.
    public static func blockStorageStatistics() -> (read: UInt64, written: UInt64)? {
        guard
            let properties = firstServiceProperties(className: "IOBlockStorageDriver"),
            let statistics = properties["Statistics"] as? [String: Any],
            let read = statistics["Bytes (Read)"] as? UInt64,
            let written = statistics["Bytes (Write)"] as? UInt64
        else { return nil }

        return (read, written)
    }
}
