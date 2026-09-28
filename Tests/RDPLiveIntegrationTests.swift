import XCTest
import Combine
@testable import FjarrConnect

/// Opt-in authenticated test against the developer's saved Windows profile.
/// Credentials stay in Keychain and are only held in memory by the session.
final class RDPLiveIntegrationTests: XCTestCase {
    @MainActor
    func testAuthenticatedLiveRDPDisplaysFirstDesktopFrame() async throws {
        guard ProcessInfo.processInfo.environment["FJARRCONNECT_TEST_LIVE_RDP"] == "1",
              let host = ProcessInfo.processInfo.environment["FJARRCONNECT_TEST_LIVE_RDP_HOST"],
              ConnectionURI.validHost(host),
              let runtimePath = ProcessInfo.processInfo.environment["FJARRCONNECT_RDP_LIBRARY"],
              runtimePath.hasPrefix("/") else {
            throw XCTSkip("Opt in with a host and bundled RDP runtime path; credentials are read from the saved Keychain profile")
        }

        let store = ProfileStore()
        guard var profile = store.profiles.first(where: {
            $0.host == host && $0.transport == .rdp
        }) else {
            throw XCTSkip("No saved RDP profile exists for the selected host")
        }
        guard !profile.requiresBiometricUnlock else {
            throw XCTSkip("The saved profile requires interactive biometric authentication")
        }
        let password: String?
        do {
            password = try KeychainStore.password(for: profile.id)
        } catch {
            throw XCTSkip("The test host cannot access the saved credential; run the check from FjarrConnect")
        }
        guard let password else {
            throw XCTSkip("The saved RDP profile has no Keychain credential")
        }

        var options = profile.rdp ?? RDPOptions()
        options.clipboardFiles = true
        profile.rdp = options
        profile.clipboardEnabled = true
        let runtime = try XCTUnwrap(RDPRuntime(path: runtimePath))
        let session = RDPRemoteSession(profile: profile, password: password, runtime: runtime)
        let connected = expectation(description: "Live RDP session established")
        var didResolve = false
        let statusObservation = session.$status.sink { status in
            guard !didResolve, status.isEstablished || status.isFinished else { return }
            didResolve = true
            connected.fulfill()
        }
        defer {
            statusObservation.cancel()
            session.stop()
        }

        session.start()
        await fulfillment(of: [connected], timeout: 40)
        XCTAssertEqual(session.status, .connected,
                       "Live RDP failed: phase=\(session.connectionPhase ?? "unavailable"), " +
                       "requested=\(session.requestedSecurityProtocols.map { String(format: "0x%08X", $0) } ?? "unavailable"), " +
                       "selected=\(session.selectedSecurityProtocol.map(String.init) ?? "unavailable"), " +
                       "security-mode=\(profile.rdp?.selectedSecurityMode.rawValue ?? "automatic").")
        guard session.status == .connected else { return }

        let firstFrame = expectation(description: "Live RDP desktop frame received")
        let frameObservation = session.$hasReceivedFrame.sink { received in
            if received { firstFrame.fulfill() }
        }
        defer { frameObservation.cancel() }
        await fulfillment(of: [firstFrame], timeout: 20)
        XCTAssertTrue(session.hasReceivedFrame, "The live Windows session connected but sent no desktop frame")
    }
}
