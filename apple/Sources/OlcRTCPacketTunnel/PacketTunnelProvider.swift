import Darwin
import Foundation
import NetworkExtension
import OlcRTCClientKit
import Tun2SocksKit
import Tun2SocksKitC

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private enum Constants {
        static let tunnelAddress = "198.18.0.1"
        // Only used when the endpoint host is unavailable. Must differ from
        // tunnelAddress and stay out of reserved space, or iOS treats the tunnel's
        // network service as non-viable and every routed connection gets ENETDOWN.
        static let fallbackRemoteAddress = "10.255.255.254"
        // /32 keeps the tunnel point-to-point. A wider prefix makes the kernel treat
        // neighbouring addresses as on-link and try to resolve a link-layer next hop,
        // which a utun cannot do, so sends fail with EHOSTUNREACH.
        static let tunnelSubnetMask = "255.255.255.255"
        static let mapDNSAddress = "198.18.0.2"
        static let mapDNSNetwork = "198.18.0.0"
        static let mapDNSNetmask = "255.255.0.0"
        // KCP over TURN over UDP leaves little room under a 1500-byte path.
        static let mtu = 1360
    }

    private final class Tun2SocksLaunchState: @unchecked Sendable {
        private let lock = NSLock()
        private var exitCode: Int32?

        func setExit(_ code: Int32) {
            lock.lock()
            exitCode = code
            lock.unlock()
        }

        func getExit() -> Int32? {
            lock.lock()
            defer { lock.unlock() }
            return exitCode
        }
    }

    private var engine: GomobileOlcRTCEngine?
    private var tun2socksTask: Task<Void, Never>?
    private var tun2socksStatsTask: Task<Void, Never>?
    private var tun2socksLogTask: Task<Void, Never>?
    private var configFileURL: URL?
    private var tun2socksLogURL: URL?
    private var tunnelInterfaceName: String?
    private var eventTask: Task<Void, Never>?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Task {
            // Log before config parse — otherwise a missing keyHex/endpoint leaves shared.log empty.
            let proto = protocolConfiguration as? NETunnelProviderProtocol
            let persisted = proto?.providerConfiguration ?? [:]
            let startKeys = Set((options ?? [:]).keys)
            let persistedKeys = Set(persisted.keys)
            DiagnosticJournal.shared.configureSession(
                sessionId: UUID(),
                mode: "packetTunnel",
                deviceId: "pending"
            )
            log("checkpoint: extension build \(BuildInfo.summary)", level: .checkpoint)
            log(
                "checkpoint: VPN extension startTunnel appGroup=\(DiagnosticJournal.isAppGroupAvailable() ? "ok" : "MISSING") path=\(DiagnosticJournal.shared.diagnosticsDirectoryPath()) startOpts=\(startKeys.sorted().joined(separator: ",")) persisted=\(persistedKeys.sorted().joined(separator: ","))",
                level: .checkpoint
            )
            do {
                let configuration = try PacketTunnelConfiguration(
                    providerConfiguration: persisted,
                    startOptions: options
                )
                DiagnosticJournal.shared.configureSession(
                    sessionId: DiagnosticJournal.shared.currentSessionId() ?? UUID(),
                    mode: "packetTunnel",
                    deviceId: configuration.connectionProfile.clientID
                )
                try await startOlcRTC(configuration: configuration)
                log("checkpoint: WaitReady ok — applying tunnel settings", level: .checkpoint)
                try await applyNetworkSettings(configuration: configuration)
                log("checkpoint: tunnel settings applied addr=\(Constants.tunnelAddress)", level: .checkpoint)
                // utun fd from NetworkExtension is sometimes not visible for a beat.
                try await Task.sleep(nanoseconds: 300_000_000)
                await startTun2Socks(configuration: configuration)
                completionHandler(nil)
            } catch {
                log("checkpoint: VPN start failed \(error.localizedDescription)", level: .error)
                completionHandler(error)
                await stopRuntime()
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        Task {
            log("checkpoint: VPN extension stopTunnel reason=\(reason.rawValue)", level: .checkpoint)
            await stopRuntime()
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        let command = String(data: messageData, encoding: .utf8) ?? ""
        switch command {
        case "dump-logs":
            let lines = DiagnosticJournal.shared.exportDisplayLines(limit: 800)
            let header = [
                "checkpoint: tunnel-ipc dump appGroup=\(DiagnosticJournal.isAppGroupAvailable() ? "ok" : "MISSING") path=\(DiagnosticJournal.shared.diagnosticsDirectoryPath()) lines=\(lines.count)",
            ]
            let body = (header + lines).joined(separator: "\n")
            completionHandler?(Data(body.utf8))
        default:
            completionHandler?(nil)
        }
    }

    private func startOlcRTC(configuration: PacketTunnelConfiguration) async throws {
        let profile = configuration.connectionProfile
        let startOptions = OlcRTCStartOptions(profile: profile)
        let engine = GomobileOlcRTCEngine()
        self.engine = engine
        observeEngine(engine)

        log(
            "checkpoint: MobileStart carrier=\(startOptions.carrierName) transport=\(startOptions.transportName) room=\(startOptions.roomID) socks=\(startOptions.socksPort) endpoint=\(startOptions.turnEndpoint.isEmpty ? "missing" : startOptions.turnEndpoint) jwt=\(startOptions.accessToken.isEmpty ? "no" : "yes") carrierAuth=\(startOptions.carrierAuthToken.isEmpty ? "no" : "yes")",
            level: .checkpoint
        )
        try await engine.start(options: startOptions)
        try await engine.waitReady(
            timeoutMillis: max(
                configuration.startTimeoutMillis,
                ConnectionProfile.defaultStartTimeoutMillis
            )
        )
    }

    private func observeEngine(_ engine: GomobileOlcRTCEngine) {
        eventTask?.cancel()
        eventTask = Task {
            for await message in engine.events {
                log(message, level: message.hasPrefix("checkpoint:") || message.hasPrefix("socks:") ? .checkpoint : .info)
            }
        }
    }

    private func applyNetworkSettings(configuration: PacketTunnelConfiguration) async throws {
        let remoteAddress = remoteEndpointAddress(configuration: configuration)
        log("checkpoint: tunnel remote address \(remoteAddress)", level: .checkpoint)
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)
        settings.mtu = Constants.mtu as NSNumber

        let ipv4Settings = NEIPv4Settings(
            addresses: [Constants.tunnelAddress],
            subnetMasks: [Constants.tunnelSubnetMask]
        )
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        // Loopback is deliberately absent: it never routes through a tunnel, and
        // excluding it points the SOCKS listener and the resolver at the physical
        // interface instead.
        var excluded: [NEIPv4Route] = []
        // Keep Cockney control-plane HTTPS off-tunnel (subscription + log upload).
        let controlHosts = controlPlaneHosts(from: configuration)
        for host in controlHosts {
            for ip in await resolveIPv4Addresses(host: host) {
                excluded.append(NEIPv4Route(destinationAddress: ip, subnetMask: "255.255.255.255"))
                log("checkpoint: exclude control-plane route \(host) → \(ip)", level: .checkpoint)
            }
        }
        let transportName = configuration.connectionProfile.transport.rawValue
        if transportName == Transport.turnrelay.rawValue {
            // turnrelay binds TURN/UDP via IP_BOUND_IF (MobileSetProtector); no media bypass.
            log("checkpoint: turnrelay routing — default route + control-plane exclude only", level: .checkpoint)
        } else {
            // Keep VK Calls / olcRTC media off-tunnel for vp8channel. If these go into TUN,
            // ICE/WebRTC self-eats (sendto: can't assign requested address).
            for route in carrierMediaBypassRoutes() {
                excluded.append(route)
                log(
                    "checkpoint: exclude carrier-media route \(route.destinationAddress)/\(route.destinationSubnetMask ?? "?")",
                    level: .checkpoint
                )
            }
            for host in carrierMediaHosts() {
                for ip in await resolveIPv4Addresses(host: host) {
                    excluded.append(NEIPv4Route(destinationAddress: ip, subnetMask: "255.255.255.255"))
                    log("checkpoint: exclude carrier-media host \(host) → \(ip)", level: .checkpoint)
                }
            }
        }
        ipv4Settings.excludedRoutes = excluded
        settings.ipv4Settings = ipv4Settings

        let dnsSettings = NEDNSSettings(servers: [Constants.mapDNSAddress])
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setTunnelNetworkSettings(settings) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    private func controlPlaneHosts(from configuration: PacketTunnelConfiguration) -> [String] {
        var hosts: [String] = ["cockney.tokenova.space"]
        if let raw = configuration.connectionProfile.subscription?.sourceURL,
           let url = URL(string: raw),
           let host = url.host,
           !host.isEmpty {
            hosts.append(host)
        }
        return Array(Set(hosts))
    }

    /// Hard-coded media/egress prefixes seen in production ICE (NL agent + VK TURN).
    private func carrierMediaBypassRoutes() -> [NEIPv4Route] {
        [
            // NL olcRTC agent (host candidates in ICE)
            NEIPv4Route(destinationAddress: "195.133.81.165", subnetMask: "255.255.255.255"),
            // VK TURN / relay pool observed in client logs
            NEIPv4Route(destinationAddress: "90.156.236.0", subnetMask: "255.255.255.0"),
        ]
    }

    private func carrierMediaHosts() -> [String] {
        [
            "api.vk.com",
            "login.vk.com",
            "queuev4.vk.com",
            "stun.vk.com",
            "turn.vk.com",
        ]
    }

    private func resolveIPv4Addresses(host: String) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo(
                    ai_flags: AI_ADDRCONFIG,
                    ai_family: AF_INET,
                    ai_socktype: SOCK_STREAM,
                    ai_protocol: 0,
                    ai_addrlen: 0,
                    ai_canonname: nil,
                    ai_addr: nil,
                    ai_next: nil
                )
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, nil, &hints, &result)
                defer {
                    if let result {
                        freeaddrinfo(result)
                    }
                }
                guard status == 0, let first = result else {
                    continuation.resume(returning: [])
                    return
                }
                var addresses: [String] = []
                var pointer: UnsafeMutablePointer<addrinfo>? = first
                while let info = pointer {
                    if info.pointee.ai_family == AF_INET,
                       let addr = info.pointee.ai_addr {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(
                            addr,
                            socklen_t(info.pointee.ai_addrlen),
                            &hostname,
                            socklen_t(hostname.count),
                            nil,
                            0,
                            NI_NUMERICHOST
                        ) == 0 {
                            addresses.append(String(cString: hostname))
                        }
                    }
                    pointer = info.pointee.ai_next
                }
                continuation.resume(returning: Array(Set(addresses)))
            }
        }
    }

    /// Tun2SocksKit picks the first `utun_control` descriptor it finds by scanning fds.
    /// When the extension holds more than one, it can bind to an interface the system
    /// never routes packets to, which looks exactly like a dead tunnel.
    private func logUtunDescriptors() {
        var ctlInfo = ctl_info()
        withUnsafeMutablePointer(to: &ctlInfo.ctl_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: $0.pointee)) {
                _ = strcpy($0, "com.apple.net.utun_control")
            }
        }

        var found: [String] = []
        for fd: Int32 in 0...1024 {
            var addr = sockaddr_ctl()
            var ret: Int32 = -1
            var len = socklen_t(MemoryLayout.size(ofValue: addr))
            withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    ret = getpeername(fd, $0, &len)
                }
            }
            if ret != 0 || addr.sc_family != AF_SYSTEM {
                continue
            }
            if ctlInfo.ctl_id == 0, ioctl(fd, CTLIOCGINFO, &ctlInfo) != 0 {
                continue
            }
            guard addr.sc_id == ctlInfo.ctl_id else { continue }

            var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            var nameLen = socklen_t(IFNAMSIZ)
            // SYSPROTO_CONTROL / UTUN_OPT_IFNAME are not surfaced by the iOS Darwin module.
            let named = getsockopt(fd, 2, 2, &name, &nameLen) == 0
            found.append("fd=\(fd)/\(named ? String(cString: name) : "?")")
        }

        log(
            "checkpoint: utun descriptors count=\(found.count) [\(found.joined(separator: " "))]",
            level: .checkpoint
        )
    }

    /// iOS builds the tunnel's network service around this address, so it has to look
    /// like a real peer. The turnrelay endpoint is exactly that.
    private func remoteEndpointAddress(configuration: PacketTunnelConfiguration) -> String {
        let endpoint = configuration.turnEndpoint.trimmingCharacters(in: .whitespaces)
        let host = endpoint.contains(":")
            ? String(endpoint.split(separator: ":").first ?? "")
            : endpoint
        var addr = in_addr()
        guard !host.isEmpty, inet_pton(AF_INET, host, &addr) == 1 else {
            return Constants.fallbackRemoteAddress
        }
        return host
    }

    /// The descriptor we hand to tun2socks is only useful if the system actually
    /// configured that same interface with the tunnel address.
    private func logTunnelInterfaces() {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else {
            log("checkpoint: getifaddrs failed", level: .checkpoint)
            return
        }
        defer { freeifaddrs(head) }

        var entries: [String] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("utun"), let sa = ptr.pointee.ifa_addr else { continue }
            guard sa.pointee.sa_family == UInt8(AF_INET) || sa.pointee.sa_family == UInt8(AF_INET6) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                sa,
                socklen_t(sa.pointee.sa_len),
                &host,
                socklen_t(NI_MAXHOST),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }

            // connect() returns ENETDOWN when the interface is not both UP and RUNNING.
            var flags: [String] = []
            if ptr.pointee.ifa_flags & UInt32(IFF_UP) == 0 { flags.append("!up") }
            if ptr.pointee.ifa_flags & UInt32(IFF_RUNNING) == 0 { flags.append("!running") }
            let suffix = flags.isEmpty ? "" : "(\(flags.joined(separator: ",")))"
            entries.append("\(name)=\(String(cString: host))\(suffix)")
        }

        log("checkpoint: utun interfaces [\(entries.joined(separator: " "))]", level: .checkpoint)
    }

    /// tun2socks only counts what it managed to read off the descriptor. The kernel's
    /// own counters for the tunnel interface say whether the packets were handed to it
    /// in the first place, which separates a routing problem from a read problem.
    private func tunnelInterfaceCounters() -> String {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return "if=?" }
        defer { freeifaddrs(head) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("utun"),
                  ptr.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let raw = ptr.pointee.ifa_data
            else { continue }
            guard tunnelInterfaceName == nil || tunnelInterfaceName == name else { continue }

            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            return "if=\(name) inPkts=\(data.ifi_ipackets) inBytes=\(data.ifi_ibytes)"
                + " outPkts=\(data.ifi_opackets) outBytes=\(data.ifi_obytes)"
                + " drops=\(data.ifi_iqdrops) errs=\(data.ifi_ierrors)/\(data.ifi_oerrors)"
        }
        return "if=\(tunnelInterfaceName ?? "?") missing"
    }

    /// Resolved once from the tunnel address so the counters follow a single interface
    /// even when other utun devices come and go.
    private func resolveTunnelInterfaceName() {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return }
        defer { freeifaddrs(head) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("utun"),
                  let sa = ptr.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                sa,
                socklen_t(sa.pointee.sa_len),
                &host,
                socklen_t(NI_MAXHOST),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }

            if String(cString: host) == Constants.tunnelAddress {
                tunnelInterfaceName = name
                return
            }
        }
    }

    private func startTun2Socks(configuration: PacketTunnelConfiguration) async {
        logUtunDescriptors()
        logTunnelInterfaces()
        resolveTunnelInterfaceName()
        let socksPort = await engine?.activeSocksPort ?? configuration.socksPort
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("olcrtc-tun2socks.log")
        try? FileManager.default.removeItem(at: logURL)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        tun2socksLogURL = logURL
        let configText = tun2socksConfiguration(
            socksPort: socksPort,
            debugLogging: configuration.debugLogging,
            logPath: logURL.path
        )
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("olcrtc-tun2socks.yml")
        do {
            try configText.write(to: fileURL, atomically: true, encoding: .utf8)
            configFileURL = fileURL
        } catch {
            log("checkpoint: tun2socks config write failed \(error.localizedDescription)", level: .error)
        }
        log("checkpoint: tun2socks config socks=127.0.0.1:\(socksPort)", level: .checkpoint)

        // Socks5Tunnel.run returns -1 immediately if the utun fd is not visible yet.
        // Do NOT fail the whole VPN for that — keep control-plane Connected and surface the code.
        var lastCode: Int32 = -1
        for attempt in 1...8 {
            if attempt > 1 {
                Socks5Tunnel.quit()
                tun2socksTask = nil
                try? await Task.sleep(nanoseconds: 200_000_000)
            }

            let state = Tun2SocksLaunchState()
            let config: Socks5Tunnel.Config = .string(content: configText)
            tun2socksTask = Task.detached(priority: .userInitiated) {
                let code = Socks5Tunnel.run(withConfig: config)
                state.setExit(code)
            }

            var earlyExit: Int32?
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if let code = state.getExit() {
                    earlyExit = code
                    break
                }
            }

            if earlyExit == nil {
                log("checkpoint: tun2socks running attempt=\(attempt)", level: .checkpoint)
                startTun2SocksStatsProbe()
                startTun2SocksLogProbe()
                Task.detached(priority: .utility) { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    self?.logDefaultRoutes()
                    self?.runRoutingProbe()
                }
                return
            }

            lastCode = earlyExit!
            log(
                "checkpoint: tun2socks exited early code=\(lastCode) attempt=\(attempt)",
                level: .error
            )
        }

        log(
            "checkpoint: tun2socks FAILED code=\(lastCode) — VPN stays up without packet bridge",
            level: .error
        )
    }

    private func startTun2SocksStatsProbe() {
        tun2socksStatsTask?.cancel()
        tun2socksStatsTask = Task { [weak self] in
            while !Task.isCancelled {
                let stats = Socks5Tunnel.stats
                let counters = self?.tunnelInterfaceCounters() ?? "if=?"
                self?.log(
                    "checkpoint: tun2socks stats upPkts=\(stats.up.packets) upBytes=\(stats.up.bytes) downPkts=\(stats.down.packets) downBytes=\(stats.down.bytes) \(counters)",
                    level: .checkpoint
                )
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// The extension's own sockets are excluded from its own tunnel, so probing from
    /// here says nothing about app traffic. Read the kernel table instead and report
    /// which interface owns the IPv4 default route.
    private func logDefaultRoutes() {
        // net/route.h is not exposed to Swift on iOS; mirror the kernel layout.
        struct RTMetrics {
            var locks: UInt32 = 0, mtu: UInt32 = 0, hopcount: UInt32 = 0, expire: Int32 = 0
            var recvpipe: UInt32 = 0, sendpipe: UInt32 = 0, ssthresh: UInt32 = 0
            var rtt: UInt32 = 0, rttvar: UInt32 = 0, pksent: UInt32 = 0, state: UInt32 = 0
            var filler0: UInt32 = 0, filler1: UInt32 = 0, filler2: UInt32 = 0
        }
        struct RTMsgHdr {
            var msglen: UInt16 = 0, version: UInt8 = 0, type: UInt8 = 0, index: UInt16 = 0
            var flags: Int32 = 0, addrs: Int32 = 0, pid: Int32 = 0, seq: Int32 = 0
            var errno: Int32 = 0, use: Int32 = 0, inits: UInt32 = 0
            var rmx = RTMetrics()
        }
        let rtfUp: Int32 = 0x1
        let rtaDst: Int32 = 0x1
        let rtaGateway: Int32 = 0x2

        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0]
        var needed = 0
        guard sysctl(&mib, 6, nil, &needed, nil, 0) == 0, needed > 0 else {
            log("checkpoint: route table size query failed errno=\(errno)", level: .checkpoint)
            return
        }

        var buffer = [UInt8](repeating: 0, count: needed)
        guard sysctl(&mib, 6, &buffer, &needed, nil, 0) == 0 else {
            log("checkpoint: route table dump failed errno=\(errno)", level: .checkpoint)
            return
        }

        let headerSize = MemoryLayout<RTMsgHdr>.size
        var defaults: [String] = []
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + headerSize <= needed {
                let header = base.advanced(by: offset)
                    .loadUnaligned(as: RTMsgHdr.self)
                let length = Int(header.msglen)
                guard length >= headerSize, offset + length <= needed else { break }
                defer { offset += length }

                guard header.flags & rtfUp != 0, header.addrs & rtaDst != 0 else { continue }

                var cursor = offset + headerSize
                let dst = base.advanced(by: cursor).loadUnaligned(as: sockaddr.self)
                guard dst.sa_family == UInt8(AF_INET) else { continue }
                let dstIn = base.advanced(by: cursor).loadUnaligned(as: sockaddr_in.self)
                guard dstIn.sin_addr.s_addr == 0 else { continue }

                cursor += (max(Int(dst.sa_len), 4) + 3) & ~3
                var gateway = "?"
                if header.addrs & rtaGateway != 0, cursor + MemoryLayout<sockaddr>.size <= needed {
                    let gw = base.advanced(by: cursor).loadUnaligned(as: sockaddr.self)
                    if gw.sa_family == UInt8(AF_INET) {
                        var addr = base.advanced(by: cursor)
                            .loadUnaligned(as: sockaddr_in.self).sin_addr
                        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        if inet_ntop(AF_INET, &addr, &text, socklen_t(INET_ADDRSTRLEN)) != nil {
                            gateway = String(cString: text)
                        }
                    } else if gw.sa_family == UInt8(AF_LINK) {
                        gateway = "link"
                    }
                }

                var ifName = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                let name = if_indextoname(UInt32(header.index), &ifName) != nil
                    ? String(cString: ifName)
                    : "idx\(header.index)"
                defaults.append("\(name)->\(gateway)")
            }
        }

        log(
            "checkpoint: ipv4 default routes hdr=\(headerSize) [\(defaults.joined(separator: " "))]",
            level: .checkpoint
        )
    }

    private func runRoutingProbe() {
        let probeIP = "1.1.1.1"
        let probePort: UInt16 = 80

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log("checkpoint: routing probe socket failed errno=\(errno)", level: .checkpoint)
            return
        }
        defer { close(fd) }

        var flags = fcntl(fd, F_GETFL, 0)
        flags |= O_NONBLOCK
        _ = fcntl(fd, F_SETFL, flags)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = probePort.bigEndian
        inet_pton(AF_INET, probeIP, &addr.sin_addr)

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 {
            log("checkpoint: routing probe \(probeIP):\(probePort) connected immediately", level: .checkpoint)
            return
        }
        guard errno == EINPROGRESS else {
            log("checkpoint: routing probe connect failed errno=\(errno)", level: .checkpoint)
            return
        }

        var writeSet = fd_set()
        withUnsafeMutablePointer(to: &writeSet) { bzero($0, MemoryLayout<fd_set>.size) }
        __darwin_fd_set(fd, &writeSet)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        let ready = select(fd + 1, nil, &writeSet, nil, &timeout)

        if ready == 0 {
            log("checkpoint: routing probe \(probeIP):\(probePort) TIMED OUT", level: .checkpoint)
            return
        }

        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
        log(
            "checkpoint: routing probe \(probeIP):\(probePort) \(soError == 0 ? "connected" : "failed err=\(soError)")",
            level: .checkpoint
        )
    }

    private func startTun2SocksLogProbe() {
        guard let logURL = tun2socksLogURL else { return }
        tun2socksLogTask?.cancel()
        tun2socksLogTask = Task { [weak self] in
            // Debug level is per-packet chatty; enough lines to diagnose, not to flood.
            let maxLines = 300
            var forwarded = 0
            var offset: UInt64 = 0
            var reportedSilence = false

            while !Task.isCancelled, forwarded < maxLines {
                if let handle = try? FileHandle(forReadingFrom: logURL) {
                    try? handle.seek(toOffset: offset)
                    let data = (try? handle.readToEnd()) ?? Data()
                    offset += UInt64(data.count)
                    try? handle.close()
                    if let text = String(data: data, encoding: .utf8) {
                        for line in text.split(separator: "\n") where !line.isEmpty {
                            guard forwarded < maxLines else { break }
                            forwarded += 1
                            self?.log("tun2socks: \(line)", level: .info)
                        }
                    }
                }
                if offset == 0, !reportedSilence {
                    reportedSilence = true
                    self?.log("checkpoint: tun2socks log still empty", level: .checkpoint)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopRuntime() async {
        eventTask?.cancel()
        eventTask = nil
        tun2socksStatsTask?.cancel()
        tun2socksStatsTask = nil
        tun2socksLogTask?.cancel()
        tun2socksLogTask = nil
        tun2socksTask?.cancel()
        tun2socksTask = nil
        Socks5Tunnel.quit()

        if let configFileURL {
            try? FileManager.default.removeItem(at: configFileURL)
            self.configFileURL = nil
        }

        if let tun2socksLogURL {
            try? FileManager.default.removeItem(at: tun2socksLogURL)
            self.tun2socksLogURL = nil
        }

        await engine?.stop()
        engine = nil
        DiagnosticJournal.shared.clearSession()
    }

    private func log(_ message: String, level: DiagnosticLogLevel) {
        DiagnosticJournal.shared.append(message, level: level)
    }

    private func tun2socksConfiguration(
        socksPort: Int,
        debugLogging: Bool,
        logPath: String
    ) -> String {
        """
        tunnel:
          mtu: \(Constants.mtu)
          ipv4: \(Constants.tunnelAddress)
        socks5:
          port: \(socksPort)
          address: 127.0.0.1
          udp: 'tcp'
        mapdns:
          address: \(Constants.mapDNSAddress)
          port: 53
          network: \(Constants.mapDNSNetwork)
          netmask: \(Constants.mapDNSNetmask)
          cache-size: 10000
        misc:
          task-stack-size: 24576
          tcp-buffer-size: 4096
          connect-timeout: 10000
          tcp-read-write-timeout: 300000
          udp-read-write-timeout: 60000
          log-file: \(logPath)
          log-level: debug
          limit-nofile: 65535
        """
    }
}
