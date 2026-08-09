import Foundation
import Network

/// Probes the data plane from the app process. The tunnel extension is excluded
/// from its own tunnel, so a probe running there proves nothing about app traffic;
/// this one goes through the same path Safari does.
public enum TunnelReachabilityProbe {
    private static let probeHost = "example.com"
    private static let probeAddress = "1.1.1.1"
    private static let mapDNSAddress = "198.18.0.2"

    /// Streams each result as it lands so a journal uploaded mid-probe still carries
    /// the steps that already finished.
    public static func stream() -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                continuation.yield(await pathSnapshot())
                continuation.yield(routeLine(to: probeAddress))
                continuation.yield(routeLine(to: mapDNSAddress))
                continuation.yield(directDNSLine())

                let resolved = resolveIPv4(host: probeHost)
                continuation.yield("probe dns \(probeHost) -> [\(resolved.joined(separator: " "))]")

                continuation.yield(await connectLine(to: .init(probeAddress), label: probeAddress))
                if let first = resolved.first {
                    continuation.yield(await connectLine(to: .init(first), label: "\(probeHost)/\(first)"))
                }
                continuation.yield(await connectLine(to: .init(probeHost), label: "\(probeHost) by name"))
                continuation.finish()
            }
        }
    }

    /// ENETDOWN means the system found no viable path, so ask the system why.
    private static func pathSnapshot() async -> String {
        let monitor = NWPathMonitor()
        let box = OutcomeBox()

        let description: String = await withCheckedContinuation { continuation in
            let finish: @Sendable (String) -> Void = { text in
                guard box.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: text)
            }

            monitor.pathUpdateHandler = { path in
                let interfaces = path.availableInterfaces
                    .map { "\($0.name)/\($0.type)" }
                    .joined(separator: " ")
                var text = "status=\(path.status)"
                if #available(iOS 14.2, macOS 11.0, *) {
                    text += " unsatisfiedReason=\(path.unsatisfiedReason)"
                }
                text += " ipv4=\(path.supportsIPv4) ipv6=\(path.supportsIPv6)"
                text += " interfaces=[\(interfaces)]"
                finish(text)
            }
            monitor.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                finish("status=unknown (no path update)")
            }
        }
        return "probe path \(description)"
    }

    /// Connecting a UDP socket performs a route lookup without sending anything, so
    /// the chosen source address names the interface the kernel picked.
    private static func routeLine(to address: String) -> String {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return "probe route \(address) socket errno=\(errno)" }
        defer { close(fd) }

        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = UInt16(53).bigEndian
        guard inet_pton(AF_INET, address, &remote.sin_addr) == 1 else {
            return "probe route \(address) bad address"
        }

        var status: Int32 = -1
        withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                status = Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if status != 0 {
            let code = errno
            return "probe route \(address) errno=\(code) (\(String(cString: strerror(code))))"
        }

        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &length)
            }
        }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &local.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))

        // Lookup succeeding says nothing about delivery: a rejecting route only
        // shows itself once something is actually transmitted.
        var payload: UInt8 = 0
        let sent = Darwin.send(fd, &payload, 1, 0)
        let delivery = sent < 0
            ? "send errno=\(errno) (\(String(cString: strerror(errno))))"
            : "send=ok"
        return "probe route \(address) src=\(String(cString: text)) \(delivery)"
    }

    /// The system resolver hides what came back. Query the tunnel's DNS directly to
    /// see the address mapped DNS actually hands out.
    private static func directDNSLine() -> String {
        let query: [UInt8] = dnsQuery(for: probeHost)
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return "probe dns-direct socket errno=\(errno)" }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = UInt16(53).bigEndian
        _ = inet_pton(AF_INET, mapDNSAddress, &remote.sin_addr)

        var sent = -1
        withUnsafePointer(to: &remote) { addr in
            addr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                sent = query.withUnsafeBytes {
                    sendto(fd, $0.baseAddress, query.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 {
            let code = errno
            return "probe dns-direct send errno=\(code) (\(String(cString: strerror(code))))"
        }

        var buffer = [UInt8](repeating: 0, count: 512)
        let received = recv(fd, &buffer, buffer.count, 0)
        if received < 0 {
            let code = errno
            return "probe dns-direct recv errno=\(code) (\(String(cString: strerror(code))))"
        }

        let answers = dnsAnswers(in: Array(buffer.prefix(received)))
        return "probe dns-direct \(probeHost) bytes=\(received) answers=[\(answers.joined(separator: " "))]"
    }

    private static func dnsQuery(for host: String) -> [UInt8] {
        var packet: [UInt8] = [0x2b, 0xad, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in host.split(separator: ".") {
            packet.append(UInt8(label.utf8.count))
            packet.append(contentsOf: Array(label.utf8))
        }
        packet.append(contentsOf: [0, 0, 1, 0, 1])
        return packet
    }

    /// Minimal A-record scan: walk past the question, then read each answer's rdata.
    private static func dnsAnswers(in packet: [UInt8]) -> [String] {
        guard packet.count > 12 else { return [] }
        let answerCount = Int(packet[6]) << 8 | Int(packet[7])
        guard answerCount > 0 else { return [] }

        var cursor = 12
        while cursor < packet.count, packet[cursor] != 0 {
            cursor += Int(packet[cursor]) + 1
        }
        cursor += 5

        var out: [String] = []
        for _ in 0..<answerCount {
            guard cursor + 12 <= packet.count else { break }
            cursor += (packet[cursor] & 0xC0) == 0xC0 ? 2 : 1
            let type = Int(packet[cursor]) << 8 | Int(packet[cursor + 1])
            let rdLength = Int(packet[cursor + 8]) << 8 | Int(packet[cursor + 9])
            cursor += 10
            guard cursor + rdLength <= packet.count else { break }
            if type == 1, rdLength == 4 {
                out.append(packet[cursor..<(cursor + 4)].map(String.init).joined(separator: "."))
            } else {
                out.append("type\(type)")
            }
            cursor += rdLength
        }
        return out
    }

    private static func resolveIPv4(host: String) -> [String] {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &head) == 0, let first = head else {
            return []
        }
        defer { freeaddrinfo(head) }

        var out: [String] = []
        for ptr in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let sa = ptr.pointee.ai_addr else { continue }
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                sa,
                ptr.pointee.ai_addrlen,
                &text,
                socklen_t(NI_MAXHOST),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            out.append(String(cString: text))
        }
        return out
    }

    private static func connectLine(to host: NWEndpoint.Host, label: String) async -> String {
        let start = Date()
        let outcome = await connect(to: host, port: 80, timeout: 5)
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        return "probe tcp \(label):80 \(outcome) in \(elapsed)ms"
    }

    private static func connect(to host: NWEndpoint.Host, port: UInt16, timeout: TimeInterval) async -> String {
        let connection = NWConnection(host: host, port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let box = OutcomeBox()

        return await withCheckedContinuation { continuation in
            let finish: @Sendable (String) -> Void = { outcome in
                guard box.claim() else { return }
                connection.cancel()
                continuation.resume(returning: outcome)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish("connected")
                case let .failed(error):
                    finish("failed(\(error.debugDescription))")
                case let .waiting(error):
                    // .waiting means no viable path — the interesting failure mode here.
                    finish("waiting(\(error.debugDescription))")
                case .cancelled:
                    finish("cancelled")
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish("timeout")
            }
        }
    }
}

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
