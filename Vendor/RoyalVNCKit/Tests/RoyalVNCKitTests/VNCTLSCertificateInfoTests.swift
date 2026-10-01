import Foundation
import XCTest

@testable import RoyalVNCKit

final class VNCTLSCertificateInfoTests: XCTestCase {
    func testFingerprintIsSHA256OfTheDEREncodedPeerCertificate() {
        let certificate = VNCTLSCertificateInfo(
            subjectSummary: "localhost",
            derEncodedCertificate: Data("abc".utf8)
        )

        XCTAssertEqual(certificate.subjectSummary, "localhost")
        XCTAssertEqual(certificate.sha256Fingerprint,
                       "BA:78:16:BF:8F:01:CF:EA:41:41:40:DE:5D:AE:22:23:" +
                       "B0:03:61:A3:96:17:7A:9C:B4:10:FF:61:F2:00:15:AD")
    }

    func testVeNCryptDiagnosticsDistinguishSelectedFromVerifiedTLS() {
        XCTAssertEqual(VNCNegotiatedSecurity.veNCryptX509VNCSelected.tlsCertificateWasVerified, false)
        XCTAssertEqual(VNCNegotiatedSecurity.veNCryptX509PlainSelected.tlsCertificateWasVerified, false)
        XCTAssertEqual(VNCNegotiatedSecurity.veNCryptX509VNCVerified.tlsCertificateWasVerified, true)
        XCTAssertEqual(VNCNegotiatedSecurity.veNCryptX509PlainVerified.tlsCertificateWasVerified, true)
        XCTAssertNil(VNCNegotiatedSecurity.vncPassword.tlsCertificateWasVerified)
        XCTAssertEqual(VNCNegotiatedSecurity.veNCryptX509VNCVerified.protocolName, "VeNCrypt X509Vnc")
        XCTAssertEqual(VNCNegotiatedSecurity.veNCryptX509PlainSelected.protocolName, "VeNCrypt X509Plain")
    }
}
