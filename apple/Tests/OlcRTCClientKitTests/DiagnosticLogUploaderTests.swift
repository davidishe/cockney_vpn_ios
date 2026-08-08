import XCTest
@testable import OlcRTCClientKit

final class DiagnosticLogUploaderTests: XCTestCase {
    func testUploadURL_ReplacesSubscriptionPath() throws {
        let sub = try XCTUnwrap(URL(string: "https://cockney.tokenova.space/api/olcrtc/subscriptions/opaque-token"))
        let upload = DiagnosticLogUploader.uploadURL(fromSubscriptionURL: sub)
        XCTAssertEqual(upload.absoluteString, "https://cockney.tokenova.space/api/olcrtc/diagnostics/logs")
    }

    func testUploadURL_FallsBackToDefault() {
        let upload = DiagnosticLogUploader.uploadURL(fromSubscriptionURL: nil)
        XCTAssertEqual(upload.host, "cockney.tokenova.space")
        XCTAssertTrue(upload.path.contains("diagnostics/logs"))
    }

    func testJournal_DoesNotLeakJWTIntoPending() {
        let journal = DiagnosticJournal.shared
        journal.append(
            "token=eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiIxIn0.signature carrierAuth=secretvalue",
            level: .info
        )
        let pending = journal.drainPending(limit: 5)
        XCTAssertFalse(pending.isEmpty)
        let joined = pending.map(\.message).joined(separator: "\n")
        XCTAssertFalse(joined.contains("eyJhbGciOiJFUzI1NiJ9"))
        XCTAssertFalse(joined.contains("secretvalue"))
        XCTAssertTrue(joined.contains("jwt:***") || joined.contains("***"))
    }
}
