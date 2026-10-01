import XCTest
@testable import FjarrConnect

final class RDPDiagnosticsTests: XCTestCase {
    func testServerInitiatedLogoffHasItsOwnExplanation() {
        XCTAssertEqual(RDPRemoteSession.failureLocalizationKey(for: 8), "rdp.error.serverEndedSession")
        XCTAssertEqual(RDPRemoteSession.failureLocalizationKey(for: 9), "rdp.error.securityNegotiation")
        XCTAssertEqual(RDPRemoteSession.failureLocalizationKey(for: 10), "rdp.error.channel")
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
        XCTAssertTrue(report.contains("tcp-connect-ms: unavailable"))
        XCTAssertTrue(report.contains("endpoint: omitted"))
        XCTAssertFalse(report.contains("endpoint-id:"))
        XCTAssertFalse(report.contains("private.example"))
        XCTAssertFalse(report.contains("alice"))
        XCTAssertFalse(report.contains("backend secret detail"))
    }

    func testDiagnosticReportIncludesAvailableHealthWithoutEndpointData() {
        let profile = ConnectionProfile(name: "Remote", transport: .rdp, host: "192.0.2.4")
        let health = SessionHealth(tcpConnectionMilliseconds: 18, packetLossPercent: nil,
                                   codec: "RemoteFX", roundTripMilliseconds: 42)
        let report = DiagnosticReport.text(profile: profile, status: .connected, health: health)
        XCTAssertTrue(report.contains("tcp-connect-ms: 18"))
        XCTAssertTrue(report.contains("rdp-round-trip-ms: 42"))
        XCTAssertTrue(report.contains("packet-loss-percent: unavailable"))
        XCTAssertTrue(report.contains("graphics-codec: RemoteFX"))
        XCTAssertFalse(report.contains(profile.host))
    }

    func testDiagnosticReportIncludesOnlyKnownRDPPhases() {
        let profile = ConnectionProfile(name: "Remote", transport: .rdp, host: "192.0.2.4")
        let valid = DiagnosticReport.text(profile: profile, status: .connecting,
                                          connectionPhase: "CONNECTION_STATE_NEGO")
        XCTAssertTrue(valid.contains("rdp-connection-phase: CONNECTION_STATE_NEGO"))
        let unsafe = DiagnosticReport.text(profile: profile, status: .connecting,
                                           connectionPhase: "password=private")
        XCTAssertTrue(unsafe.contains("rdp-connection-phase: unavailable"))
        XCTAssertFalse(unsafe.contains("private"))
    }

    func testDiagnosticReportIncludesSafeNegotiatedSecurityProtocols() {
        let profile = ConnectionProfile(name: "Remote", transport: .rdp, host: "192.0.2.4")
        let report = DiagnosticReport.text(profile: profile, status: .disconnected(reason: "failure"),
                                           requestedSecurityProtocols: 0x0B,
                                           selectedSecurityProtocol: 8)
        XCTAssertTrue(report.contains("rdp-requested-security-protocols: 0x0000000B"))
        XCTAssertTrue(report.contains("rdp-selected-security-protocol: NLA-Extended"))
        XCTAssertFalse(report.contains(profile.host))
    }

    func testSecurityProtocolsAreUnavailableBeforeNegotiationCompletes() {
        let profile = ConnectionProfile(name: "Remote", transport: .rdp, host: "192.0.2.4")
        let report = DiagnosticReport.text(profile: profile, status: .disconnected(reason: "failure"),
                                           connectionPhase: "CONNECTION_STATE_NEGO",
                                           requestedSecurityProtocols: 0,
                                           selectedSecurityProtocol: 0)
        XCTAssertTrue(report.contains("rdp-requested-security-protocols: unavailable"))
        XCTAssertTrue(report.contains("rdp-selected-security-protocol: unavailable"))
    }

    func testNegotiatedProtocolRemainsVisibleDuringNLAFailure() {
        let profile = ConnectionProfile(name: "Remote", transport: .rdp, host: "192.0.2.4")
        let report = DiagnosticReport.text(profile: profile, status: .disconnected(reason: "failure"),
                                           connectionPhase: "CONNECTION_STATE_NEGO",
                                           requestedSecurityProtocols: 0x0B,
                                           selectedSecurityProtocol: 0x08)
        XCTAssertTrue(report.contains("rdp-requested-security-protocols: 0x0000000B"))
        XCTAssertTrue(report.contains("rdp-selected-security-protocol: NLA-Extended"))
    }

    func testVNCReportIncludesOnlyNegotiatedSecuritySummary() {
        let profile = ConnectionProfile(name: "Remote", transport: .vnc,
                                        host: "private.example", username: "private-user")
        let report = DiagnosticReport.text(profile: profile, status: .disconnected(reason: "secret"),
                                           vncSecurity: .veNCryptX509VNCVerified)
        XCTAssertTrue(report.contains("vnc-negotiated-security: VeNCrypt X509Vnc; TLS and certificate validation succeeded"))
        XCTAssertTrue(report.contains("credentials: omitted"))
        XCTAssertFalse(report.contains("private.example"))
        XCTAssertFalse(report.contains("private-user"))
        XCTAssertFalse(report.contains("secret"))

        let unavailable = DiagnosticReport.text(profile: profile, status: .connecting)
        XCTAssertTrue(unavailable.contains("vnc-negotiated-security: unavailable"))

        let tlsFailure = DiagnosticReport.text(profile: profile, status: .disconnected(reason: "failure"),
                                               vncTLSFailureCode: -9807)
        XCTAssertTrue(tlsFailure.contains("vnc-tls-error-code: -9807"))
        XCTAssertFalse(tlsFailure.contains("private.example"))

        let nonVNC = DiagnosticReport.text(
            profile: ConnectionProfile(name: "Remote", transport: .rdp, host: "private.example"),
            status: .connecting,
            vncSecurity: .veNCryptX509VNCVerified
        )
        XCTAssertTrue(nonVNC.contains("vnc-negotiated-security: unavailable"))
        XCTAssertTrue(nonVNC.contains("vnc-tls-error-code: unavailable"))
    }

    func testDiagnosticReportIncludesOnlyCredentialPresenceBits() {
        let profile = ConnectionProfile(name: "Remote", transport: .rdp, host: "192.0.2.4", username: "private-user")
        let report = DiagnosticReport.text(profile: profile, status: .disconnected(reason: "failure"), inputState: 7)
        XCTAssertTrue(report.contains("rdp-arguments-parsed: yes"))
        XCTAssertTrue(report.contains("rdp-username-configured: yes"))
        XCTAssertTrue(report.contains("rdp-password-configured: yes"))
        XCTAssertFalse(report.contains("private-user"))
        XCTAssertFalse(report.contains("password="))

        let missing = DiagnosticReport.text(profile: profile, status: .disconnected(reason: "failure"), inputState: 1)
        XCTAssertTrue(missing.contains("rdp-arguments-parsed: yes"))
        XCTAssertTrue(missing.contains("rdp-username-configured: no"))
        XCTAssertTrue(missing.contains("rdp-password-configured: no"))
    }

    func testDiagnosticReportWritesToSelectedFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("diagnostic.txt")
        let profile = ConnectionProfile(name: "Private", transport: .rdp, host: "private.example")

        try DiagnosticReport.write(profile: profile, status: .connected,
                                   to: destination, now: Date(timeIntervalSince1970: 0))

        let saved = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(saved.contains("state: connected"))
        XCTAssertFalse(saved.contains("private.example"))
    }

    func testDiagnosticReportPropagatesFileWriteFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = ConnectionProfile(name: "Private", transport: .rdp, host: "private.example")

        XCTAssertThrowsError(try DiagnosticReport.write(profile: profile, status: .connected,
                                                        to: directory))
    }
}
