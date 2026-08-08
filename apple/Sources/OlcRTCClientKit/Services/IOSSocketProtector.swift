import Foundation

#if canImport(Mobile) && canImport(Darwin)
import Darwin
import Mobile

/// Binds olcRTC sockets to a physical network interface so Packet Tunnel
/// default routes cannot invalidate ICE/TURN UDP source addresses
/// (`sendto: can't assign requested address`).
public final class IOSSocketProtector: NSObject, MobileSocketProtectorProtocol {
    private let ifindex: UInt32
    private let interfaceName: String

    public var boundInterfaceName: String { interfaceName }
    public var boundInterfaceIndex: UInt32 { ifindex }

    public init?(interfaceName preferred: String? = nil) {
        guard let resolved = Self.resolvePhysicalInterface(preferred: preferred) else {
            return nil
        }
        self.interfaceName = resolved.name
        self.ifindex = resolved.index
        super.init()
    }

    public func protect(_ fd: Int) -> Bool {
        guard fd >= 0, ifindex != 0 else { return false }
        var idx = ifindex
        let rc = withUnsafePointer(to: &idx) { ptr in
            setsockopt(
                Int32(fd),
                IPPROTO_IP,
                IP_BOUND_IF,
                ptr,
                socklen_t(MemoryLayout<UInt32>.size)
            )
        }
        if rc == 0 {
            return true
        }
        // Dual-stack / IPv6 listeners use IPV6_BOUND_IF.
        var idx6 = ifindex
        let rc6 = withUnsafePointer(to: &idx6) { ptr in
            setsockopt(
                Int32(fd),
                IPPROTO_IPV6,
                IPV6_BOUND_IF,
                ptr,
                socklen_t(MemoryLayout<UInt32>.size)
            )
        }
        return rc6 == 0
    }

    private static func resolvePhysicalInterface(preferred: String?) -> (name: String, index: UInt32)? {
        if let preferred, !preferred.isEmpty {
            let idx = if_nametoindex(preferred)
            if idx != 0 {
                return (preferred, idx)
            }
        }

        let candidates = [
            "en0", // Wi-Fi
            "en1",
            "pdp_ip0", // cellular
            "pdp_ip1",
        ]
        for name in candidates {
            let idx = if_nametoindex(name)
            if idx != 0 {
                return (name, idx)
            }
        }

        // Last resort: first non-loopback / non-utun interface with an IPv4 address.
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let name = String(cString: current.pointee.ifa_name)
            if name.hasPrefix("lo") || name.hasPrefix("utun") || name.hasPrefix("awdl") {
                continue
            }
            guard let addr = current.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else {
                continue
            }
            let idx = if_nametoindex(name)
            if idx != 0 {
                return (name, idx)
            }
        }
        return nil
    }
}
#endif
