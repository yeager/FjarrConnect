import XCTest
@testable import FjarrConnect

final class RDPRuntimeTests: XCTestCase {
    func testMissingRuntimeFileHasSpecificFailure() {
        let missingPath = NSTemporaryDirectory()
            + "FjarrConnect-missing-rdp-\(UUID().uuidString).dylib"
        var failure: RDPRuntime.LoadFailure?

        XCTAssertNil(RDPRuntime(path: missingPath) { failure = $0 })
        XCTAssertEqual(failure, .missingFile)
    }

    func testDyldFailuresAreReducedToSafeCategories() {
        XCTAssertEqual(
            RDPRuntime.LoadFailure.classifyDyldError("mach-o, but wrong architecture"),
            .architectureMismatch
        )
        XCTAssertEqual(
            RDPRuntime.LoadFailure.classifyDyldError("code signature invalid"),
            .signatureRejected
        )
        XCTAssertEqual(
            RDPRuntime.LoadFailure.classifyDyldError("Library not loaded: image not found"),
            .dependencyUnavailable
        )
        XCTAssertEqual(
            RDPRuntime.LoadFailure.classifyDyldError("unrecognized loader failure"),
            .loadFailed
        )
    }
}
