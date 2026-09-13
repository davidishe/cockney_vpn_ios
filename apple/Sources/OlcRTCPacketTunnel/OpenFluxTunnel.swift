import Darwin
import Foundation
import Mobile
import Network
import NetworkExtension
import OlcRTCClientKit

/// Experimental OpenFlux mode: device IPv4 packets go to the Go core as-is and
/// travel through a public Yandex Docs document to the OpenFlux exit node on NL.
///
/// Everything here exists to find out why the channel loses traffic, so both
/// sides of the bridge are counted: what iOS handed us, what the Go core took,
/// what came back and what iOS accepted, plus memory and path changes.
final class OpenFluxTunnel: @unchecked Sendable {
    private enum Constants {
        static let remoteAddress = "10.255.255.254"
        static let dnsAddress = "198.18.0.1"
        // Upstream OpenFlux uses 1500; lowering it is one of the experiments.
        static let mtu = 1500
        static let readBatch = 64
        static let statsInterval: TimeInterval = 5
    }

    /// Yandex networks stay off the tunnel: the document websocket itself
    /// lives there, and routing it into the tunnel would loop.
    private static let yandexRanges: [(String, String)] = [
        ("5.45.192.0", "255.255.192.0"),
        ("5.255.192.0", "255.255.192.0"),
        ("37.9.64.0", "255.255.192.0"),
        ("37.140.128.0", "255.255.192.0"),
        ("77.88.0.0", "255.255.192.0"),
        ("84.201.128.0", "255.255.192.0"),
        ("87.250.224.0", "255.255.224.0"),
        ("90.156.176.0", "255.255.252.0"),
        ("93.158.128.0", "255.255.192.0"),
        ("95.108.128.0", "255.255.128.0"),
        ("100.43.64.0", "255.255.224.0"),
        ("178.154.128.0", "255.255.128.0"),
        ("213.180.192.0", "255.255.224.0"),
    ]

    private weak var provider: NEPacketTunnelProvider?
    private let log: (String, DiagnosticLogLevel) -> Void
    private let lock = NSLock()
    private var running = false
    private var logRelay: OpenFluxLogRelay?
    private var readerThread: Thread?
    private var statsTimer: DispatchSourceTimer?
    private let pathMonitor = NWPathMonitor()

    private var upPackets = 0
    private var upBytes = 0
    private var upBatches = 0
    private var downPackets = 0
    private var downBytes = 0
    private var downBatches = 0
    private var lastStats = ""

    init(provider: NEPacketTunnelProvider, log: @escaping (String, DiagnosticLogLevel) -> Void) {
        self.provider = provider
        self.log = log
    }

    func start(docURL: String, excludedHosts: [String]) async throws {
        let relay = OpenFluxLogRelay { [weak self] line in
            self?.log(line, Self.level(for: line))
        }
        logRelay = relay
        MobileSetLogWriter(relay)
        // No socket protector: the provider's own sockets already bypass its
        // tunnel, and binding to one interface would break on Wi-Fi/LTE flips.
        MobileSetProtector(nil)

        var error: NSError?
        guard MobileOpenfluxStart(docURL, &error) else {
            throw error ?? NSError(domain: "OpenFlux", code: 1)
        }
        log("checkpoint: openflux core started mtu=\(Constants.mtu) \(memorySummary())", .checkpoint)

        try await applySettings(excludedHosts: excludedHosts)
        setRunning(true)
        startPathMonitor()
        startReader()
        readFromDevice()
        startStats()
    }

    func stop() {
        guard isRunning else { return }
        setRunning(false)
        statsTimer?.cancel()
        statsTimer = nil
        pathMonitor.cancel()
        MobileOpenfluxStop()
        MobileSetLogWriter(nil)
        logRelay = nil
        log("checkpoint: openflux stopped \(counterSummary())", .checkpoint)
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func setRunning(_ value: Bool) {
        lock.lock()
        running = value
        lock.unlock()
    }

    private func applySettings(excludedHosts: [String]) async throws {
        guard let provider else { return }
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: Constants.remoteAddress)
        settings.mtu = Constants.mtu as NSNumber

        let ipv4 = NEIPv4Settings(addresses: [MobileOpenfluxTunnelAddress()], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        var excluded = Self.yandexRanges.map { NEIPv4Route(destinationAddress: $0.0, subnetMask: $0.1) }
        let dot = MobileOpenfluxBypassAddrs().split(separator: ",").map(String.init)
        excluded += dot.map { NEIPv4Route(destinationAddress: $0, subnetMask: "255.255.255.255") }
        excluded += excludedHosts.map { NEIPv4Route(destinationAddress: $0, subnetMask: "255.255.255.255") }
        ipv4.excludedRoutes = excluded
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: [Constants.dnsAddress])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        try await provider.setTunnelNetworkSettings(settings)
        log(
            "checkpoint: openflux settings addr=\(MobileOpenfluxTunnelAddress())/32 excluded=\(excluded.count) dot=\(dot.joined(separator: ",")) control=\(excludedHosts.joined(separator: ","))",
            .checkpoint
        )
    }

    /// iOS -> Go. readPackets re-arms itself until stop.
    private func readFromDevice() {
        provider?.packetFlow.readPackets { [weak self] packets, _ in
            guard let self, self.isRunning else { return }
            var bytes = 0
            for packet in packets {
                bytes += packet.count
                MobileOpenfluxWritePacket(packet)
            }
            self.lock.lock()
            self.upPackets += packets.count
            self.upBytes += bytes
            self.upBatches += 1
            self.lock.unlock()
            self.readFromDevice()
        }
    }

    /// Go -> iOS on a dedicated thread: the Go read blocks.
    private func startReader() {
        let thread = Thread { [weak self] in
            while let self, self.isRunning {
                guard let first = MobileOpenfluxReadPacket(500) else { continue }
                var batch = [first]
                while batch.count < Constants.readBatch, let next = MobileOpenfluxReadPacket(0) {
                    batch.append(next)
                }
                let protocols = [NSNumber](repeating: NSNumber(value: AF_INET), count: batch.count)
                let accepted = self.provider?.packetFlow.writePackets(batch, withProtocols: protocols) ?? false
                let bytes = batch.reduce(0) { $0 + $1.count }
                self.lock.lock()
                self.downPackets += batch.count
                self.downBytes += bytes
                self.downBatches += 1
                self.lock.unlock()
                if !accepted {
                    self.log("checkpoint: openflux writePackets rejected batch=\(batch.count)", .error)
                }
            }
        }
        thread.name = "openflux.reader"
        thread.qualityOfService = .userInitiated
        readerThread = thread
        thread.start()
    }

    private func startStats() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Constants.statsInterval, repeating: Constants.statsInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let summary = self.counterSummary()
            // The Go core logs its own view; this line is the iOS side of the
            // bridge and memory, which is what jetsam watches.
            self.log("openflux-ext: \(summary) connected=\(MobileOpenfluxIsConnected()) \(self.memorySummary())", .info)
        }
        statsTimer = timer
        timer.resume()
    }

    private func counterSummary() -> String {
        lock.lock()
        defer { lock.unlock() }
        let text = "fromIOS=\(upPackets)p/\(upBytes)B in \(upBatches) toIOS=\(downPackets)p/\(downBytes)B in \(downBatches)"
        return text
    }

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let kinds: [(NWInterface.InterfaceType, String)] = [
                (.wifi, "wifi"), (.cellular, "cellular"), (.wiredEthernet, "wired"), (.other, "other"),
            ]
            let used = kinds.filter { path.usesInterfaceType($0.0) }.map(\.1).joined(separator: "+")
            let names = path.availableInterfaces.map(\.name).joined(separator: ",")
            self?.log(
                "checkpoint: openflux path status=\(path.status) uses=\(used.isEmpty ? "none" : used) ifaces=\(names) expensive=\(path.isExpensive) constrained=\(path.isConstrained)",
                .checkpoint
            )
        }
        pathMonitor.start(queue: DispatchQueue(label: "openflux.path"))
    }

    private func memorySummary() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard rc == KERN_SUCCESS else { return "mem=?" }
        return "mem=\(info.phys_footprint / 1_048_576)MB"
    }

    private static func level(for line: String) -> DiagnosticLogLevel {
        let events = ["stall", "session", "waitAuth", "participants", "auth", "dns", "lag", "keepalive", "stopped", "start"]
        if line.hasPrefix("openflux: stats") || line.hasPrefix("openflux: frame") {
            return .info
        }
        return events.contains(where: line.contains) ? .checkpoint : .info
    }
}

private final class OpenFluxLogRelay: NSObject, MobileLogWriterProtocol {
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) {
        self.onLine = onLine
    }

    func writeLog(_ msg: String?) {
        guard let msg else { return }
        msg.split(whereSeparator: \.isNewline)
            .map { line -> String in
                // Go's log prefix repeats the time the journal already stamps.
                let text = String(line)
                if let range = text.range(of: "openflux") {
                    return String(text[range.lowerBound...])
                }
                return text.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .forEach(onLine)
    }
}
