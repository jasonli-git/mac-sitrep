import Foundation

/// Display formatting for report output.
///
/// Canonical values are stored and computed in bytes, seconds, and degrees
/// Celsius; conversion to human units happens only at the edge, here.
public enum Format {

    /// Bytes in binary units, e.g. `9.7 GB`, `412 MB`, `0 B`.
    ///
    /// Uses GB/MB labels for binary multiples, matching what Activity Monitor
    /// and the rest of the Mac ecosystem display.
    public static func bytes(_ value: UInt64) -> String {
        let units: [(threshold: UInt64, divisor: Double, suffix: String)] = [
            (1 << 40, Double(1 << 40), "TB"),
            (1 << 30, Double(1 << 30), "GB"),
            (1 << 20, Double(1 << 20), "MB"),
            (1 << 10, Double(1 << 10), "KB"),
        ]

        for unit in units where value >= unit.threshold {
            let scaled = Double(value) / unit.divisor
            let precision = scaled < 10 ? 1 : 0
            return String(format: "%.\(precision)f %@", scaled, unit.suffix)
        }
        return "\(value) B"
    }

    /// Seconds with precision that shrinks as the magnitude grows.
    public static func seconds(_ value: Double) -> String {
        if value < 1 { return String(format: "%.3f s", value) }
        if value < 60 { return String(format: "%.2f s", value) }
        return String(format: "%.0f s", value)
    }

    /// A percentage to one decimal place.
    public static func percent(_ fraction: Double) -> String {
        String(format: "%.1f%%", fraction * 100)
    }
}
