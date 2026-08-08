import Foundation

struct OlcRTCConfigYAMLBuilder {
    var options: OlcRTCStartOptions
    var socksPort: Int
    var dataPath: String = "data"

    func yaml() -> String {
        var lines: [String] = []

        lines.append("mode: cnc")
        lines.append("link: direct")
        lines.append("auth:")
        lines.append("  provider: \(yamlString(options.carrierName))")
        appendIfPresent("  token", options.carrierAuthToken, to: &lines)
        lines.append("room:")
        lines.append("  id: \(yamlString(options.roomID))")
        lines.append("crypto:")
        lines.append("  key: \(yamlString(options.keyHex))")
        if !options.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("client:")
            appendIfPresent("  device_id", options.clientID, to: &lines)
            appendIfPresent("  access_token", options.accessToken, to: &lines)
        }
        lines.append("net:")
        lines.append("  transport: \(yamlString(options.transportName))")
        appendIfPresent("  dns", options.dnsServer, to: &lines)
        lines.append("socks:")
        lines.append("  host: \(yamlString("127.0.0.1"))")
        lines.append("  port: \(socksPort)")
        appendIfPresent("  user", options.socksUser, to: &lines)
        appendIfPresent("  pass", options.socksPass, to: &lines)
        appendTransportOptions(to: &lines)
        lines.append("data: \(yamlString(dataPath))")
        lines.append("debug: \(options.debugLogging ? "true" : "false")")

        return lines.joined(separator: "\n") + "\n"
    }

    private func appendTransportOptions(to lines: inout [String]) {
        switch options.transportName {
        case "vp8channel":
            lines.append("vp8:")
            lines.append("  fps: \(options.vp8FPS)")
            lines.append("  batch_size: \(options.vp8BatchSize)")
        case "seichannel":
            lines.append("sei:")
            lines.append("  fps: \(options.seiFPS)")
            lines.append("  batch_size: \(options.seiBatchSize)")
            lines.append("  fragment_size: \(options.seiFragmentSize)")
            lines.append("  ack_timeout_ms: \(options.seiAckTimeoutMillis)")
        case "videochannel":
            lines.append("video:")
            lines.append("  width: \(options.videoWidth)")
            lines.append("  height: \(options.videoHeight)")
            lines.append("  fps: \(options.videoFPS)")
            lines.append("  bitrate: \(yamlString(options.videoBitrate))")
            lines.append("  hw: \(yamlString(options.videoHardwareAcceleration))")
            lines.append("  codec: \(yamlString(options.videoCodec))")
            lines.append("  qr_size: \(options.videoQRSize)")
            lines.append("  qr_recovery: \(yamlString(options.videoQRRecovery))")
            lines.append("  tile_module: \(options.videoTileModule)")
            lines.append("  tile_rs: \(options.videoTileRS)")
        case "turnrelay":
            let endpoint = options.turnEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            if !endpoint.isEmpty {
                lines.append("turnrelay:")
                lines.append("  endpoint: \(yamlString(endpoint))")
            }
        default:
            break
        }
    }

    private func appendIfPresent(_ key: String, _ value: String, to lines: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        lines.append("\(key): \(yamlString(trimmed))")
    }

    private func yamlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
