import Foundation
import Network

#if canImport(Mobile) && canImport(Darwin)
import Darwin
import Mobile

/// Binds olcRTC sockets to the *active* physical interface so Packet Tunnel
/// default routes cannot invalidate TURN/UDP source addresses
/// (`sendto: can't assign requested address`).
///
/// A static preference for `en0` breaks LTE-only sessions: Wi-Fi still exists
/// as an interface name while the working path is `pdp_ip*`. Android's
/// `VpnService.protect(fd)` picks the live interface for us; on iOS we must.
public final class IOSSocketProtector: NSObject, MobileSocketProtectorProtocol {
    private let ifindex: UInt32
    private let interfaceName: String
    public let selectionSummary: String

    public var boundInterfaceName: String { interfaceName }
    public var boundInterfaceIndex: UInt32 { ifindex }

    public init?(interfaceName preferred: String? = nil) {
        guard let resolved = Self.resolvePhysicalInterface(preferred: preferred) else {
            return nil
        }
        self.interfaceName = resolved.name
        self.ifindex = resolved.index
        self.selectionSummary = resolved.summary
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
        let errno4 = errno
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
        if rc6 == 0 {
            return true
        }
        // Best-effort: protect is called from Go's Control hook with no logger.
        // errno surfaces in the engine checkpoint when selection itself fails;
        // bind failures here usually mean the path flipped mid-session.
        _ = errno4
        return false
    }

    private struct ResolvedInterface {
        let name: String
        let index: UInt32
        let summary: String
    }

    private static func resolvePhysicalInterface(preferred: String?) -> ResolvedInterface? {
        if let preferred, !preferred.isEmpty {
            if let live = liveInterface(named: preferred) {
                return ResolvedInterface(
                    name: live.name,
                    index: live.index,
                    summary: "preferred=\(preferred) up"
                )
            }
        }

        let path = currentPathSnapshot()
        let pathNames = path.interfaces.map(\.name)
        let pathKinds = path.interfaces.map { "\($0.name)/\($0.kind)" }.joined(separator: " ")

        // Prefer interfaces that the system currently uses for the satisfied path.
        for iface in path.interfaces {
            if let live = liveInterface(named: iface.name), isPhysical(live.name) {
                return ResolvedInterface(
                    name: live.name,
                    index: live.index,
                    summary: "path=\(path.status) uses=\(iface.kind) if=\(live.name) candidates=[\(pathKinds)]"
                )
            }
        }

        // Path may list only utun while cellular/wifi are still up underneath.
        let orderedFallbacks: [String]
        if path.usesCellular, !path.usesWifi {
            orderedFallbacks = ["pdp_ip0", "pdp_ip1", "pdp_ip2", "en0", "en1"]
        } else if path.usesWifi {
            orderedFallbacks = ["en0", "en1", "pdp_ip0", "pdp_ip1"]
        } else {
            orderedFallbacks = ["en0", "en1", "pdp_ip0", "pdp_ip1", "pdp_ip2"]
        }

        for name in orderedFallbacks {
            if let live = liveInterface(named: name) {
                return ResolvedInterface(
                    name: live.name,
                    index: live.index,
                    summary: "fallback path=\(path.status) cellular=\(path.usesCellular) wifi=\(path.usesWifi) if=\(live.name) pathIf=[\(pathKinds.isEmpty ? pathNames.joined(separator: " ") : pathKinds)]"
                )
            }
        }

        if let any = firstLivePhysicalIPv4() {
            return ResolvedInterface(
                name: any.name,
                index: any.index,
                summary: "last-resort if=\(any.name) path=\(path.status)"
            )
        }
        return nil
    }

    private struct PathSnapshot {
        var status: String
        var usesWifi: Bool
        var usesCellular: Bool
        var interfaces: [(name: String, kind: String)]
    }

    private static func currentPathSnapshot() -> PathSnapshot {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "olcrtc.socket-protector.path")
        let lock = NSLock()
        var snapshot: PathSnapshot?
        let group = DispatchGroup()
        group.enter()
        monitor.pathUpdateHandler = { path in
            lock.lock()
            defer { lock.unlock() }
            guard snapshot == nil else { return }
            snapshot = PathSnapshot(
                status: String(describing: path.status),
                usesWifi: path.usesInterfaceType(.wifi),
                usesCellular: path.usesInterfaceType(.cellular),
                interfaces: path.availableInterfaces.map { iface in
                    (iface.name, String(describing: iface.type))
                }
            )
            group.leave()
        }
        monitor.start(queue: queue)
        // Path callbacks are usually immediate; keep a short ceiling for cold starts.
        _ = group.wait(timeout: .now() + 0.4)
        monitor.cancel()
        lock.lock()
        let result = snapshot
        lock.unlock()
        return result ?? PathSnapshot(status: "unknown", usesWifi: false, usesCellular: false, interfaces: [])
    }

    private struct LiveInterface {
        let name: String
        let index: UInt32
    }

    private static func liveInterface(named name: String) -> LiveInterface? {
        let idx = if_nametoindex(name)
        guard idx != 0 else { return nil }
        guard interfaceIsUpAndRunning(name) else { return nil }
        return LiveInterface(name: name, index: idx)
    }

    private static func interfaceIsUpAndRunning(_ name: String) -> Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else {
            // If we cannot read flags, fall back to "name exists".
            return if_nametoindex(name) != 0
        }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let ifName = String(cString: current.pointee.ifa_name)
            guard ifName == name else { continue }
            let flags = current.pointee.ifa_flags
            let up = (flags & UInt32(IFF_UP)) != 0
            let running = (flags & UInt32(IFF_RUNNING)) != 0
            // Cellular sometimes reports UP without RUNNING briefly; accept UP alone
            // only when an address is present on this entry.
            if up && running { return true }
            if up, let addr = current.pointee.ifa_addr {
                let family = addr.pointee.sa_family
                if family == sa_family_t(AF_INET) || family == sa_family_t(AF_INET6) {
                    return true
                }
            }
        }
        return false
    }

    private static func isPhysical(_ name: String) -> Bool {
        !(name.hasPrefix("lo")
            || name.hasPrefix("utun")
            || name.hasPrefix("awdl")
            || name.hasPrefix("llw")
            || name.hasPrefix("ipsec"))
    }

    private static func firstLivePhysicalIPv4() -> LiveInterface? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let name = String(cString: current.pointee.ifa_name)
            guard isPhysical(name) else { continue }
            guard let addr = current.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else {
                continue
            }
            let flags = current.pointee.ifa_flags
            guard (flags & UInt32(IFF_UP)) != 0 else { continue }
            let idx = if_nametoindex(name)
            if idx != 0 {
                return LiveInterface(name: name, index: idx)
            }
        }
        return nil
    }
}
#endif
