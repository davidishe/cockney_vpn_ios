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

public enum DiagnosticLogUploaderError: Error, LocalizedError {
    case unauthorized
    case httpStatus(Int)
    case encoding
    case emptyToken
    case nothingToUpload
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Сервер отклонил токен (401/403)."
        case .httpStatus(let code):
            return "HTTP \(code)"
        case .encoding:
            return "Не удалось сериализовать журнал."
        case .emptyToken:
            return "Нет access token — обновите подписку."
        case .nothingToUpload:
            return "Журнал пуст."
        case .transport(let message):
            return message
        }
    }
}

/// Manual upload of DiagnosticJournal pending lines to RU API.
public final class DiagnosticLogUploader: @unchecked Sendable {
    public static let shared = DiagnosticLogUploader()

    private let journal: DiagnosticJournal
    private let session: URLSession

    public init(
        journal: DiagnosticJournal = .shared,
        session: URLSession = .shared
    ) {
        self.journal = journal
        self.session = session
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

    /// Drain and POST all pending batches. Does not append checkpoints into the journal.
    public func uploadAllPending(context: DiagnosticLogUploadContext) async throws -> Int {
        guard !context.accessToken.isEmpty else {
            throw DiagnosticLogUploaderError.emptyToken
        }
        journal.prepareForUpload()
        var total = 0
        while true {
            let batch = journal.drainPending(limit: 100)
            if batch.isEmpty {
                break
            }
            do {
                try await performUpload(context: context, lines: batch)
                total += batch.count
            } catch {
                journal.requeue(batch)
                throw error
            }
        }
        if total == 0 {
            throw DiagnosticLogUploaderError.nothingToUpload
        }
        return total
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

        do {
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
        } catch let urlError as URLError {
            throw DiagnosticLogUploaderError.transport(Self.describeURLError(urlError))
        }
    }

    private static func describeURLError(_ error: URLError) -> String {
        switch error.code {
        case .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot,
             .secureConnectionFailed,
             .clientCertificateRejected,
             .clientCertificateRequired:
            return "SSL: \(error.localizedDescription). Если VPN включён — пересоберите клиент (обход API) или отключите VPN и повторите."
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .dnsLookupFailed:
            return "Сеть: \(error.localizedDescription)"
        default:
            return error.localizedDescription
        }
    }
}
