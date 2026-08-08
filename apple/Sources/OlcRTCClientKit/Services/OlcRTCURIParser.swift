import Foundation

public enum OlcRTCURIParserError: LocalizedError, Equatable {
    case unsupportedScheme
    case missingCarrier
    case missingTransport
    case missingRoom
    case missingFragment
    case missingKey
    case invalidCarrier(String)
    case invalidTransport(String)
    case invalidPayload(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedScheme:
            "Only olcrtc:// links are supported."
        case .missingCarrier:
            "Carrier is missing in the olcRTC link."
        case .missingTransport:
            "Transport is missing in the olcRTC link."
        case .missingRoom:
            "Room ID is missing in the olcRTC link."
        case .missingFragment:
            "Key fragment is missing in the olcRTC link."
        case .missingKey:
            "Encryption key is missing in the olcRTC link."
        case let .invalidCarrier(value):
            "Unsupported carrier in the olcRTC link: \(value)."
        case let .invalidTransport(value):
            "Unsupported transport in the olcRTC link: \(value)."
        case let .invalidPayload(value):
            "Invalid transport payload in the olcRTC link: \(value)."
        }
    }
}

public struct OlcRTCURIParser {
    private static let scheme = "olcrtc://"

    public init() {}

    public func parse(_ rawValue: String, into profile: ConnectionProfile) throws -> ConnectionProfile {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: Self.scheme, options: [.anchored, .caseInsensitive]) != nil else {
            throw OlcRTCURIParserError.unsupportedScheme
        }

        let body = String(value.dropFirst(Self.scheme.count))
        let carrierSplit = try splitRequired(body, at: "?", missing: .missingTransport)
        let carrierName = normalizedIdentifier(carrierSplit.head)
        guard !carrierName.isEmpty else {
            throw OlcRTCURIParserError.missingCarrier
        }
        guard let carrier = Carrier(rawValue: carrierName) else {
            throw OlcRTCURIParserError.invalidCarrier(carrierSplit.head)
        }

        let fragmentSplit = try splitRequired(carrierSplit.tail, at: "#", missing: .missingFragment)
        let roomSplit = try splitRequired(fragmentSplit.head, at: "@", missing: .missingRoom)
        let transport = try parseTransport(roomSplit.head)
        let roomID = roomSplit.tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !roomID.isEmpty else {
            throw OlcRTCURIParserError.missingRoom
        }

        var parsed = profile
        parsed.carrier = carrier
        parsed.transport = transport.name
        parsed.roomID = roomID
        applyTransportParameters(transport.parameters, to: &parsed)
        try parseFragment(fragmentSplit.tail, into: &parsed)

        if parsed.name == ConnectionProfile.empty.name || parsed.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parsed.name = "\(parsed.carrier.title) \(parsed.roomID)"
        }

        return parsed
    }

    private func parseTransport(_ value: String) throws -> (name: Transport, parameters: [String: String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OlcRTCURIParserError.missingTransport
        }

        let parsed = try parseTransportValue(trimmed)
        guard let transport = Transport(rawValue: parsed.name) else {
            throw OlcRTCURIParserError.invalidTransport(parsed.name)
        }
        return (transport, parsed.parameters)
    }

    private func parseTransportValue(_ value: String) throws -> (name: String, parameters: [String: String]) {
        guard let payloadStart = value.firstIndex(of: "<") else {
            return (normalizedIdentifier(value), [:])
        }

        guard value.hasSuffix(">"), let payloadEnd = value.lastIndex(of: ">"), payloadEnd > payloadStart else {
            throw OlcRTCURIParserError.invalidPayload(value)
        }

        let name = normalizedIdentifier(String(value[..<payloadStart]))
        guard !name.isEmpty else {
            throw OlcRTCURIParserError.missingTransport
        }

        let payloadText = String(value[value.index(after: payloadStart)..<payloadEnd])
        var parameters: [String: String] = [:]
        guard !payloadText.isEmpty else {
            return (name, parameters)
        }

        for pair in payloadText.split(separator: "&", omittingEmptySubsequences: true) {
            let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard keyValue.count == 2 else {
                throw OlcRTCURIParserError.invalidPayload(String(pair))
            }
            let key = normalizedIdentifier(String(keyValue[0]))
            guard !key.isEmpty else {
                throw OlcRTCURIParserError.invalidPayload(String(pair))
            }
            parameters[key] = String(keyValue[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return (name, parameters)
    }

    private func applyTransportParameters(_ parameters: [String: String], to profile: inout ConnectionProfile) {
        if let value = parameters["vp8-fps"].flatMap(Int.init) {
            profile.vp8FPS = value
        }
        if let value = parameters["vp8-batch"].flatMap(Int.init) {
            profile.vp8BatchSize = value
        }
        if let value = parameters["turn-endpoint"], !value.isEmpty {
            profile.turnEndpoint = value
        }
        if let value = parameters["fps"].flatMap(Int.init) {
            profile.seiFPS = value
        }
        if let value = parameters["batch"].flatMap(Int.init) {
            profile.seiBatchSize = value
        }
        if let value = parameters["frag"].flatMap(Int.init) {
            profile.seiFragmentSize = value
        }
        if let value = parameters["ack-ms"].flatMap(Int.init) {
            profile.seiAckTimeoutMillis = value
        }
        if let value = parameters["video-codec"] {
            profile.videoCodec = value
        }
        if let value = parameters["video-w"].flatMap(Int.init) {
            profile.videoWidth = value
        }
        if let value = parameters["video-h"].flatMap(Int.init) {
            profile.videoHeight = value
        }
        if let value = parameters["video-fps"].flatMap(Int.init) {
            profile.videoFPS = value
        }
        if let value = parameters["video-bitrate"] {
            profile.videoBitrate = value
        }
        if let value = parameters["video-hw"] {
            profile.videoHardwareAcceleration = value
        }
        if let value = parameters["video-qr-recovery"] {
            profile.videoQRRecovery = value
        }
        if let value = parameters["video-qr-size"].flatMap(Int.init) {
            profile.videoQRSize = value
        }
        if let value = parameters["video-tile-module"].flatMap(Int.init) {
            profile.videoTileModule = value
        }
        if let value = parameters["video-tile-rs"].flatMap(Int.init) {
            profile.videoTileRS = value
        }
    }

    private func parseFragment(_ value: String, into profile: inout ConnectionProfile) throws {
        let metaSplit = splitOptional(value, at: "$")
        let legacyClientSplit = splitOptional(metaSplit.head, at: "%")
        let key = legacyClientSplit.head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw OlcRTCURIParserError.missingKey
        }

        profile.keyHex = key

        if let clientID = legacyClientSplit.tail?.trimmingCharacters(in: .whitespacesAndNewlines),
           !clientID.isEmpty {
            profile.clientID = clientID
        }

        if let mimo = metaSplit.tail?.trimmingCharacters(in: .whitespacesAndNewlines),
           !mimo.isEmpty {
            profile.name = mimo
        }
    }

    private func splitRequired(
        _ value: String,
        at separator: Character,
        missing error: OlcRTCURIParserError
    ) throws -> (head: String, tail: String) {
        guard let index = value.firstIndex(of: separator) else {
            throw error
        }
        let tailStart = value.index(after: index)
        return (String(value[..<index]), String(value[tailStart...]))
    }

    private func splitOptional(_ value: String, at separator: Character) -> (head: String, tail: String?) {
        guard let index = value.firstIndex(of: separator) else {
            return (value, nil)
        }
        let tailStart = value.index(after: index)
        return (String(value[..<index]), String(value[tailStart...]))
    }

    private func normalizedIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
