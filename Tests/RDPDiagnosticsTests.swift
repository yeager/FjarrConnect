import XCTest
@testable import FjarrConnect

final class RDPDiagnosticsTests: XCTestCase {
    func testServerInitiatedLogoffHasItsOwnExplanation() {
        XCTAssertEqual(RDPRemoteSession.failureLocalizationKey(for: 8), "rdp.error.serverEndedSession")
        XCTAssertEqual(RDPRemoteSession.failureLocalizationKey(for: 3), "rdp.error.authentication")
        XCTAssertEqual(RDPRemoteSession.failureLocalizationKey(for: 99), "rdp.ended")
    }

    func testNetworkFailureSurvivesSplitPipeReadsWithoutExposingLogs() {
        var diagnostics = RDPDiagnostics()
        diagnostics.consume(Data("private diagnostic data\n[ERROR] ERRCONNECT_CON".utf8))
        diagnostics.consume(Data("NECT_FAILED [0x00020006]\nThe connection failed.\n".utf8))
        XCTAssertEqual(diagnostics.failure, .network)
        let message = diagnostics.message(host: "desktop.local", port: 3389, exitCode: 141)
        XCTAssertTrue(message.contains("desktop.local:3389"))
        XCTAssertTrue(message.contains("141"))
        XCTAssertFalse(message.contains("private diagnostic data"))
        XCTAssertFalse(message.contains("0x00020006"))
    }

    func testSpecificLoginFailureIsNotOverwrittenByTransportCleanup() {
        var diagnostics = RDPDiagnostics()
        diagnostics.consume(Data("ERRCONNECT_LOGON_FAILURE\nERRCONNECT_CONNECT_TRANSPORT_FAILED".utf8))
        XCTAssertEqual(diagnostics.failure, .authentication)
        diagnostics.consume(Data("ERRCONNECT_PASSWORD_EXPIRED".utf8))
        XCTAssertEqual(diagnostics.failure, .account)
    }

    func testTLSFailureAndUnknownErrorsHaveSafeMessages() {
        var diagnostics = RDPDiagnostics()
        diagnostics.consume(Data("unrecognized backend details".utf8))
        XCTAssertNil(diagnostics.failure)
        XCTAssertFalse(diagnostics.message(host: "rdp.local", port: 3390, exitCode: 1)
            .contains("unrecognized backend details"))
        diagnostics.consume(Data("ERRCONNECT_TLS_CONNECT_FAILED".utf8))
        XCTAssertEqual(diagnostics.failure, .certificate)
    }


    func testDiagnosticReportOmitsEndpointCredentialsAndBackendDetails() {
        let profile = ConnectionProfile(name: "Private", transport: .rdp, host: "private.example", port: 3390, username: "alice")
        let report = DiagnosticReport.text(profile: profile, status: .disconnected(reason: "backend secret detail"), now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(report.contains("protocol: rdp"))
        XCTAssertTrue(report.contains("state: failed"))
        XCTAssertTrue(report.contains("architecture:"))
        XCTAssertTrue(report.contains("macOS:"))
        XCTAssertTrue(report.contains("tcp-handshake-ms: unavailable"))
        XCTAssertTrue(report.contains("endpoint: omitted"))
        XCTAssertFalse(report.contains("endpoint-id:"))
        XCTAssertFalse(report.contains("private.example"))
        XCTAssertFalse(report.contains("alice"))
        XCTAssertFalse(report.contains("backend secret detail"))
    }

    func testDiagnosticReportIncludesAvailableHealthWithoutEndpointData() {
        let profile = ConnectionProfile(name: "Remote", transport: .rdp, host: "192.0.2.4")
        let health = SessionHealth(latencyMilliseconds: 18, packetLossPercent: nil, codec: "RemoteFX")
        let report = DiagnosticReport.text(profile: profile, status: .connected, health: health)
        XCTAssertTrue(report.contains("tcp-handshake-ms: 18"))
        XCTAssertTrue(report.contains("packet-loss-percent: unavailable"))
        XCTAssertTrue(report.contains("graphics-codec: RemoteFX"))
        XCTAssertFalse(report.contains(profile.host))
    }
}
