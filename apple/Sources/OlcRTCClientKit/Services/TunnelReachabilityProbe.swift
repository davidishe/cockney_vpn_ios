import Foundation
import Network

/// Probes the data plane from the app process. The tunnel extension is excluded
/// from its own tunnel, so a probe running there proves nothing about app traffic;
/// this one goes through the same path Safari does.
public enum TunnelReachabilityProbe {
    public struct Result: Sendable {
        public var lines: [String]
    }

    private static let probeHost = "example.com"
    private static let probeAddress = "1.1.1.1"

    public static func run() async -> Result {
        var lines: [String] = []

        let resolved = resolveIPv4(host: probeHost)
        lines.append("probe dns \(probeHost) -> [\(resolved.joined(separator: " "))]")

        lines.append(await connectLine(to: .init(probeAddress), label: probeAddress))
        if let first = resolved.first {
            lines.append(await connectLine(to: .init(first), label: "\(probeHost)/\(first)"))
        }
        lines.append(await connectLine(to: .init(probeHost), label: "\(probeHost) by name"))

        return Result(lines: lines)
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
        let outcome = await connect(to: host, port: 80, timeout: 8)
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
