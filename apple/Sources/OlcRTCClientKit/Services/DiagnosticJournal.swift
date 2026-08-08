import Foundation

public enum DiagnosticLogLevel: String, Codable, Sendable {
    case checkpoint
    case info
    case warn
    case error
}

public struct DiagnosticLogEntry: Codable, Sendable, Equatable {
    public var ts: String
    public var level: String
    public var message: String
    public var sessionId: String?
    public var mode: String?

    public init(
        ts: String,
        level: String,
        message: String,
        sessionId: String? = nil,
        mode: String? = nil
    ) {
        self.ts = ts
        self.level = level
        self.message = message
        self.sessionId = sessionId
        self.mode = mode
    }
}

/// Shared diagnostic journal for the app and Packet Tunnel (App Group when available).
public final class DiagnosticJournal: @unchecked Sendable {
    public static let shared = DiagnosticJournal()
    public static let appGroupIdentifier = "group.space.tokenova.cockney.ios"

    public static let maxUILines = 2000
    private static let maxPendingEntries = 2000

    private let queue = DispatchQueue(label: "space.tokenova.cockney.diagnostic-journal")
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private var uiLines: [String] = []
    private var pending: [DiagnosticLogEntry] = []
    private var sessionId: UUID?
    private var mode: String = "localSocks"
    private var deviceId: String = ""

    private init() {
        queue.sync {
            loadFromDisk()
        }
    }

    public func configureSession(sessionId: UUID, mode: String, deviceId: String) {
        queue.sync {
            self.sessionId = sessionId
            self.mode = mode
            self.deviceId = deviceId
            persistMeta()
        }
    }

    public func clearSession() {
        queue.sync {
            sessionId = nil
        }
    }

    public func append(_ message: String, level: DiagnosticLogLevel = .info) {
        let now = Date()
        let redacted = DiagnosticLogRedactor.redact(message)
        let ts = isoFormatter.string(from: now)
        let display = "[\(displayFormatter.string(from: now))] \(redacted)"
        let entry = DiagnosticLogEntry(
            ts: ts,
            level: level.rawValue,
            message: redacted,
            sessionId: sessionId?.uuidString,
            mode: mode
        )

        queue.sync {
            uiLines.append(display)
            if uiLines.count > Self.maxUILines {
                uiLines.removeFirst(uiLines.count - Self.maxUILines)
            }
            pending.append(entry)
            if pending.count > Self.maxPendingEntries {
                pending.removeFirst(pending.count - Self.maxPendingEntries)
            }
            persistUILines()
            persistPending()
            appendSharedLogLine(display)
        }
    }

    public func recentUILines() -> [String] {
        queue.sync { uiLines }
    }

    public func exportDisplayLines(limit: Int = 500) -> [String] {
        queue.sync { Array(uiLines.suffix(max(0, limit))) }
    }

    /// Merge display lines produced in another process (Packet Tunnel IPC).
    public func ingestDisplayLines(_ lines: [String], enqueuePending: Bool = true) {
        queue.sync {
            for line in lines where !line.isEmpty {
                if uiLines.contains(line) { continue }
                uiLines.append(line)
                if enqueuePending {
                    let message = stripDisplayTimestamp(line)
                    pending.append(
                        DiagnosticLogEntry(
                            ts: isoFormatter.string(from: Date()),
                            level: message.hasPrefix("checkpoint:") || message.hasPrefix("socks:")
                                ? DiagnosticLogLevel.checkpoint.rawValue
                                : DiagnosticLogLevel.info.rawValue,
                            message: message,
                            sessionId: sessionId?.uuidString,
                            mode: mode
                        )
                    )
                }
            }
            if uiLines.count > Self.maxUILines {
                uiLines.removeFirst(uiLines.count - Self.maxUILines)
            }
            if pending.count > Self.maxPendingEntries {
                pending.removeFirst(pending.count - Self.maxPendingEntries)
            }
            persistUILines()
            if enqueuePending {
                persistPending()
            }
        }
    }

    public static func isAppGroupAvailable() -> Bool {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) != nil
    }

    public func diagnosticsDirectoryPath() -> String {
        queue.sync { baseDirectory().path }
    }

    public func clearUI() {
        queue.sync {
            uiLines.removeAll()
            persistUILines()
        }
    }

    public func clearAll() {
        queue.sync {
            uiLines.removeAll()
            pending.removeAll()
            sessionId = nil
            persistUILines()
            persistPending()
            persistMeta()
            if let url = sharedLogURL() {
                try? "".data(using: .utf8)?.write(to: url, options: .atomic)
            }
        }
    }

    public func pendingCount() -> Int {
        queue.sync { pending.count }
    }

    public func hasContent() -> Bool {
        queue.sync { !uiLines.isEmpty || !pending.isEmpty }
    }

    /// Pull App Group shared.log into UI + pending so tunnel lines are included in manual upload.
    public func prepareForUpload() {
        queue.sync {
            mergeSharedLogLocked(enqueuePending: true)
        }
    }

    public func drainPending(limit: Int = 100) -> [DiagnosticLogEntry] {
        queue.sync {
            guard !pending.isEmpty else { return [] }
            let count = min(limit, pending.count)
            let batch = Array(pending.prefix(count))
            pending.removeFirst(count)
            persistPending()
            return batch
        }
    }

    public func requeue(_ entries: [DiagnosticLogEntry]) {
        guard !entries.isEmpty else { return }
        queue.sync {
            pending.insert(contentsOf: entries, at: 0)
            if pending.count > Self.maxPendingEntries {
                pending = Array(pending.suffix(Self.maxPendingEntries))
            }
            persistPending()
        }
    }

    public func currentSessionId() -> UUID? {
        queue.sync { sessionId }
    }

    public func currentMode() -> String {
        queue.sync { mode }
    }

    public func currentDeviceId() -> String {
        queue.sync { deviceId }
    }

    public func mergeSharedLogIntoUI() {
        queue.sync {
            mergeSharedLogLocked(enqueuePending: false)
        }
    }

    private func mergeSharedLogLocked(enqueuePending: Bool) {
        guard let url = sharedLogURL(),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return }
        for line in lines.suffix(500) where !line.isEmpty {
            if !uiLines.contains(line) {
                uiLines.append(line)
                if enqueuePending {
                    let message = stripDisplayTimestamp(line)
                    pending.append(
                        DiagnosticLogEntry(
                            ts: isoFormatter.string(from: Date()),
                            level: message.hasPrefix("checkpoint:") || message.hasPrefix("socks:")
                                ? DiagnosticLogLevel.checkpoint.rawValue
                                : DiagnosticLogLevel.info.rawValue,
                            message: message,
                            sessionId: sessionId?.uuidString,
                            mode: mode
                        )
                    )
                }
            }
        }
        if uiLines.count > Self.maxUILines {
            uiLines.removeFirst(uiLines.count - Self.maxUILines)
        }
        if pending.count > Self.maxPendingEntries {
            pending.removeFirst(pending.count - Self.maxPendingEntries)
        }
        persistUILines()
        if enqueuePending {
            persistPending()
        }
    }

    private func stripDisplayTimestamp(_ line: String) -> String {
        // "[HH:mm:ss.SSS] message"
        guard line.first == "[",
              let close = line.firstIndex(of: "]"),
              line.distance(from: line.startIndex, to: close) <= 16 else {
            return line
        }
        let after = line.index(after: close)
        return line[after...].trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Storage

    private func baseDirectory() -> URL {
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) {
            let dir = groupURL.appendingPathComponent("Diagnostics", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("CockneyDiagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func uiLinesURL() -> URL { baseDirectory().appendingPathComponent("ui-lines.json") }
    private func pendingURL() -> URL { baseDirectory().appendingPathComponent("pending.json") }
    private func metaURL() -> URL { baseDirectory().appendingPathComponent("meta.json") }
    private func sharedLogURL() -> URL? {
        baseDirectory().appendingPathComponent("shared.log")
    }

    private func persistUILines() {
        guard let data = try? JSONEncoder().encode(uiLines) else { return }
        try? data.write(to: uiLinesURL(), options: .atomic)
    }

    private func persistPending() {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: pendingURL(), options: .atomic)
    }

    private func persistMeta() {
        let payload: [String: String] = [
            "sessionId": sessionId?.uuidString ?? "",
            "mode": mode,
            "deviceId": deviceId,
        ]
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: metaURL(), options: .atomic)
    }

    private func appendSharedLogLine(_ line: String) {
        guard let url = sharedLogURL() else { return }
        let payload = (line + "\n").data(using: .utf8) ?? Data()
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            try? payload.write(to: url, options: .atomic)
        }
        // Cap shared log size (~512 KiB).
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber,
           size.intValue > 512_000,
           let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            let trimmed = text.suffix(256_000)
            try? String(trimmed).data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    private func loadFromDisk() {
        if let data = try? Data(contentsOf: uiLinesURL()),
           let lines = try? JSONDecoder().decode([String].self, from: data) {
            uiLines = lines
        }
        if let data = try? Data(contentsOf: pendingURL()),
           let entries = try? JSONDecoder().decode([DiagnosticLogEntry].self, from: data) {
            pending = entries
        }
        if let data = try? Data(contentsOf: metaURL()),
           let meta = try? JSONDecoder().decode([String: String].self, from: data) {
            if let raw = meta["sessionId"], let id = UUID(uuidString: raw) {
                sessionId = id
            }
            mode = meta["mode"] ?? mode
            deviceId = meta["deviceId"] ?? deviceId
        }
    }
}
