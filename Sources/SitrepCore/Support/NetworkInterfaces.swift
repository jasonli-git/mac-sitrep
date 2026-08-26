import Darwin

/// System-wide network byte counters.
///
/// Reads `NET_RT_IFLIST2` rather than `getifaddrs(3)`. The `if_data` struct
/// that `getifaddrs` hands back carries **32-bit** byte counters, which wrap
/// every 4 GB — unusable for a tool that reports cumulative I/O. The route
/// sysctl returns `if_msghdr2`, whose embedded `if_data64` counters are 64-bit.
/// This is the same source `netstat -ib` uses.
///
/// Per-process attribution is impossible here at any privilege level and is
/// disclosed as such — see the `network.per_process` capability.
public enum NetworkInterfaces {

    /// Cumulative bytes received and sent across all non-loopback interfaces.
    ///
    /// Loopback is excluded: traffic a machine sends to itself is not network
    /// I/O in the sense that matters for a resource budget, and including it
    /// would make local development look like heavy network use.
    public static func totals() -> Totals? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]

        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else {
            return nil
        }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var sawInterface = false

        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }

                if header.ifm_type == UInt8(RTM_IFINFO2),
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let interface = raw.loadUnaligned(
                        fromByteOffset: offset, as: if_msghdr2.self
                    )
                    if interface.ifm_flags & Int32(IFF_LOOPBACK) == 0 {
                        received += interface.ifm_data.ifi_ibytes
                        sent += interface.ifm_data.ifi_obytes
                        sawInterface = true
                    }
                }

                offset += messageLength
            }
        }

        return sawInterface ? Totals(received: received, sent: sent) : nil
    }

    public struct Totals: Equatable, Sendable {
        public let received: UInt64
        public let sent: UInt64
    }
}
