import XCTest
@testable import OlcRTCClientKit

final class OlcRTCURIParserTests: XCTestCase {
    private let parser = OlcRTCURIParser()

    func testParsesDocumentedJitsiURIWithoutClientID() throws {
        let profile = try parser.parse(
            "olcrtc://jitsi?datachannel@https://meet.cryptopro.ru/myroom#d823fa01cb3e0609b67322f7cf984c4ee2e4ce2e294936fc24ef38c9e59f4799$RU / olc free sub",
            into: .empty
        )

        XCTAssertEqual(profile.carrier, .jitsi)
        XCTAssertEqual(profile.transport, .datachannel)
        XCTAssertEqual(profile.roomID, "https://meet.cryptopro.ru/myroom")
        XCTAssertEqual(profile.keyHex, "d823fa01cb3e0609b67322f7cf984c4ee2e4ce2e294936fc24ef38c9e59f4799")
        XCTAssertEqual(profile.clientID, "")
        XCTAssertEqual(profile.name, "RU / olc free sub")
    }

    func testParsesActualJitsiLink() throws {
        let profile = try parser.parse(
            "olcrtc://jitsi?datachannel@https://meet.cryptopro.ru/pasklove-olcrtc-548f323503997581#258aa76a14d8e5d22a9eeb57190e454d4062c5185ec4b5f9a3631de76f3001a2$Jitsi CH",
            into: .empty
        )

        XCTAssertEqual(profile.carrier, .jitsi)
        XCTAssertEqual(profile.transport, .datachannel)
        XCTAssertEqual(profile.roomID, "https://meet.cryptopro.ru/pasklove-olcrtc-548f323503997581")
        XCTAssertEqual(profile.keyHex, "258aa76a14d8e5d22a9eeb57190e454d4062c5185ec4b5f9a3631de76f3001a2")
        XCTAssertEqual(profile.clientID, "")
        XCTAssertEqual(profile.name, "Jitsi CH")
    }

    func testParsesTransportPayloadAndFullMIMO() throws {
        let profile = try parser.parse(
            "olcrtc://wbstream?vp8channel<vp8-fps=60&vp8-batch=64>@room-01#d823fa01cb3e0609b67322f7cf984c4ee2e4ce2e294936fc24ef38c9e59f4799$RU / olc free sub / IPv6",
            into: .empty
        )

        XCTAssertEqual(profile.carrier, .wbstream)
        XCTAssertEqual(profile.transport, .vp8channel)
        XCTAssertEqual(profile.roomID, "room-01")
        XCTAssertEqual(profile.vp8FPS, 60)
        XCTAssertEqual(profile.vp8BatchSize, 64)
        XCTAssertEqual(profile.name, "RU / olc free sub / IPv6")
    }

    func testParsesVkCallsURI() throws {
        let profile = try parser.parse(
            "olcrtc://vkcalls?vp8channel@join-abc#d823fa01cb3e0609b67322f7cf984c4ee2e4ce2e294936fc24ef38c9e59f4799$Cockney",
            into: .empty
        )

        XCTAssertEqual(profile.carrier, .vkcalls)
        XCTAssertEqual(profile.transport, .vp8channel)
        XCTAssertEqual(profile.roomID, "join-abc")
        XCTAssertEqual(profile.name, "Cockney")
    }

    func testParsesVkCallsTurnrelayURI() throws {
        let profile = try parser.parse(
            "olcrtc://vkcalls?turnrelay<turn-endpoint=195.133.81.165:56000>@join-abc#d823fa01cb3e0609b67322f7cf984c4ee2e4ce2e294936fc24ef38c9e59f4799$Cockney",
            into: .empty
        )

        XCTAssertEqual(profile.carrier, .vkcalls)
        XCTAssertEqual(profile.transport, .turnrelay)
        XCTAssertEqual(profile.roomID, "join-abc")
        XCTAssertEqual(profile.turnEndpoint, "195.133.81.165:56000")
        XCTAssertEqual(profile.name, "Cockney")
    }

    func testKeepsLegacyClientIDCompatibility() throws {
        let profile = try parser.parse(
            "olcrtc://jitsi?datachannel@https://meet.cryptopro.ru/myroom#d823fa01cb3e0609b67322f7cf984c4ee2e4ce2e294936fc24ef38c9e59f4799%legacy-client$Legacy",
            into: .empty
        )

        XCTAssertEqual(profile.clientID, "legacy-client")
        XCTAssertEqual(profile.name, "Legacy")
    }

    func testRejectsUnknownCarrierInsteadOfFallingBackToDefault() {
        XCTAssertThrowsError(
            try parser.parse(
                "olcrtc://unknown?datachannel@room#d823fa01cb3e0609b67322f7cf984c4ee2e4ce2e294936fc24ef38c9e59f4799$Name",
                into: .empty
            )
        ) { error in
            XCTAssertEqual(error as? OlcRTCURIParserError, .invalidCarrier("unknown"))
        }
    }
}
