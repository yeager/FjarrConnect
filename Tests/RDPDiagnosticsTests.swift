import XCTest
@testable import FjarrConnect

final class RDPDiagnosticsTests: XCTestCase {
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
}
