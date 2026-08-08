import XCTest
@testable import OlcRTCClientKit

final class CockneySubscriptionParserTests: XCTestCase {
    private let parser = OlcRTCSubscriptionParser()

    func testParsesCockneyJSONSubscription() throws {
        let key = String(repeating: "ab", count: 32)
        let sourceURL = URL(string: "https://cockney.example/api/olcrtc/subscriptions/opaque-secret-token")!
        let json = """
        {
          "version": 1,
          "device": { "id": "5d14ba93-14b9-4d88-ba0b-79de28ba49a8", "name": "iPhone", "tokenVersion": 2 },
          "accessToken": "eyJhbGciOiJFUzI1NiJ9.payload.signature",
          "accessTokenExpiresAtUtc": "2026-08-08T12:00:00Z",
          "refreshAfterSeconds": 600,
          "profile": {
            "provider": "wbstream",
            "transport": "vp8channel",
            "roomId": "019fdcf8-2b0a-70c7-88ae-86af25d110cd",
            "cryptoKey": "\(key)",
            "vp8Fps": 30,
            "vp8BatchSize": 8,
            "connectionUri": "olcrtc://wbstream?vp8channel@019fdcf8-2b0a-70c7-88ae-86af25d110cd#\(key)$Cockney"
          }
        }
        """

        let imported = try parser.parse(json, sourceURL: sourceURL)
        XCTAssertEqual(imported.profiles.count, 1)
        let profile = try XCTUnwrap(imported.profiles.first)
        XCTAssertEqual(profile.clientID, "5d14ba93-14b9-4d88-ba0b-79de28ba49a8")
        XCTAssertEqual(profile.accessToken, "eyJhbGciOiJFUzI1NiJ9.payload.signature")
        XCTAssertEqual(profile.carrier, .wbstream)
        XCTAssertEqual(profile.transport, .vp8channel)
        XCTAssertEqual(profile.roomID, "019fdcf8-2b0a-70c7-88ae-86af25d110cd")
        XCTAssertEqual(profile.keyHex, key)
        XCTAssertEqual(profile.socksPort, CockneySubscriptionParser.defaultSocksPort)
        XCTAssertEqual(profile.vp8FPS, 30)
        XCTAssertEqual(profile.subscription?.refreshInterval, "600s")
        XCTAssertEqual(profile.subscription?.accessExpiresAtUtc, "2026-08-08T12:00:00Z")
        XCTAssertEqual(profile.subscription?.sourceURL, sourceURL.absoluteString)
    }

    func testRedactsSubscriptionSecrets() {
        let raw = "Loading https://host/api/olcrtc/subscriptions/super-secret-token and eyJhbGciOiJFUzI1NiJ9.aaa.bbb"
        let redacted = DiagnosticLogRedactor.redact(raw)
        XCTAssertFalse(redacted.contains("super-secret-token"))
        XCTAssertTrue(redacted.contains("/api/olcrtc/subscriptions/***"))
        XCTAssertTrue(redacted.contains("jwt:***"))
    }
}
