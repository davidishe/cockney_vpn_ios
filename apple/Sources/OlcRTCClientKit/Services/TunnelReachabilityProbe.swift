import Foundation
import Network

/// Probes the data plane from the app process. The tunnel extension is excluded
/// from its own tunnel, so a probe running there proves nothing about app traffic;
/// this one goes through the same path Safari does.
public enum TunnelReachabilityProbe {
    private static let probeHost = "example.com"
    private static let probeAddress = "1.1.1.1"

    /// Streams each result as it lands so a journal uploaded mid-probe still carries
    /// the steps that already finished.
    public static func stream() -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                continuation.yield(await pathSnapshot())

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
