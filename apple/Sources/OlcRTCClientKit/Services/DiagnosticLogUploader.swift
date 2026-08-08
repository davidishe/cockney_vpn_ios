import Foundation

public struct DiagnosticLogUploadContext: Sendable {
    public var accessToken: String
    public var deviceId: String
    public var sessionId: UUID
    public var mode: String
    public var uploadURL: URL
    public var appVersion: String
    public var build: String
    public var platform: String

    public init(
        accessToken: String,
        deviceId: String,
        sessionId: UUID,
        mode: String,
        uploadURL: URL,
        appVersion: String,
        build: String,
        platform: String
    ) {
        self.accessToken = accessToken
        self.deviceId = deviceId
        self.sessionId = sessionId
        self.mode = mode
        self.uploadURL = uploadURL
        self.appVersion = appVersion
        self.build = build
        self.platform = platform
    }
}

public enum DiagnosticLogUploaderError: Error {
    case unauthorized
    case httpStatus(Int)
    case encoding
    case emptyToken
}

/// Periodically drains DiagnosticJournal pending lines to RU API.
public final class DiagnosticLogUploader: @unchecked Sendable {
    public static let shared = DiagnosticLogUploader()

    private let journal: DiagnosticJournal
    private let session: URLSession
    private let queue = DispatchQueue(label: "space.tokenova.cockney.diagnostic-uploader")
    private var timer: DispatchSourceTimer?
    private var inFlight = false
    private var enabled = true
    private var context: DiagnosticLogUploadContext?
    private var consecutiveFailures = 0

    public init(
        journal: DiagnosticJournal = .shared,
        session: URLSession = .shared
    ) {
        self.journal = journal
        self.session = session
    }

    public func setEnabled(_ value: Bool) {
        queue.sync { enabled = value }
    }

    public func updateContext(_ context: DiagnosticLogUploadContext?) {
        queue.sync { self.context = context }
    }

    public func startPeriodicUpload(intervalSeconds: TimeInterval = 30) {
        queue.async {
            self.timer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 3, repeating: intervalSeconds)
            timer.setEventHandler { [weak self] in
                self?.uploadIfNeeded(reason: "timer")
            }
            self.timer = timer
            timer.resume()
        }
    }

    public func stopPeriodicUpload() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    public func uploadNow(reason: String = "manual") {
        queue.async {
            self.uploadIfNeeded(reason: reason)
        }
    }

    public static func uploadURL(fromSubscriptionURL subscriptionURL: URL?) -> URL {
        if let subscriptionURL,
           var components = URLComponents(url: subscriptionURL, resolvingAgainstBaseURL: false) {
            components.path = "/api/olcrtc/diagnostics/logs"
            components.query = nil
            components.fragment = nil
            if let url = components.url {
                return url
            }
        }
        return URL(string: "https://cockney.tokenova.space/api/olcrtc/diagnostics/logs")!
    }

    public static func makeContext(
        accessToken: String,
        deviceId: String,
        sessionId: UUID,
        mode: String,
        subscriptionURL: URL? = nil
    ) -> DiagnosticLogUploadContext {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        #if os(iOS)
        let platform = "ios"
        #else
        let platform = "macos"
        #endif
        return DiagnosticLogUploadContext(
            accessToken: accessToken,
            deviceId: deviceId,
            sessionId: sessionId,
            mode: mode,
            uploadURL: uploadURL(fromSubscriptionURL: subscriptionURL),
            appVersion: appVersion,
            build: build,
            platform: platform
        )
    }

    private func uploadIfNeeded(reason: String) {
        guard enabled, !inFlight else { return }
        guard let context else {
            if reason != "timer" {
                journal.append("checkpoint: diagnostics upload skipped reason=\(reason) (no context)", level: .warn)
            }
            return
        }
        guard !context.accessToken.isEmpty else {
            journal.append("checkpoint: diagnostics upload skipped reason=\(reason) (empty jwt)", level: .warn)
            return
        }

        let batch = journal.drainPending(limit: 100)
        guard !batch.isEmpty else { return }
        inFlight = true

        if reason != "timer" {
            journal.append(
                "checkpoint: diagnostics upload start reason=\(reason) lines=\(batch.count)",
                level: .checkpoint
            )
        }

        Task {
            do {
                try await performUpload(context: context, lines: batch)
                queue.async {
                    self.consecutiveFailures = 0
                    self.inFlight = false
                }
                self.journal.append(
                    "checkpoint: diagnostics upload ok reason=\(reason) lines=\(batch.count)",
                    level: .checkpoint
                )
            } catch DiagnosticLogUploaderError.unauthorized {
                journal.requeue(batch)
                queue.async {
                    self.consecutiveFailures += 1
                    self.inFlight = false
                }
                self.journal.append(
                    "checkpoint: diagnostics upload 401/403 reason=\(reason)",
                    level: .error
                )
            } catch DiagnosticLogUploaderError.httpStatus(let code) {
                journal.requeue(batch)
                queue.async {
                    self.consecutiveFailures += 1
                    self.inFlight = false
                }
                self.journal.append(
                    "checkpoint: diagnostics upload http=\(code) reason=\(reason)",
                    level: .error
                )
            } catch {
                journal.requeue(batch)
                queue.async {
                    self.consecutiveFailures += 1
                    self.inFlight = false
                }
                self.journal.append(
                    "checkpoint: diagnostics upload failed reason=\(reason) err=\(error.localizedDescription)",
                    level: .error
                )
            }
        }
    }

    private func performUpload(context: DiagnosticLogUploadContext, lines: [DiagnosticLogEntry]) async throws {
        struct Body: Encodable {
            var sessionId: String
            var deviceId: String
            var appVersion: String
            var build: String
            var platform: String
            var mode: String
            var lines: [Line]
            struct Line: Encodable {
                var ts: String
                var level: String
                var message: String
            }
        }

        let body = Body(
            sessionId: context.sessionId.uuidString,
            deviceId: context.deviceId,
            appVersion: context.appVersion,
            build: context.build,
            platform: context.platform,
            mode: context.mode,
            lines: lines.map { Body.Line(ts: $0.ts, level: $0.level, message: $0.message) }
        )

        guard let data = try? JSONEncoder().encode(body) else {
            throw DiagnosticLogUploaderError.encoding
        }

        var request = URLRequest(url: context.uploadURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(context.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = data
        request.timeoutInterval = 30

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DiagnosticLogUploaderError.httpStatus(-1)
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw DiagnosticLogUploaderError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DiagnosticLogUploaderError.httpStatus(http.statusCode)
        }
    }
}
