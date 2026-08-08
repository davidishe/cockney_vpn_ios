import Foundation

public enum CockneySubscriptionParserError: LocalizedError, Equatable {
    case invalidJSON
    case unsupportedVersion(Int)
    case missingAccessToken
    case missingDeviceID
    case missingProfile
    case invalidProvider(String)
    case invalidTransport(String)
    case missingRoomID
    case missingCryptoKey

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            "Cockney subscription JSON is invalid."
        case let .unsupportedVersion(version):
            "Unsupported Cockney subscription version: \(version)."
        case .missingAccessToken:
            "Cockney subscription is missing accessToken."
        case .missingDeviceID:
            "Cockney subscription is missing device.id."
        case .missingProfile:
            "Cockney subscription is missing profile."
        case let .invalidProvider(value):
            "Unsupported Cockney provider: \(value)."
        case let .invalidTransport(value):
            "Unsupported Cockney transport: \(value)."
        case .missingRoomID:
            "Cockney subscription profile is missing roomId."
        case .missingCryptoKey:
            "Cockney subscription profile is missing cryptoKey."
        }
    }
}

public struct CockneySubscriptionParser {
    public static let defaultSocksPort = 18_080

    private let uriParser: OlcRTCURIParser

    public init(uriParser: OlcRTCURIParser = OlcRTCURIParser()) {
        self.uriParser = uriParser
    }

    public static func looksLikeCockneyJSON(_ rawValue: String) -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{")
    }

    public func parse(_ rawValue: String, sourceURL: URL? = nil) throws -> OlcRTCSubscriptionImport {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            throw CockneySubscriptionParserError.invalidJSON
        }

        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw CockneySubscriptionParserError.invalidJSON
        }

        guard document.version == 1 else {
            throw CockneySubscriptionParserError.unsupportedVersion(document.version)
        }

        let accessToken = document.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            throw CockneySubscriptionParserError.missingAccessToken
        }

        let deviceID = document.device.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceID.isEmpty else {
            throw CockneySubscriptionParserError.missingDeviceID
        }

        guard let profileDTO = document.profile else {
            throw CockneySubscriptionParserError.missingProfile
        }

        let subscriptionID = UUID()
        let deviceName = normalized(document.device.name) ?? "Cockney device"
        let subscriptionName = sourceURL?.host.map { "Cockney \($0)" } ?? "Cockney subscription"
        let refreshInterval = document.refreshAfterSeconds.flatMap { seconds in
            seconds > 0 ? "\(seconds)s" : nil
        }

        var profile = ConnectionProfile.empty
        if let connectionURI = normalized(profileDTO.connectionUri),
           connectionURI.lowercased().hasPrefix("olcrtc://") {
            profile = try uriParser.parse(connectionURI, into: profile)
        } else {
            profile = try applyProfileFields(profileDTO, into: profile)
        }

        if let fps = profileDTO.vp8Fps, fps > 0 {
            profile.vp8FPS = fps
        }
        if let batch = profileDTO.vp8BatchSize, batch > 0 {
            profile.vp8BatchSize = batch
        }

        profile.id = UUID()
        profile.name = deviceName
        profile.clientID = deviceID
        profile.accessToken = accessToken
        profile.socksPort = Self.defaultSocksPort
        profile.subscription = SubscriptionMetadata(
            id: subscriptionID,
            name: subscriptionName,
            sourceURL: sourceURL?.absoluteString,
            updatedAtUnix: nil,
            lastFetchedAtUnix: nil,
            refreshInterval: refreshInterval,
            accessExpiresAtUtc: normalized(document.accessTokenExpiresAtUtc),
            nodeComment: "device=\(deviceID)",
            nodeURI: normalized(profileDTO.connectionUri)
        )

        return OlcRTCSubscriptionImport(
            subscriptionID: subscriptionID,
            name: subscriptionName,
            profiles: [profile]
        )
    }

    private func applyProfileFields(
        _ dto: ProfileDTO,
        into profile: ConnectionProfile
    ) throws -> ConnectionProfile {
        var parsed = profile

        let provider = normalizedIdentifier(dto.provider)
        guard !provider.isEmpty else {
            throw CockneySubscriptionParserError.invalidProvider(dto.provider)
        }
        guard let carrier = Carrier(rawValue: provider) else {
            throw CockneySubscriptionParserError.invalidProvider(dto.provider)
        }

        let transportName = normalizedIdentifier(dto.transport)
        guard !transportName.isEmpty else {
            throw CockneySubscriptionParserError.invalidTransport(dto.transport)
        }
        guard let transport = Transport(rawValue: transportName) else {
            throw CockneySubscriptionParserError.invalidTransport(dto.transport)
        }

        let roomID = dto.roomId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !roomID.isEmpty else {
            throw CockneySubscriptionParserError.missingRoomID
        }

        let cryptoKey = dto.cryptoKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cryptoKey.isEmpty else {
            throw CockneySubscriptionParserError.missingCryptoKey
        }

        parsed.carrier = carrier
        parsed.transport = transport
        parsed.roomID = roomID
        parsed.keyHex = cryptoKey
        return parsed
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private struct Document: Decodable {
    let version: Int
    let device: DeviceDTO
    let accessToken: String
    let accessTokenExpiresAtUtc: String?
    let refreshAfterSeconds: Int?
    let profile: ProfileDTO?
}

private struct DeviceDTO: Decodable {
    let id: String
    let name: String?
    let tokenVersion: Int?
}

private struct ProfileDTO: Decodable {
    let provider: String
    let transport: String
    let roomId: String
    let channelId: String?
    let cryptoKey: String
    let vp8Fps: Int?
    let vp8BatchSize: Int?
    let connectionUri: String?
}
