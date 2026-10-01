import XCTest
import Combine
import SwiftUI
@testable import FjarrConnect

private struct LiveRDPIntegrationScreen: View {
    @ObservedObject var session: RDPRemoteSession
    var body: some View { session.makeScreenView() }
}

/// Opt-in authenticated test against a saved RDP profile.
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
        let negotiationOnly = ProcessInfo.processInfo.environment["FJARRCONNECT_TEST_LIVE_RDP_NEGOTIATION_ONLY"] == "1"
        guard let savedProfile = store.profiles.first(where: {
            $0.host == host && $0.transport == .rdp
        }) else {
            throw XCTSkip("No saved RDP profile exists for the selected host")
        }
        guard !savedProfile.requiresBiometricUnlock else {
            throw XCTSkip("The saved profile requires interactive biometric authentication")
        }
        let password: String?
        if negotiationOnly {
            password = nil
        } else {
            do {
                password = try KeychainStore.password(for: savedProfile.id)
            } catch {
                throw XCTSkip("The test host cannot access the saved credential; run the check from FjarrConnect")
            }
        }
        if !negotiationOnly, password == nil {
            throw XCTSkip("The saved RDP profile has no Keychain credential")
        }

        var profile = savedProfile
        if let connectHost = ProcessInfo.processInfo.environment["FJARRCONNECT_TEST_LIVE_RDP_CONNECT_HOST"],
           let connectPort = ProcessInfo.processInfo.environment["FJARRCONNECT_TEST_LIVE_RDP_CONNECT_PORT"].flatMap(UInt16.init) {
            profile.host = connectHost
            profile.port = connectPort
        }
        if let requestedMode = ProcessInfo.processInfo.environment["FJARRCONNECT_TEST_LIVE_RDP_SECURITY"] {
            guard let mode = RDPOptions.SecurityMode(rawValue: requestedMode) else {
                XCTFail("FJARRCONNECT_TEST_LIVE_RDP_SECURITY must name a supported security mode")
                return
            }
            profile.rdp = profile.rdp ?? RDPOptions()
            profile.rdp?.securityMode = mode
        }

        let runtime = try XCTUnwrap(RDPRuntime(path: runtimePath))
        let session = RDPRemoteSession(profile: profile, password: password, runtime: runtime)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
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
        window.contentView = NSHostingView(rootView: LiveRDPIntegrationScreen(session: session))
        window.makeKeyAndOrderFront(nil)
        await fulfillment(of: [connected], timeout: 40)
        if negotiationOnly {
            XCTAssertEqual(session.requestedSecurityProtocols, 0x0B,
                           "Expected FreeRDP's automatic TLS/NLA/NLA-Extended request mask; " +
                           "phase=\(session.connectionPhase ?? "unavailable")")
            XCTAssertEqual(session.selectedSecurityProtocol, 0x08,
                           "Expected the server to select NLA Extended; phase=\(session.connectionPhase ?? "unavailable"), " +
                           "input-state=0x\(String(session.inputState ?? 0, radix: 16))")
            return
        }
        XCTAssertEqual(session.status, .connected,
                       "Live RDP failed: phase=\(session.connectionPhase ?? "unavailable"), " +
                       "requested=\(session.requestedSecurityProtocols.map { String(format: "0x%08X", $0) } ?? "unavailable"), " +
                       "selected=\(session.selectedSecurityProtocol.map(String.init) ?? "unavailable"), " +
                       "security-mode=\(profile.rdp?.selectedSecurityMode.rawValue ?? "automatic"), " +
                       "input-state=0x\(String(session.inputState ?? 0, radix: 16)).")
        guard session.status == .connected else { return }

        let expectsRTT = ProcessInfo.processInfo.environment["FJARRCONNECT_TEST_EXPECT_RDP_RTT"] == "1"
        let rttPublished = expectsRTT ? expectation(description: "RDP RTT is published to SwiftUI") : nil
        var observedRTT: Int?
        let rttObservation = expectsRTT ? session.$roundTripMilliseconds.sink { value in
            guard let value else { return }
            observedRTT = value
            rttPublished?.fulfill()
        } : nil
        defer { rttObservation?.cancel() }

        let firstFrame = expectation(description: "Live RDP desktop frame received")
        let frameObservation = session.$hasReceivedFrame.sink { received in
            if received { firstFrame.fulfill() }
        }
        defer { frameObservation.cancel() }
        await fulfillment(of: [firstFrame], timeout: 20)
        XCTAssertTrue(session.hasReceivedFrame, "The live RDP session connected but sent no desktop frame")
        if let rttPublished {
            await fulfillment(of: [rttPublished], timeout: 10)
            XCTAssertGreaterThan(observedRTT ?? 0, 0,
                                 "The server did not publish a FreeRDP RTT measurement after desktop activation")
        }
        let embedded = await waitForUI(timeout: 5) {
            session.recordingView?.window === window
        }
        XCTAssertTrue(embedded, "The live RDP view was not embedded in the app window")
    }

    @MainActor
    private func waitForUI(timeout: TimeInterval, condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
