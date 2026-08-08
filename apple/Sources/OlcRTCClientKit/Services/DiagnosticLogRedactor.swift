import Foundation

enum DiagnosticLogRedactor {
    private static let jwtPattern = #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#
    private static let subscriptionPathPattern =
        #"(?i)(/api/olcrtc/subscriptions/)([A-Za-z0-9._~-]+)"#
    private static let hexKeyPattern = #"(?i)\b([0-9a-f]{16})([0-9a-f]{32,})([0-9a-f]{16})\b"#
    private static let bearerPattern = #"(?i)\bBearer\s+[A-Za-z0-9._\-+/=]+\b"#
    private static let carrierAuthPattern = #"(?i)(carrierAuth(Token)?=)([^\s]+)"#
    private static let cookiesPattern = #"(?i)(cookie[s]?\s*[:=]\s*)([^\s]+)"#

    static func redact(_ message: String) -> String {
        var result = message
        result = replace(result, pattern: jwtPattern, template: "jwt:***")
        result = replace(result, pattern: bearerPattern, template: "Bearer ***")
        result = replace(
            result,
            pattern: subscriptionPathPattern,
            template: "$1***"
        )
        result = replace(result, pattern: hexKeyPattern, template: "$1…$3")
        result = replace(result, pattern: carrierAuthPattern, template: "$1***")
        result = replace(result, pattern: cookiesPattern, template: "$1***")
        return result
    }

    static func redactURL(_ url: URL) -> String {
        redact(url.absoluteString)
    }

    private static func replace(_ input: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return input
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(
            in: input,
            options: [],
            range: range,
            withTemplate: template
        )
    }
}
