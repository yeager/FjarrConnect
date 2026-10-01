import XCTest
import Combine
import SwiftUI
@testable import RoyalVNCKit
@testable import FjarrConnect

private struct VNCSessionScreenView: View {
    @ObservedObject var session: VNCRemoteSession
    var body: some View { session.makeScreenView() }
}

private final class CursorTrackingWindow: NSWindow {
    private(set) var cursorRectInvalidations = 0
    var simulatedPointerLocation = NSPoint.zero

    override var isKeyWindow: Bool { true }

    override var mouseLocationOutsideOfEventStream: NSPoint {
        simulatedPointerLocation
    }

    override func invalidateCursorRects(for view: NSView) {
        cursorRectInvalidations += 1
        super.invalidateCursorRects(for: view)
    }
}

private final class VNCKeyboardFocusTestView: NSView {
    override var canBecomeKeyView: Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

/// A local RFB server exercises the actual RoyalVNCKit handshake and session lifecycle.
final class VNCIntegrationTests: XCTestCase {
    @MainActor
    func testVNCConnectsToLocalServerAndStops() async throws {
        try await exerciseServer(requiresUsername: false, expectedNegotiatedSecurity: VNCNegotiatedSecurity.none)
    }

    func testMacScreenSharingRetriesOneSilentFirstConnection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let portFile = directory.appendingPathComponent("port")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-c", Self.server, portFile.path, "retry-once", portFile.path + ".uploaded"]
        server.standardOutput = FileHandle.nullDevice
        server.environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("XCTest") && !$0.key.hasPrefix("XCInject")
        }
        try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        let ready = expectation(description: "retry fixture ready")
        DispatchQueue.global().async {
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: portFile.path) || !server.isRunning { ready.fulfill(); return }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        wait(for: [ready], timeout: 12)
        let port = try XCTUnwrap(UInt16(String(contentsOf: portFile, encoding: .utf8)))
        let profile = ConnectionProfile(name: "Retry fixture", host: "127.0.0.1", port: port,
                                        username: "test", usesMacScreenSharingAuthentication: true)
        let session = VNCRemoteSession(profile: profile, password: "test-only", connectionTimeout: 0.35)
        defer { session.stop() }
        let connected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in session.status == .connected }, object: nil)
        session.start()
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 8), .completed)
        XCTAssertEqual(session.status, .connected)
        XCTAssertEqual(try String(contentsOf: portFile.appendingPathExtension("count"), encoding: .utf8), "2")
    }

    func testMacScreenSharingRetriesOneFailedHandshake() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let portFile = directory.appendingPathComponent("port")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-c", Self.server, portFile.path, "close-once", portFile.path + ".uploaded"]
        server.standardOutput = FileHandle.nullDevice
        server.environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("XCTest") && !$0.key.hasPrefix("XCInject")
        }
        try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        let ready = expectation(description: "failed-handshake fixture ready")
        DispatchQueue.global().async {
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: portFile.path) || !server.isRunning { ready.fulfill(); return }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        wait(for: [ready], timeout: 12)
        let port = try XCTUnwrap(UInt16(String(contentsOf: portFile, encoding: .utf8)))
        let profile = ConnectionProfile(name: "Failed-handshake fixture", host: "127.0.0.1", port: port,
                                        username: "test", usesMacScreenSharingAuthentication: true)
        let session = VNCRemoteSession(profile: profile, password: "test-only", connectionTimeout: 2)
        defer { session.stop() }
        let connected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in session.status == .connected }, object: nil)
        session.start()
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 8), .completed)
        XCTAssertEqual(session.status, .connected)
        XCTAssertEqual(try String(contentsOf: portFile.appendingPathExtension("count"), encoding: .utf8), "2")
    }

    @MainActor
    func testAppleVNCExplainsMissingUsername() async throws {
        try await exerciseServer(requiresUsername: true)
    }

    func testCursorPointSizeAndHotspotFollowFramebufferScale() {
        let pixels = Data(repeating: 0xFF, count: 3 * 2 * 4)
        let cursor = VNCCursor(imageData: pixels,
                               size: VNCSize(width: 3, height: 2),
                               hotspot: VNCPoint(x: 2, y: 1),
                               bitsPerComponent: 8,
                               bitsPerPixel: 32,
                               bytesPerPixel: 4)

        let displayed = cursor.nsCursor(scaleFactor: 0.5)

        XCTAssertEqual(displayed.image.size, CGSize(width: 1.5, height: 1))
        XCTAssertEqual(displayed.hotSpot, CGPoint(x: 1, y: 0.5))
    }

    func testLiveAppleVNCReachesRequiredUsernamePromptWithoutCredentials() throws {
        guard let host = ProcessInfo.processInfo.environment["FJARRCONNECT_TEST_LIVE_MAC_VNC_HOST"],
              ConnectionURI.validHost(host) else {
            throw XCTSkip("Set FJARRCONNECT_TEST_LIVE_MAC_VNC_HOST in the Xcode scheme's Launch environment to opt in to a credential-free Mac VNC handshake check")
        }
        let profile = ConnectionProfile(name: "Live Mac VNC", host: host,
                                        usesMacScreenSharingAuthentication: true)
        let session = VNCRemoteSession(profile: profile, password: nil)
        let disconnected = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in session.status.isFinished },
            object: nil
        )
        defer { session.stop() }

        session.start()
        XCTAssertEqual(XCTWaiter.wait(for: [disconnected], timeout: 23), .completed,
                       "The server should reach authentication or a bounded connection timeout")
        XCTAssertTrue(session.serverRequiresMacAccount,
                      "The client must parse the Mac Screen Sharing authentication challenge")
        XCTAssertEqual(session.status.error, NSLocalizedString("vnc.usernameRequired", comment: ""))
    }

    @MainActor
    func testAuthenticatedLiveMacVNCUsesSavedKeychainProfileAndReportsCapabilities() async throws {
        guard ProcessInfo.processInfo.environment["FJARRCONNECT_TEST_LIVE_MAC_VNC_AUTHENTICATED"] == "1",
              let host = ProcessInfo.processInfo.environment["FJARRCONNECT_TEST_LIVE_MAC_VNC_HOST"],
              ConnectionURI.validHost(host) else {
            throw XCTSkip("Opt in with FJARRCONNECT_TEST_LIVE_MAC_VNC_AUTHENTICATED=1 and FJARRCONNECT_TEST_LIVE_MAC_VNC_HOST; credentials are read from the saved profile Keychain item")
        }
        let store = ProfileStore()
        guard let profile = store.profiles.first(where: {
            $0.host == host && $0.transport == .vnc
        }) else {
            throw XCTSkip("No saved VNC profile exists for the selected host")
        }
        guard !profile.requiresBiometricUnlock else {
            throw XCTSkip("The saved profile requires interactive biometric authentication")
        }
        guard let username = profile.username, !username.isEmpty else {
            throw XCTSkip("The saved Mac Screen Sharing profile has no username")
        }
        let password: String?
        do {
            password = try KeychainStore.password(for: profile.id)
        } catch {
            throw XCTSkip("The test host cannot access this saved credential; run the live check from FjarrConnect")
        }
        guard let password else {
            throw XCTSkip("The saved profile has no Keychain credential")
        }

        var macProfile = profile
        macProfile.username = username
        macProfile.usesMacScreenSharingAuthentication = true
        let session = VNCRemoteSession(profile: macProfile, password: password)
        let hostingView = NSHostingView(rootView: VNCSessionScreenView(session: session))
        let testWindow = CursorTrackingWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                                              styleMask: [.titled], backing: .buffered, defer: false)
        testWindow.isReleasedWhenClosed = false
        testWindow.contentView = hostingView
        testWindow.makeKeyAndOrderFront(nil)
        let resolved = expectation(description: "Authenticated live VNC connection resolves")
        var didResolve = false
        let subscription = session.$status.sink { status in
            guard !didResolve, status.isEstablished || status.isFinished else { return }
            didResolve = true
            resolved.fulfill()
        }
        defer {
            subscription.cancel()
            session.stop()
            testWindow.close()
        }

        session.start()
        // Apple Screen Sharing may be silent on the first connection. The
        // session retries once after its 20-second deadline.
        await fulfillment(of: [resolved], timeout: 45)
        XCTAssertTrue(session.status.isEstablished,
                      "The saved Mac VNC profile did not connect: \(session.status.error ?? session.status.label); " +
                      "mac-account-challenge=\(session.serverRequiresMacAccount), " +
                      "username-challenge=\(session.serverRequiresUsername), " +
                      "saved-credentials-rejected=\(session.savedCredentialsRejected)")
        guard session.status.isEstablished else { return }

        print("[VNC live] Mac Screen Sharing authenticated; file-list/download=\(session.fileTransferAvailable); upload=\(session.fileUploadAvailable)")
        let framebuffer = session.recordingView as? VNCCAFramebufferView
        let visibleMetalLayer = framebuffer?.layer?.sublayers?.contains { layer in
            layer is CAMetalLayer && !layer.isHidden
        } ?? false
        print("[VNC live] framebuffer-created=\(framebuffer != nil); framebuffer-size=\(framebuffer?.framebufferSize.width ?? 0)x\(framebuffer?.framebufferSize.height ?? 0); metal-layer-active=\(visibleMetalLayer)")
        XCTAssertNotNil(framebuffer, "An established VNC session should install its framebuffer in the application session")
        XCTAssertTrue(framebuffer?.currentCursor === NSCursor.arrow,
                      "Keep a visible local pointer until a VNC server supplies a remote shape")
        if let framebuffer, let window = framebuffer.window as? CursorTrackingWindow {
            let localPoint = NSPoint(x: min(max(24, framebuffer.bounds.midX), framebuffer.bounds.maxX - 24),
                                     y: min(max(24, framebuffer.bounds.midY), framebuffer.bounds.maxY - 24))
            let point = framebuffer.convert(localPoint, to: nil)
            window.simulatedPointerLocation = point
            _ = window.makeFirstResponder(framebuffer)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved,
                                                        location: point,
                                                        modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber,
                                                        context: nil,
                                                        eventNumber: 0,
                                                        clickCount: 0,
                                                        pressure: 0))
            framebuffer.mouseMoved(with: event)
        }
        let cursorReceived = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let cursor = framebuffer?.remoteCursor else { return false }
            return !cursor.isEmpty
        }, object: nil)
        await fulfillment(of: [cursorReceived], timeout: 8)
        if let cursor = framebuffer?.remoteCursor, !cursor.isEmpty {
            print("[VNC live] server cursor shape=\(cursor.size.width)x\(cursor.size.height); hotspot=\(cursor.hotspot.x),\(cursor.hotspot.y)")
        } else if framebuffer?.remoteCursor?.isEmpty == true {
            print("[VNC live] server sent an empty cursor shape; client uses the dot fallback")
            XCTAssertEqual(framebuffer?.currentCursor.image.size, CGSize(width: 9, height: 9),
                           "An empty server cursor shape should use the centered dot fallback")
        } else {
            print("[VNC live] server cursor shape=not-sent; local arrow remains visible")
            XCTAssertTrue(framebuffer?.currentCursor === NSCursor.arrow)
        }
    }

#if canImport(CFNetwork)
    func testLiveVeNCryptCompletesVerifiedTLSBeforeSendingCredentials() async throws {
        guard let host = ProcessInfo.processInfo.environment["FJARRCONNECT_TEST_LIVE_VENCRYPT_HOST"],
              ConnectionURI.validHost(host) else {
            throw XCTSkip("Set FJARRCONNECT_TEST_LIVE_VENCRYPT_HOST to opt in to a credential-free VeNCrypt/TLS check")
        }
        let port = UInt16(ProcessInfo.processInfo.environment["FJARRCONNECT_TEST_LIVE_VENCRYPT_PORT"] ?? "5900") ?? 5900
        let connection = CFStreamNetworkConnection(settings: NetworkConnectionSettings(
            connectionTimeout: 8, host: host, port: port
        ))
        defer { connection.cancel() }

        let ready = expectation(description: "VNC TCP stream ready")
        connection.setStatusUpdateHandler { status in
            if case .ready = status { ready.fulfill() }
        }
        connection.start(queue: DispatchQueue(label: "FjarrConnect.LiveVeNCryptTest"))
        await fulfillment(of: [ready], timeout: 8)
        guard connection.isReady else {
            XCTFail("The server did not accept a TCP connection within 8 seconds")
            return
        }

        let greeting = try await connection.read(minimumLength: 12, maximumLength: 12)
        let greetingText = String(decoding: greeting, as: UTF8.self)
        guard greetingText.hasPrefix("RFB 003.") else {
            XCTFail("The server sent an invalid RFB version greeting")
            return
        }
        guard let serverMinor = Int(greetingText.dropFirst(8).prefix(3)) else {
            XCTFail("The server sent an invalid RFB version")
            return
        }
        let negotiatedMinor = min(serverMinor, 8)
        try await connection.write(data: Data(String(format: "RFB 003.%03d\n", negotiatedMinor).utf8))

        if serverMinor < 7 {
            let securityType = try await connection.readUInt32()
            if securityType == 0 {
                let reasonLength = Int(try await connection.readUInt32())
                guard (1...4096).contains(reasonLength) else {
                    XCTFail("The server refused the RFB handshake without a valid reason string")
                    return
                }
                let reason = try await connection.read(minimumLength: reasonLength,
                                                       maximumLength: reasonLength)
                XCTFail("The server refused the RFB handshake: \(String(decoding: reason, as: UTF8.self))")
                return
            }
            guard securityType == 19 else {
                XCTFail("RFB 3.3 server selected security type \(securityType), expected VeNCrypt (19)")
                return
            }
        } else {
            let securityTypeCount = Int(try await connection.readUInt8())
            guard securityTypeCount > 0 else {
                XCTFail("The server did not offer an RFB security type")
                return
            }
            let securityTypes = try await connection.read(minimumLength: securityTypeCount,
                                                          maximumLength: securityTypeCount)
            guard securityTypes.contains(19) else {
                XCTFail("The server did not offer VeNCrypt")
                return
            }
            try await connection.write(value: 19)
        }

        let version = try await connection.read(minimumLength: 2, maximumLength: 2)
        guard version == Data([0, 2]) else {
            XCTFail("The server must offer VeNCrypt 0.2")
            return
        }
        try await connection.write(data: Data([0, 2]))
        let versionAcknowledgement = try await connection.readUInt8()
        guard versionAcknowledgement == 0 else {
            XCTFail("The server rejected VeNCrypt 0.2")
            return
        }

        let subtypeCount = Int(try await connection.readUInt8())
        guard subtypeCount > 0 else {
            XCTFail("VeNCrypt must offer at least one subtype")
            return
        }
        let subtypeBytes = try await connection.read(minimumLength: subtypeCount * 4,
                                                     maximumLength: subtypeCount * 4)
        let subtypes = stride(from: 0, to: subtypeBytes.count, by: 4).map { offset in
            subtypeBytes[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        guard subtypes.contains(261) else {
            XCTFail("The server must offer certificate-validated X509Vnc")
            return
        }
        try await connection.write(value: 0)
        try await connection.write(data: Data([0, 0, 1, 5]))
        let subtypeAcknowledgement = try await connection.readUInt8()
        guard subtypeAcknowledgement == 1 else {
            XCTFail("The server rejected X509Vnc")
            return
        }

        try await connection.upgradeToTLS(serverName: host)

        // Reading the VNC challenge forces CFStream to complete and validate the
        // TLS handshake. Stop here: the test never sends a password response.
        let challenge = try await connection.read(minimumLength: 16, maximumLength: 16)
        XCTAssertEqual(challenge.count, 16, "The server should begin VNC authentication inside TLS")
    }
#endif

    @MainActor
    func testVNCAuthenticatesWithPasswordAndReceivesDesktop() async throws {
        try await exerciseServer(requiresUsername: false, requiresPassword: true,
                           expectedNegotiatedSecurity: .vncPassword)
    }

    @MainActor
    func testRejectedVNCPasswordIsReportedForCredentialRetry() async throws {
        try await exerciseServer(requiresUsername: false, requiresPassword: true,
                           clientPassword: "wrong-test-password", expectsCredentialRejection: true)
    }

    @MainActor
    func testTightFileBrowserAppearsWhenTheServerAdvertisesDownloadChannels() async throws {
        try await exerciseServer(requiresUsername: false, tightFileTransfer: true)
    }

    @MainActor
    func testTightReadOnlyServerStillOffersFileDownloads() async throws {
        try await exerciseServer(requiresUsername: false, tightDownloadOnly: true)
    }

    @MainActor
    func testTightUploadSendsFileWhenServerAdvertisesUploadChannel() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("fjarrconnect-upload-fixture.txt")
        let payload = Data((0..<150_000).map { UInt8($0 % 251) })
        try payload.write(to: source, options: .atomic)
        defer { try? FileManager.default.removeItem(at: source) }
        try await exerciseServer(requiresUsername: false, uploadFile: source, expectedUpload: payload)
    }

    @MainActor
    func testTightUploadSendsDroppedFilesSequentially() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = [directory.appendingPathComponent("first.txt"), directory.appendingPathComponent("second.bin")]
        let payloads = [Data("first-file".utf8), Data((0..<90_000).map { UInt8($0 % 239) })]
        for (source, payload) in zip(sources, payloads) { try payload.write(to: source, options: .atomic) }
        try await exerciseServer(requiresUsername: false, uploadFiles: sources, expectedUploads: payloads)
    }

    @MainActor
    func testBlackDesktopHintClearsWhenServerStartsSendingContent() async throws {
        try await exerciseServer(requiresUsername: false, blackInitially: true)
    }

    @MainActor
    func testDesktopResizeReplacesTheDisplayedFramebuffer() async throws {
        try await exerciseServer(requiresUsername: false, resize: true)
    }

    @MainActor
    func testEmptyRemoteCursorUsesDotFallbackInRenderedSession() async throws {
        try await exerciseServer(requiresUsername: false, emptyCursor: true)
    }

    @MainActor
    func testConnectedVNCDesktopReceivesInitialKeyboardFocus() async throws {
        try await exerciseServer(requiresUsername: false, verifyInitialFocus: true)
    }

    @MainActor
    func testInternationalKeyboardCharactersReachVNCServer() async throws {
        try await exerciseServer(requiresUsername: false, keyboard: true)
    }

    func testVNCFailureMessageIsLocalizedAndDoesNotContainBackendDiagnostics() {
        let message = VNCRemoteSession.connectionFailureMessage(host: "desktop.local", port: 5901)
        XCTAssertTrue(message.contains("desktop.local:5901"))
        XCTAssertTrue(message.contains(NSLocalizedString("vnc.connectionFailed", comment: "")))
        XCTAssertFalse(message.contains("ERRCONNECT"))
    }

    func testVNCUnsupportedSecurityExplainsTheProtocolLimitation() {
        let message = VNCRemoteSession.connectionFailureMessage(
            host: "desktop.local",
            port: 5901,
            error: VNCError.authentication(.clientCouldNotDecideOnSecurityType)
        )
        XCTAssertTrue(message.contains("desktop.local:5901"))
        XCTAssertTrue(message.contains(NSLocalizedString("vnc.unsupportedSecurity", comment: "")))
        XCTAssertFalse(message.contains("could not decide"))
    }

    func testVNCTLSFailureHasSafeLocalizedGuidance() {
        let message = VNCRemoteSession.connectionFailureMessage(
            host: "desktop.local", port: 5901, tlsFailureCode: -9807
        )
        XCTAssertTrue(message.contains("desktop.local:5901"))
        XCTAssertTrue(message.contains(NSLocalizedString("vnc.tlsHandshakeFailed", comment: "")))
        XCTAssertFalse(message.contains("-9807"))
    }

    func testMacScreenSharingAuthenticationFailureExplainsAccountChecks() {
        let message = VNCRemoteSession.connectionFailureMessage(
            host: "desktop.local",
            port: 5900,
            error: VNCError.authentication(.securityHandshakingFailed(reason: nil)),
            authentication: .appleRemoteDesktop
        )
        XCTAssertTrue(message.contains("desktop.local:5900"))
        XCTAssertTrue(message.contains(NSLocalizedString("vnc.macAuthenticationRejected", comment: "")))
        XCTAssertFalse(message.contains("securityHandshakingFailed"))
    }

    func testRejectedSavedVNCPasswordIsDetectedWithoutExposingServerText() {
        XCTAssertTrue(VNCRemoteSession.shouldOfferCredentialRetry(
            passwordWasProvided: true, authentication: .appleRemoteDesktop,
            error: VNCError.authentication(.securityHandshakingFailed(reason: "private server detail"))))
        XCTAssertFalse(VNCRemoteSession.shouldOfferCredentialRetry(
            passwordWasProvided: true, authentication: .appleRemoteDesktop,
            error: VNCError.authentication(.clientCouldNotDecideOnSecurityType)))
        XCTAssertFalse(VNCRemoteSession.shouldOfferCredentialRetry(
            passwordWasProvided: false, authentication: .appleRemoteDesktop,
            error: VNCError.authentication(.securityHandshakingFailed(reason: nil))))
        XCTAssertFalse(VNCRemoteSession.shouldOfferCredentialRetry(
            passwordWasProvided: true, authentication: nil,
            error: VNCError.authentication(.securityHandshakingFailed(reason: nil))))
    }

    func testOnlyTransientMacScreenSharingHandshakeFailuresRetryOnce() {
        let handshakeClosed = VNCError.ConnectionError.closedDuringHandshake(
            handshakingPhase: "Receive Server Init", underlyingError: nil
        )
        XCTAssertTrue(VNCRemoteSession.shouldRetryInitialMacScreenSharingConnection(
            usesMacScreenSharingAuthentication: true, passwordWasProvided: true,
            retryAlreadyUsed: false, status: .connecting, error: handshakeClosed
        ))
        XCTAssertFalse(VNCRemoteSession.shouldRetryInitialMacScreenSharingConnection(
            usesMacScreenSharingAuthentication: true, passwordWasProvided: true,
            retryAlreadyUsed: true, status: .connecting, error: handshakeClosed
        ))
        XCTAssertFalse(VNCRemoteSession.shouldRetryInitialMacScreenSharingConnection(
            usesMacScreenSharingAuthentication: true, passwordWasProvided: false,
            retryAlreadyUsed: false, status: .connecting, error: handshakeClosed
        ))
        XCTAssertFalse(VNCRemoteSession.shouldRetryInitialMacScreenSharingConnection(
            usesMacScreenSharingAuthentication: true, passwordWasProvided: true,
            retryAlreadyUsed: false, status: .connected, error: handshakeClosed
        ))
        XCTAssertFalse(VNCRemoteSession.shouldRetryInitialMacScreenSharingConnection(
            usesMacScreenSharingAuthentication: true, passwordWasProvided: true,
            retryAlreadyUsed: false, status: .connecting,
            error: VNCError.authentication(.securityHandshakingFailed(reason: nil))
        ))
    }

    func testARDTimeoutExplainsThatTheMacDidNotFinishAuthentication() {
        XCTAssertEqual(
            VNCRemoteSession.connectionTimeoutMessage(authentication: .appleRemoteDesktop),
            NSLocalizedString("vnc.ardAuthenticationTimeout", comment: "")
        )
        XCTAssertEqual(
            VNCRemoteSession.connectionTimeoutMessage(authentication: .vnc),
            NSLocalizedString("session.timeout", comment: "")
        )
    }

    func testVNCRejectsAnUnknownSecurityType() async throws {
        try await exerciseServer(requiresUsername: false, unsupportedSecurity: true)
    }

    func testClipboardIsIsolatedBetweenVNCsessionsWhenChangingTabs() {
        var first = VNCClipboardSessionGate()
        var second = VNCClipboardSessionGate()
        first.setActive(true, changeCount: 10)
        second.setActive(false, changeCount: 10)

        XCTAssertTrue(first.accepts(isCurrentConnection: true, sharesClipboard: true,
                                    isForeground: true, changeCount: 10))
        XCTAssertFalse(second.accepts(isCurrentConnection: true, sharesClipboard: true,
                                      isForeground: false, changeCount: 10))

        // A pasteboard update is visible only to the selected session.
        XCTAssertTrue(first.hasLocalClipboardChanges(11))
        XCTAssertFalse(second.accepts(isCurrentConnection: true, sharesClipboard: true,
                                      isForeground: false, changeCount: 11))

        // Switching tabs establishes a new baseline, so old clipboard contents
        // are not sent to the newly selected remote host.
        first.setActive(false, changeCount: 11)
        second.setActive(true, changeCount: 11)
        XCTAssertFalse(first.accepts(isCurrentConnection: true, sharesClipboard: true,
                                     isForeground: false, changeCount: 11))
        XCTAssertTrue(second.accepts(isCurrentConnection: true, sharesClipboard: true,
                                     isForeground: true, changeCount: 11))
        XCTAssertFalse(second.hasLocalClipboardChanges(11))
        XCTAssertTrue(second.hasLocalClipboardChanges(12))
    }

    func testClipboardGateRejectsStaleConnectionAndDisabledSharing() {
        var gate = VNCClipboardSessionGate()
        gate.setActive(true, changeCount: 4)
        XCTAssertFalse(gate.accepts(isCurrentConnection: false, sharesClipboard: true,
                                    isForeground: true, changeCount: 4))
        XCTAssertFalse(gate.accepts(isCurrentConnection: true, sharesClipboard: false,
                                    isForeground: true, changeCount: 4))
    }

    @MainActor
    private func exerciseServer(requiresUsername: Bool, requiresPassword: Bool = false,
                                blackInitially: Bool = false, resize: Bool = false,
                                emptyCursor: Bool = false, keyboard: Bool = false,
                                verifyInitialFocus: Bool = false,
                                unsupportedSecurity: Bool = false, tightFileTransfer: Bool = false,
                                tightDownloadOnly: Bool = false, uploadFile: URL? = nil,
                                expectedUpload: Data? = nil, uploadFiles: [URL]? = nil,
                                expectedUploads: [Data]? = nil, clientPassword: String? = nil,
                                expectsCredentialRejection: Bool = false,
                                expectedNegotiatedSecurity: VNCNegotiatedSecurity? = nil) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let portFile = directory.appendingPathComponent("port")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let mode: String
        if requiresUsername { mode = "username" }
        else if unsupportedSecurity { mode = "unsupported" }
        else if requiresPassword { mode = "password" }
        else if (uploadFiles?.count ?? 0) > 1 { mode = "tight-upload-multiple" }
        else if uploadFile != nil || uploadFiles?.isEmpty == false { mode = "tight-upload" }
        else if tightFileTransfer { mode = "tight-files" }
        else if tightDownloadOnly { mode = "tight-download" }
        else if blackInitially { mode = "black" }
        else if emptyCursor { mode = "empty-cursor" }
        else if resize { mode = "resize" }
        else if keyboard { mode = "keyboard" }
        else { mode = "none" }
        server.arguments = ["-c", Self.server, portFile.path, mode, portFile.path + ".uploaded"]
        server.standardOutput = FileHandle.nullDevice
        // XCTest injects libraries into its host; these must not leak into Python.
        server.environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("XCTest") && !$0.key.hasPrefix("XCInject")
        }
        let diagnostics = directory.appendingPathComponent("server.log")
        FileManager.default.createFile(atPath: diagnostics.path, contents: nil)
        let diagnosticHandle = try FileHandle(forWritingTo: diagnostics)
        defer { try? diagnosticHandle.close() }
        server.standardError = diagnosticHandle
        try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        var port: UInt16?
        for _ in 0..<240 {
            if let value = try? String(contentsOf: portFile, encoding: .utf8),
               let parsed = UInt16(value) {
                port = parsed
                break
            }
            guard server.isRunning else { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let port else {
            XCTFail("RFB fixture did not start: " + ((try? String(contentsOf: diagnostics, encoding: .utf8)) ?? "No diagnostics"))
            return
        }
        let session = VNCRemoteSession(profile: ConnectionProfile(name: "Local RFB", host: "127.0.0.1", port: port),
                                       password: clientPassword ?? (requiresPassword ? "vnc-test" : nil))
        let connected = expectation(description: "Authenticated RFB session")
        var observed = false
        let subscription = session.$status.sink { state in
            if ((requiresUsername || unsupportedSecurity || expectsCredentialRejection) ? state.isFinished : state == .connected) && !observed {
                observed = true
                connected.fulfill()
            }
        }
        session.start()
        await fulfillment(of: [connected], timeout: 10)
        if requiresUsername {
            XCTAssertEqual(session.status.error, NSLocalizedString("vnc.usernameRequired", comment: ""))
            XCTAssertTrue(session.serverRequiresUsername)
            XCTAssertTrue(session.serverRequiresMacAccount)
        } else if unsupportedSecurity {
            XCTAssertTrue(session.status.error?.contains(NSLocalizedString("vnc.unsupportedSecurity", comment: "")) == true)
        } else if expectsCredentialRejection {
            XCTAssertTrue(session.status.isFinished)
            XCTAssertTrue(session.savedCredentialsRejected)
        } else {
            XCTAssertEqual(session.status, .connected,
                           "RFB fixture diagnostics: " + ((try? String(contentsOf: diagnostics, encoding: .utf8)) ?? "unavailable"))
            if let expectedNegotiatedSecurity {
                XCTAssertEqual(session.negotiatedSecurity, expectedNegotiatedSecurity)
            }
            let hasUploads = uploadFile != nil || uploadFiles?.isEmpty == false
            XCTAssertEqual(session.fileTransferAvailable, tightFileTransfer || tightDownloadOnly || hasUploads,
                            "A server advertising file-list and download messages should expose the read-only file browser.")
            XCTAssertEqual(session.fileUploadAvailable, tightFileTransfer || hasUploads,
                            "Upload must be available only when the server advertises upload messages.")
            if let uploadFile {
                XCTAssertFalse(session.canUploadLocalFiles([uploadFile]), "Do not upload before checking remote-name conflicts.")
                session.browseRemoteFiles("/")
                let listingLoaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    session.hasCurrentRemoteFileListing
                }, object: nil)
                await fulfillment(of: [listingLoaded], timeout: 5)
                session.uploadLocalFile(uploadFile)
                let uploadSent = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    session.fileTransferNotice == NSLocalizedString("vnc.files.uploadSent", comment: "")
                }, object: nil)
                await fulfillment(of: [uploadSent], timeout: 5)
                let uploadedFile = URL(fileURLWithPath: portFile.path + ".uploaded")
                let received = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    (try? Data(contentsOf: uploadedFile)) == expectedUpload
                }, object: nil)
                await fulfillment(of: [received], timeout: 5)
            }
            if let uploadFiles, let expectedUploads {
                XCTAssertFalse(session.canUploadLocalFiles(uploadFiles), "Do not upload before checking remote-name conflicts.")
                session.browseRemoteFiles("/")
                let listingLoaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    session.listedRemoteDirectory == "/" && !session.isLoadingRemoteFiles
                }, object: nil)
                await fulfillment(of: [listingLoaded], timeout: 5)
                XCTAssertTrue(session.canUploadLocalFiles(uploadFiles))
                XCTAssertFalse(session.canUploadLocalFiles([uploadFiles[0].deletingLastPathComponent()]))
                session.uploadLocalFiles(uploadFiles)
                let received = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    !session.isUploadingFile && zip(uploadFiles, expectedUploads).allSatisfy { source, payload in
                        let receivedURL = URL(fileURLWithPath: portFile.path + ".uploaded." + source.lastPathComponent)
                        return (try? Data(contentsOf: receivedURL)) == payload
                    }
                }, object: nil)
                await fulfillment(of: [received], timeout: 10)
            }
            if resize {
                try await assertResize(session, trigger: URL(fileURLWithPath: portFile.path + ".resize"))
            } else {
                try await assertRenderedDesktop(session, isBlack: blackInitially, expectsEmptyCursor: emptyCursor)
            }
            if keyboard { try await assertKeyboardCharacters(session, receivedKeys: URL(fileURLWithPath: portFile.path + ".keys")) }
            if verifyInitialFocus { try await assertInitialFocus(session) }
            if blackInitially {
                let warning = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    session.notice == NSLocalizedString("vnc.blackScreen", comment: "")
                }, object: nil)
                await fulfillment(of: [warning], timeout: 12)
                let recovered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    session.notice == nil
                }, object: nil)
                await fulfillment(of: [recovered], timeout: 6)
                XCTAssertEqual(session.status, .connected)
            }
        }
        session.stop()
        XCTAssertEqual(session.status, .disconnected(reason: nil))
        subscription.cancel()
    }

    @MainActor
    private func assertKeyboardCharacters(_ session: VNCRemoteSession, receivedKeys: URL) async throws {
        let host = NSHostingView(rootView: VNCSessionScreenView(session: session))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.initialFirstResponder = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func framebuffer(in view: NSView) -> VNCCAFramebufferView? {
            if let frame = view as? VNCCAFramebufferView { return frame }
            return view.subviews.lazy.compactMap { framebuffer(in: $0) }.first
        }
        let framebufferReady = await waitForUI(timeout: 5) {
            framebuffer(in: host)?.framebufferSize == CGSize(width: 2, height: 2)
                && framebuffer(in: host)?.window === window
        }
        XCTAssertTrue(framebufferReady)
        let view = try XCTUnwrap(framebuffer(in: host))
        XCTAssertTrue(window.makeFirstResponder(view))

        // Swedish macOS uses right Option+2 for @. Left Option is also accepted.
        // Emulate resolved characters from other layouts and Unicode input sources,
        // then inspect the RFB wire.
        let option = NSEvent.keyEvent(with: .flagsChanged, location: .zero,
                                      modifierFlags: [.leftOption], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil,
                                      characters: "", charactersIgnoringModifiers: "",
                                      isARepeat: false, keyCode: 58)!
        view.flagsChanged(with: option)
        let numberDown = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                          modifierFlags: [.leftOption], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil,
                                          characters: "@", charactersIgnoringModifiers: "2",
                                          isARepeat: false, keyCode: 19)!
        view.keyDown(with: numberDown)
        let numberUp = NSEvent.keyEvent(with: .keyUp, location: .zero,
                                        modifierFlags: [.leftOption], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: "@", charactersIgnoringModifiers: "2",
                                        isARepeat: false, keyCode: 19)!
        view.keyUp(with: numberUp)
        let optionUp = NSEvent.keyEvent(with: .flagsChanged, location: .zero,
                                        modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: "", charactersIgnoringModifiers: "",
                                        isARepeat: false, keyCode: 58)!
        view.flagsChanged(with: optionUp)
        let rightOptionDown = NSEvent.keyEvent(with: .flagsChanged, location: .zero,
                                               modifierFlags: [.rightOption], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil,
                                               characters: "", charactersIgnoringModifiers: "",
                                               isARepeat: false, keyCode: 61)!
        view.flagsChanged(with: rightOptionDown)
        let rightOptionAtDown = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                 modifierFlags: [.rightOption], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 characters: "@", charactersIgnoringModifiers: "2",
                                                 isARepeat: false, keyCode: 19)!
        let rightOptionAtUp = NSEvent.keyEvent(with: .keyUp, location: .zero,
                                               modifierFlags: [.rightOption], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil,
                                               characters: "@", charactersIgnoringModifiers: "2",
                                               isARepeat: false, keyCode: 19)!
        view.keyDown(with: rightOptionAtDown)
        view.keyUp(with: rightOptionAtUp)
        let rightOptionUp = NSEvent.keyEvent(with: .flagsChanged, location: .zero,
                                             modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil,
                                             characters: "", charactersIgnoringModifiers: "",
                                             isARepeat: false, keyCode: 61)!
        view.flagsChanged(with: rightOptionUp)
        let shiftDown = NSEvent.keyEvent(with: .flagsChanged, location: .zero,
                                         modifierFlags: [.leftShift], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil,
                                         characters: "", charactersIgnoringModifiers: "",
                                         isARepeat: false, keyCode: 56)!
        view.flagsChanged(with: shiftDown)
        let shiftedAtDown = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                             modifierFlags: [.leftShift], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil,
                                             characters: "@", charactersIgnoringModifiers: "2",
                                             isARepeat: false, keyCode: 19)!
        let shiftedAtUp = NSEvent.keyEvent(with: .keyUp, location: .zero,
                                           modifierFlags: [.leftShift], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: "@", charactersIgnoringModifiers: "2",
                                           isARepeat: false, keyCode: 19)!
        view.keyDown(with: shiftedAtDown)
        view.keyUp(with: shiftedAtUp)
        let shiftUp = NSEvent.keyEvent(with: .flagsChanged, location: .zero,
                                       modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil,
                                       characters: "", charactersIgnoringModifiers: "",
                                       isARepeat: false, keyCode: 56)!
        view.flagsChanged(with: shiftUp)
        // The remote Mac must receive the resolved character, not an
        // Option+physical-key sequence which depends on its own layout.
        let atKeyDown = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                         modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil,
                                         characters: "@", charactersIgnoringModifiers: "2",
                                         isARepeat: false, keyCode: 19)!
        let atKeyUp = NSEvent.keyEvent(with: .keyUp, location: .zero,
                                       modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil,
                                       characters: "@", charactersIgnoringModifiers: "2",
                                       isARepeat: false, keyCode: 19)!
        view.keyDown(with: atKeyDown)
        view.keyUp(with: atKeyUp)

        let optionDownBeforeFocusLoss = NSEvent.keyEvent(with: .flagsChanged, location: .zero,
                                                          modifierFlags: [.leftOption], timestamp: 0,
                                                          windowNumber: window.windowNumber, context: nil,
                                                          characters: "", charactersIgnoringModifiers: "",
                                                          isARepeat: false, keyCode: 58)!
        view.flagsChanged(with: optionDownBeforeFocusLoss)
        let atDownBeforeFocusLoss = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                      modifierFlags: [.leftOption], timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil,
                                                      characters: "@", charactersIgnoringModifiers: "2",
                                                      isARepeat: false, keyCode: 19)!
        view.keyDown(with: atDownBeforeFocusLoss)
        XCTAssertTrue(view.resignFirstResponder())
        let lateAtKeyUp = NSEvent.keyEvent(with: .keyUp, location: .zero,
                                           modifierFlags: [.leftOption], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: "@", charactersIgnoringModifiers: "2",
                                           isARepeat: false, keyCode: 19)!
        view.keyUp(with: lateAtKeyUp)

        // AppKit can leave the framebuffer as first responder when the whole
        // window loses key status. A matching key-up may then go to another
        // app, so the view must release the remote key on window deactivation.
        let dashDown = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                        modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: "-", charactersIgnoringModifiers: "-",
                                        isARepeat: false, keyCode: 27)!
        view.keyDown(with: dashDown)
        for _ in 0..<3 {
            let repeatedDashDown = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                    modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil,
                                                    characters: "-", charactersIgnoringModifiers: "-",
                                                    isARepeat: true, keyCode: 27)!
            view.keyDown(with: repeatedDashDown)
        }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        let lateDashUp = NSEvent.keyEvent(with: .keyUp, location: .zero,
                                          modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil,
                                          characters: "-", charactersIgnoringModifiers: "-",
                                          isARepeat: false, keyCode: 27)!
        view.keyUp(with: lateDashUp)
        let staleDashRepeat = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                               modifierFlags: [], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil,
                                               characters: "-", charactersIgnoringModifiers: "-",
                                               isARepeat: true, keyCode: 27)!
        view.keyDown(with: staleDashRepeat)

        // Returning to the VNC tab must start with a clean key state. A fresh
        // press after focus returns should still be delivered as a normal pair.
        let resumedDashDown = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                               modifierFlags: [], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil,
                                               characters: "-", charactersIgnoringModifiers: "-",
                                               isARepeat: false, keyCode: 27)!
        let resumedDashUp = NSEvent.keyEvent(with: .keyUp, location: .zero,
                                             modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil,
                                             characters: "-", charactersIgnoringModifiers: "-",
                                             isARepeat: false, keyCode: 27)!
        view.keyDown(with: resumedDashDown)
        view.keyUp(with: resumedDashUp)

        // Switching VNC tabs can move first-responder focus while the app
        // window stays active. Release the remote key before a late key-up is
        // delivered to some other view.
        let focusSink = VNCKeyboardFocusTestView(frame: host.bounds)
        focusSink.autoresizingMask = [.width, .height]
        container.addSubview(focusSink)
        let heldQDown = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                         modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil,
                                         characters: "q", charactersIgnoringModifiers: "q",
                                         isARepeat: false, keyCode: 12)!
        let lateQUp = NSEvent.keyEvent(with: .keyUp, location: .zero,
                                       modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil,
                                       characters: "q", charactersIgnoringModifiers: "q",
                                       isARepeat: false, keyCode: 12)!
        view.keyDown(with: heldQDown)
        XCTAssertTrue(window.makeFirstResponder(focusSink))
        view.keyUp(with: lateQUp)
        XCTAssertTrue(window.makeFirstResponder(view))

        // macOS can deactivate the app without a key-up reaching this view.
        // Clear remote key state even if the window itself remains key.
        let xDownBeforeAppDeactivation = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                          modifierFlags: [], timestamp: 0,
                                                          windowNumber: window.windowNumber, context: nil,
                                                          characters: "x", charactersIgnoringModifiers: "x",
                                                          isARepeat: false, keyCode: 7)!
        view.keyDown(with: xDownBeforeAppDeactivation)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        let lateXUp = NSEvent.keyEvent(with: .keyUp, location: .zero,
                                       modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil,
                                       characters: "x", charactersIgnoringModifiers: "x",
                                       isARepeat: false, keyCode: 7)!
        view.keyUp(with: lateXUp)

        func sendCharacter(_ character: String, keyCode: UInt16) {
            let down = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                        modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: character, charactersIgnoringModifiers: character,
                                        isARepeat: false, keyCode: keyCode)!
            let up = NSEvent.keyEvent(with: .keyUp, location: .zero,
                                      modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil,
                                      characters: character, charactersIgnoringModifiers: character,
                                      isARepeat: false, keyCode: keyCode)!
            view.keyDown(with: down)
            view.keyUp(with: up)
        }

        // Key code 6 is the physical Z position on ANSI keyboards but resolves
        // to Z on QWERTY and Y on QWERTZ. The client should send the resolved
        // character supplied by the active macOS input source.
        sendCharacter("y", keyCode: 6)
        sendCharacter("é", keyCode: 0xFFFF)
        sendCharacter("åäö", keyCode: 0xFFFE)
        sendCharacter("€日🙂", keyCode: 0xFFFD)

        func sendControlKey(_ keyCode: UInt16, characters: String) {
            let down = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                        modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: characters, charactersIgnoringModifiers: characters,
                                        isARepeat: false, keyCode: keyCode)!
            let up = NSEvent.keyEvent(with: .keyUp, location: .zero,
                                      modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: keyCode)!
            view.keyDown(with: down)
            view.keyUp(with: up)
        }

        sendControlKey(51, characters: "\u{7f}") // Backspace
        sendControlKey(36, characters: "\r")     // Return
        sendControlKey(48, characters: "\t")     // Tab

        let sent = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let contents = try? String(contentsOf: receivedKeys, encoding: .utf8) else { return false }
            return contents.contains("0:0000ff09\n")
        }, object: nil)
        await fulfillment(of: [sent], timeout: 5)
        let contents = try String(contentsOf: receivedKeys, encoding: .utf8)
        let events = try contents.split(separator: "\n").map { line -> (Bool, UInt32) in
            let fields = line.split(separator: ":")
            guard fields.count == 2, let down = Int(fields[0]), let keysym = UInt32(fields[1], radix: 16) else {
                throw NSError(domain: "VNC keyboard fixture", code: 1)
            }
            return (down == 1, keysym)
        }
        let nonDashEvents = events.filter { $0.1 != 0x2D }
        XCTAssertEqual(nonDashEvents.map { $0.1 }, [
            0xFFE9, 0xFFE9, 0x40, 0x40, 0xFFE9, 0xFFE9,
            0xFFEA, 0xFFEA, 0x40, 0x40, 0xFFEA, 0xFFEA,
            0xFFE1, 0xFFE1, 0x40, 0x40, 0xFFE1, 0xFFE1,
            0x40, 0x40,
            0xFFE9, 0xFFE9, 0x40, 0x40, 0xFFE9,
            0x71, 0x71,
            0x78, 0x78,
            0x79, 0x79,
            0xE9, 0xE9,
            0xE5, 0xE4, 0xF6, 0xE5, 0xE4, 0xF6,
            0x010020AC, 0x010065E5, 0x0101F642,
            0x010020AC, 0x010065E5, 0x0101F642,
            0xFF08, 0xFF08, 0xFF0D, 0xFF0D, 0xFF09, 0xFF09
        ])
        let dashEvents = events.filter { $0.1 == 0x2D }
        XCTAssertGreaterThanOrEqual(dashEvents.count, 4,
                                    "The held dash, focus-loss release, and later press/release must reach the server")
        XCTAssertLessThanOrEqual(dashEvents.count, 10,
                                 "Three AppKit repeats must be balanced taps before focus-loss release")
        XCTAssertEqual(Array(dashEvents.suffix(2).map { $0.0 }), [true, false],
                       "A new press after focus returns remains usable")
        XCTAssertEqual(dashEvents.dropLast(2).last?.0, false,
                       "Focus loss releases a held key after any queued RFB repeats")
        let qEvents = events.filter { $0.1 == 0x71 }
        XCTAssertEqual(qEvents.map { $0.0 }, [true, false],
                       "Changing first responder must release a held key even while the window remains active")
        let xEvents = events.filter { $0.1 == 0x78 }
        XCTAssertEqual(xEvents.map { $0.0 }, [true, false],
                       "App deactivation must release a held key even when the window does not resign key")

        // A VNC server must not keep typing when the physical key-up is lost.
        // Autorepeat events carry their own release, which is checked before
        // sending a different key as a delivery barrier.
        let linesBeforeLostKeyUp = try String(contentsOf: receivedKeys, encoding: .utf8)
            .split(separator: "\n").count
        let heldDash = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                        modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: "-", charactersIgnoringModifiers: "-",
                                        isARepeat: false, keyCode: 27)!
        view.keyDown(with: heldDash)
        let initialDashDelivered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let contents = try? String(contentsOf: receivedKeys, encoding: .utf8) else { return false }
            return contents.split(separator: "\n").count > linesBeforeLostKeyUp
        }, object: nil)
        await fulfillment(of: [initialDashDelivered], timeout: 5)
        let initialDashReleased = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let contents = try? String(contentsOf: receivedKeys, encoding: .utf8) else { return false }
            return contents.hasSuffix("0:0000002d\n")
        }, object: nil)
        await fulfillment(of: [initialDashReleased], timeout: 5)
        for _ in 0..<20 {
            let repeatedDash = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                modifierFlags: [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil,
                                                characters: "-", charactersIgnoringModifiers: "-",
                                                isARepeat: true, keyCode: 27)!
            view.keyDown(with: repeatedDash)
        }
        sendControlKey(0xFEFE, characters: "!")
        let lostKeyUpBarrier = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let contents = try? String(contentsOf: receivedKeys, encoding: .utf8) else { return false }
            return contents.hasSuffix("0:00000021\n")
        }, object: nil)
        await fulfillment(of: [lostKeyUpBarrier], timeout: 5)
        let lostKeyUpEvents = try String(contentsOf: receivedKeys, encoding: .utf8)
            .split(separator: "\n").dropFirst(linesBeforeLostKeyUp).map { line -> (Bool, UInt32) in
                let fields = line.split(separator: ":")
                guard fields.count == 2, let down = Int(fields[0]), let key = UInt32(fields[1], radix: 16) else {
                    throw NSError(domain: "VNC keyboard fixture", code: 4)
                }
                return (down == 1, key)
        }
        let repeatedDashEvents = lostKeyUpEvents.filter { $0.1 == 0x2D }
        XCTAssertGreaterThanOrEqual(repeatedDashEvents.count, 4,
                                    "The initial press and one balanced autorepeat must reach the server")
        XCTAssertEqual(Array(repeatedDashEvents.prefix(2).map { $0.0 }), [true, false],
                       "The initial press must release even though its physical key-up is lost")
        XCTAssertEqual(Array(repeatedDashEvents.suffix(2).map { $0.0 }), [true, false],
                       "AppKit repeats remain usable as balanced taps")
        XCTAssertEqual(repeatedDashEvents.count % 2, 0,
                       "Every dash press delivered without physical key-up is released")
        XCTAssertEqual(repeatedDashEvents.last?.0, false,
                       "The last delivered autorepeat releases the dash without waiting for physical key-up")
        XCTAssertEqual(lostKeyUpEvents.suffix(2).map { $0.0 }, [true, false],
                       "The delivery barrier must remain usable after the lost physical key-up")
        view.releasePressedKeys()

        // Send a no-delay typing burst through the full AppKit → framebuffer →
        // RFB path. Slow manual typing can mask missing or reordered events.
        let typingBurst = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        for (index, character) in typingBurst.enumerated() {
            sendControlKey(UInt16(0xFF00 + index), characters: String(character))
        }
        sendControlKey(0xFEFF, characters: "☃")
        let burstSent = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let contents = try? String(contentsOf: receivedKeys, encoding: .utf8) else { return false }
            return contents.contains("0:01002603\n")
        }, object: nil)
        await fulfillment(of: [burstSent], timeout: 5)
        let burstLines = try String(contentsOf: receivedKeys, encoding: .utf8).split(separator: "\n")
        let burstEvents = try burstLines.suffix(typingBurst.count * 2 + 2).map { line -> (Bool, UInt32) in
            let fields = line.split(separator: ":")
            guard fields.count == 2, let down = Int(fields[0]), let keysym = UInt32(fields[1], radix: 16) else {
                throw NSError(domain: "VNC keyboard fixture", code: 2)
            }
            return (down == 1, keysym)
        }
        let expectedBurst = typingBurst.flatMap { character -> [UInt32] in
            let keysym = UInt32(character.asciiValue!)
            return [keysym, keysym]
        } + [0x01002603, 0x01002603]
        XCTAssertEqual(burstEvents.map(\.0), Array(repeating: [true, false], count: expectedBurst.count / 2).flatMap { $0 })
        XCTAssertEqual(burstEvents.map(\.1), expectedBurst,
                       "Fast typing must preserve every character keysym and key-up in order")

        // Reuse the same physical key code for repeated characters, as a real
        // keyboard does when a password contains repeated letters or symbols.
        // The distinctive final keysym is a server-side delivery barrier.
        let repeatedBurst = Array(String(repeating: "aa--11zz--", count: 16))
        for character in repeatedBurst {
            let keyCode = UInt16(0xF000 + Int(character.asciiValue!))
            sendControlKey(keyCode, characters: String(character))
        }
        sendControlKey(0xFEFE, characters: "!")
        let repeatedBurstSent = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let contents = try? String(contentsOf: receivedKeys, encoding: .utf8) else { return false }
            return contents.hasSuffix("0:00000021\n")
        }, object: nil)
        await fulfillment(of: [repeatedBurstSent], timeout: 10)
        let repeatedLines = try String(contentsOf: receivedKeys, encoding: .utf8).split(separator: "\n")
        let repeatedEvents = try repeatedLines.suffix(repeatedBurst.count * 2 + 2).map { line -> (Bool, UInt32) in
            let fields = line.split(separator: ":")
            guard fields.count == 2, let down = Int(fields[0]), let keysym = UInt32(fields[1], radix: 16) else {
                throw NSError(domain: "VNC keyboard fixture", code: 3)
            }
            return (down == 1, keysym)
        }
        let expectedRepeated = repeatedBurst.flatMap { character -> [UInt32] in
            let keysym = UInt32(character.asciiValue!)
            return [keysym, keysym]
        } + [0x21, 0x21]
        XCTAssertEqual(repeatedEvents.map(\.0),
                       Array(repeating: [true, false], count: expectedRepeated.count / 2).flatMap { $0 })
        XCTAssertEqual(repeatedEvents.map(\.1), expectedRepeated,
                       "Rapid repeated letters, dashes, and digits must reach the server in order")

        let linesBeforeDetach = try String(contentsOf: receivedKeys, encoding: .utf8)
            .split(separator: "\n").count
        let detachKeyDown = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                             modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil,
                                             characters: "v", charactersIgnoringModifiers: "v",
                                             isARepeat: false, keyCode: 9)!
        view.keyDown(with: detachKeyDown)
        let detachPressSent = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let contents = try? String(contentsOf: receivedKeys, encoding: .utf8) else { return false }
            return contents.split(separator: "\n").dropFirst(linesBeforeDetach)
                .contains("1:00000076")
        }, object: nil)
        await fulfillment(of: [detachPressSent], timeout: 5)

        view.removeFromSuperview()
        XCTAssertNil(view.window, "The test must exercise framebuffer detachment")
        let detachedKeyReleased = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let contents = try? String(contentsOf: receivedKeys, encoding: .utf8) else { return false }
            return contents.hasSuffix("0:00000076\n")
        }, object: nil)
        await fulfillment(of: [detachedKeyReleased], timeout: 5)

        let lateRepeat = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                          modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil,
                                          characters: "v", charactersIgnoringModifiers: "v",
                                          isARepeat: true, keyCode: 9)!
        view.keyDown(with: lateRepeat)
        sendControlKey(0xFEFE, characters: "!")
        let detachedInputDrained = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let contents = try? String(contentsOf: receivedKeys, encoding: .utf8) else { return false }
            return contents.hasSuffix("0:00000021\n")
        }, object: nil)
        await fulfillment(of: [detachedInputDrained], timeout: 5)
        let eventsAfterDetach = try String(contentsOf: receivedKeys, encoding: .utf8)
            .split(separator: "\n").suffix(4).map { line -> (Bool, UInt32) in
                let fields = line.split(separator: ":")
                guard fields.count == 2, let down = Int(fields[0]), let key = UInt32(fields[1], radix: 16) else {
                    throw NSError(domain: "VNC keyboard fixture", code: 5)
                }
                return (down == 1, key)
            }
        XCTAssertEqual(eventsAfterDetach.map(\.0), [true, false, true, false])
        XCTAssertEqual(eventsAfterDetach.map(\.1), [0x76, 0x76, 0x21, 0x21],
                       "A delayed repeat must not press the key again after its view detaches")
    }

    @MainActor
    private func assertResize(_ session: VNCRemoteSession, trigger: URL) async throws {
        let host = NSHostingView(rootView: VNCSessionScreenView(session: session))
        let window = CursorTrackingWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func framebuffer(in view: NSView) -> VNCCAFramebufferView? {
            if let frame = view as? VNCCAFramebufferView { return frame }
            return view.subviews.lazy.compactMap { framebuffer(in: $0) }.first
        }
        let originalReady = await waitForUI(timeout: 5) {
            framebuffer(in: host)?.framebufferSize == CGSize(width: 2, height: 2)
        }
        XCTAssertTrue(originalReady)
        let originalView = try XCTUnwrap(framebuffer(in: host))
        let originalCursor = originalView.currentCursor
        XCTAssertEqual(originalCursor.image.size, CGSize(width: 2, height: 2))
        XCTAssertTrue(window.makeFirstResponder(originalView))
        window.simulatedPointerLocation = originalView.convert(
            NSPoint(x: originalView.bounds.midX, y: originalView.bounds.midY), to: nil)
        XCTAssertTrue(originalView.visibleRect.contains(
            originalView.convert(window.mouseLocationOutsideOfEventStream, from: nil)))
        originalCursor.set()
        XCTAssertTrue(NSCursor.current === originalCursor,
                      "The remote cursor should be active before the server changes its shape")
        try Data().write(to: trigger)
        let resizedReady = await waitForUI(timeout: 5) {
            framebuffer(in: host)?.framebufferSize == CGSize(width: 5, height: 3)
        }
        XCTAssertTrue(resizedReady)
        let didPaint = await waitForUI(timeout: 5) {
            guard let image = framebuffer(in: host)?.framebuffer?.cgImage,
                  image.width == 5, image.height == 3,
                  let color = NSBitmapImageRep(cgImage: image).colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB)
            else { return false }
            return color.blueComponent > 0.95 && color.redComponent < 0.05
        }
        XCTAssertTrue(didPaint)
        let resizedView = framebuffer(in: host)
        let resizedImage = resizedView?.framebuffer?.cgImage
        let resizedPixel = resizedImage.flatMap { NSBitmapImageRep(cgImage: $0).colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) }
        let resizedImageDescription = resizedImage.map { "\($0.width)x\($0.height)" } ?? "nil"
        XCTAssertTrue(resizedImage != nil,
                      "Expected a rendered blue 5x3 frame; view=\(String(describing: resizedView?.framebufferSize)), image=\(resizedImageDescription), pixel=\(String(describing: resizedPixel))")
        if window.isKeyWindow {
            XCTAssertTrue(window.firstResponder === framebuffer(in: host), "Keyboard focus must follow the resized desktop")
        }
        let cursorArrived = await waitForUI(timeout: 12) {
            guard let image = framebuffer(in: host)?.remoteCursor?.cgImage,
                  image.width == 3, image.height == 2,
                  let pixel = NSBitmapImageRep(cgImage: image).colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB)
            else { return false }
            return pixel.greenComponent > 0.95 && pixel.blueComponent > 0.95
        }
        XCTAssertTrue(cursorArrived)
        let cursorSnapshot = framebuffer(in: host)?.remoteCursor
        let fixtureStage = (try? String(contentsOf: URL(fileURLWithPath: trigger.path + ".stage"), encoding: .utf8)) ?? "unavailable"
        guard cursorSnapshot != nil else {
            XCTFail("Apple's cached cursor encoding must replace the initial XCursor shape; " +
                    "received-size=\(String(describing: cursorSnapshot?.size)), fixture-stage=\(fixtureStage)")
            return
        }
        let cursor = try XCTUnwrap(framebuffer(in: host)?.currentCursor)
        XCTAssertEqual(cursor.image.size, CGSize(width: 3, height: 2))
        XCTAssertEqual(cursor.hotSpot, CGPoint(x: 2, y: 1),
                       "The Apple cursor hotspot must be preserved")
        let decodedCursor = try XCTUnwrap(resizedView?.remoteCursor)
        let decodedImage = try XCTUnwrap(decodedCursor.cgImage)
        let cursorBitmap = NSBitmapImageRep(cgImage: decodedImage)
        let firstPixel = try XCTUnwrap(cursorBitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        let secondPixel = try XCTUnwrap(cursorBitmap.colorAt(x: 1, y: 0)?.usingColorSpace(.deviceRGB))
        let thirdPixel = try XCTUnwrap(cursorBitmap.colorAt(x: 2, y: 0)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(firstPixel.alphaComponent, 0.95, "The updated server cursor must remain visible after a resize")
        XCTAssertLessThan(firstPixel.redComponent, 0.05)
        XCTAssertGreaterThan(firstPixel.greenComponent, 0.95,
                             "The selected Apple cursor must differ from the initial XCursor shape")
        XCTAssertGreaterThan(firstPixel.blueComponent, 0.95)
        XCTAssertGreaterThan(secondPixel.alphaComponent, 0.95)
        XCTAssertGreaterThan(secondPixel.redComponent, 0.95)
        XCTAssertGreaterThan(secondPixel.greenComponent, 0.95)
        XCTAssertLessThan(secondPixel.blueComponent, 0.05)
        XCTAssertLessThan(thirdPixel.alphaComponent, 0.05,
                          "The Apple cursor alpha plane must keep transparent pixels invisible")
        XCTAssertTrue(NSCursor.current === cursor,
                      "A cursor shape update must take effect while the pointer remains over the framebuffer")
        XCTAssertGreaterThan(window.cursorRectInvalidations, 0,
                             "A changed server cursor must invalidate AppKit's cached cursor rectangles")
        XCTAssertTrue(resizedView?.trackingAreas.contains { $0.options.contains(.cursorUpdate) } == true,
                      "The framebuffer must receive AppKit cursor-update events while the pointer is over it")
        resizedView?.frame = NSRect(x: 0, y: 0, width: 2.5, height: 1.5)
        XCTAssertEqual(resizedView?.scaleRatio ?? -1, 0.5, accuracy: 0.001)
        let scaledCursor = try XCTUnwrap(resizedView?.currentCursor)
        XCTAssertEqual(scaledCursor.image.size, CGSize(width: 1.5, height: 1),
                       "The cursor should track the framebuffer's displayed scale")
        XCTAssertEqual(scaledCursor.hotSpot, CGPoint(x: 1, y: 0.5),
                       "The hotspot should use the same scale as the cursor image")
        let cursorEvent = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved,
                                                          location: .zero,
                                                          modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: window.windowNumber,
                                                          context: nil,
                                                          eventNumber: 0,
                                                          clickCount: 0,
                                                          pressure: 0))
        resizedView?.cursorUpdate(with: cursorEvent)
        XCTAssertTrue(NSCursor.current === scaledCursor,
                      "AppKit must activate the latest server cursor when the pointer enters the framebuffer")

        XCTAssertEqual(session.status, .connected)
    }

    @MainActor
    private func assertInitialFocus(_ session: VNCRemoteSession) async throws {
        let host = NSHostingView(rootView: VNCSessionScreenView(session: session))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func framebuffer(in view: NSView) -> VNCCAFramebufferView? {
            if let frame = view as? VNCCAFramebufferView { return frame }
            return view.subviews.lazy.compactMap { framebuffer(in: $0) }.first
        }
        let framebufferReady = await waitForUI(timeout: 5) {
            framebuffer(in: host)?.framebufferSize == CGSize(width: 2, height: 2)
                && framebuffer(in: host)?.window === window
        }
        XCTAssertTrue(framebufferReady)
        guard window.isKeyWindow else {
            throw XCTSkip("Initial keyboard focus requires an unlocked macOS window session")
        }
        let focusArrived = await waitForUI(timeout: 5) {
            window.firstResponder === framebuffer(in: host)
        }
        XCTAssertTrue(focusArrived,
                      "A connected VNC desktop should receive keyboard focus without a click")
    }

    @MainActor
    private func assertRenderedDesktop(_ session: VNCRemoteSession, isBlack: Bool,
                                       expectsEmptyCursor: Bool = false) async throws {
        // A successful handshake alone does not prove that the app shows pixels.
        let host = NSHostingView(rootView: VNCSessionScreenView(session: session))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.initialFirstResponder = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func framebuffer(in view: NSView) -> VNCCAFramebufferView? {
            if let frame = view as? VNCCAFramebufferView { return frame }
            return view.subviews.lazy.compactMap { framebuffer(in: $0) }.first
        }
        let didRender = await waitForUI(timeout: 5) {
            guard let view = framebuffer(in: host) else { return false }
            return view.window === window && view.layer?.contents != nil
        }
        XCTAssertTrue(didRender)
        let view = try XCTUnwrap(framebuffer(in: host))
        if expectsEmptyCursor {
        let fallbackVisible = await waitForUI(timeout: 5) {
                view.remoteCursor?.isEmpty == true && view.currentCursor.image.size == CGSize(width: 9, height: 9)
            }
            XCTAssertTrue(fallbackVisible,
                          "An empty RFB cursor shape should activate the centered dot fallback")
            XCTAssertEqual(view.currentCursor.hotSpot, CGPoint(x: 4.5, y: 4.5))
        } else {
            XCTAssertNil(view.remoteCursor, "This fixture sends no remote cursor shape")
            XCTAssertEqual(view.currentCursor.image.size, NSCursor.arrow.image.size,
                           "A server that omits cursor pseudo-encodings must leave the local pointer visible")
            XCTAssertEqual(view.currentCursor.hotSpot, NSCursor.arrow.hotSpot,
                          "A server that omits cursor pseudo-encodings must leave the local pointer visible")
        }
        let contents = try XCTUnwrap(view.layer?.contents)
        XCTAssertEqual(CFGetTypeID(contents as CFTypeRef), CGImage.typeID)
        let image = contents as! CGImage
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        let pixel = try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        if isBlack { XCTAssertLessThan(pixel.redComponent, 0.05) }
        else { XCTAssertGreaterThan(pixel.redComponent, 0.95) }
        XCTAssertLessThan(pixel.greenComponent, 0.05)
        XCTAssertLessThan(pixel.blueComponent, 0.05)
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

    private static let server = #"""
import os, socket, struct, sys, time, zlib

def read(client, count):
    data = b''
    while len(data) < count:
        chunk = client.recv(count-len(data))
        if not chunk: raise EOFError()
        data += chunk
    return data

with socket.socket() as listener:
    listener.bind(('127.0.0.1', 0))
    listener.listen(1)
    with open(sys.argv[1] + '.tmp', 'w') as out: out.write(str(listener.getsockname()[1]))
    os.replace(sys.argv[1] + '.tmp', sys.argv[1])
    if sys.argv[2] in ('retry-once', 'close-once'):
        with open(sys.argv[1] + '.count', 'w') as out: out.write('0')
        client, _ = listener.accept()
        if sys.argv[2] == 'close-once':
            with client:
                client.settimeout(12)
                with open(sys.argv[1] + '.count', 'w') as out: out.write('1')
                client.sendall(b'RFB 003.008\n')
                assert read(client, 12) == b'RFB 003.008\n'
                # Close after version negotiation but before security selection.
            client, _ = listener.accept()
            with open(sys.argv[1] + '.count', 'w') as out: out.write('2')
        else:
            with client:
                client.settimeout(12)
                with open(sys.argv[1] + '.count', 'w') as out: out.write('1')
                client.sendall(b'RFB 003.889\n')
                assert read(client, 12) == b'RFB 003.008\n'
                client.sendall(b'\x07\x1e\x21\x24\x1f\x20\x02\x23')
                assert read(client, 1) == b'\x1e'
                client.sendall(struct.pack('!HH', 5, 512) + b'\xff' * 512 + b'\x01' * 512)
                assert client.recv(1) == b''
            client, _ = listener.accept()
            with open(sys.argv[1] + '.count', 'w') as out: out.write('2')
        # Continue through the ordinary no-auth handshake below.
    else:
        client, _ = listener.accept()
    with client:
        client.settimeout(12)
        if sys.argv[2] == 'username':
            # macOS Screen Sharing advertises 3.889 but accepts the client's
            # standards-compatible 3.8 downgrade, then includes its Apple
            # extensions alongside ARD and standard VNC authentication.
            client.sendall(b'RFB 003.889\n')
            assert read(client, 12) == b'RFB 003.008\n'
            client.sendall(b'\x07\x1e\x21\x24\x1f\x20\x02\x23')
            assert read(client, 1) == b'\x1e'
            # No credentials are submitted: only the ARD challenge is needed.
            client.sendall(struct.pack('!HH', 5, 512) + b'\xff' * 512 + b'\x01' * 512)
            assert client.recv(1) == b''
            sys.exit(0)
        client.sendall(b'RFB 003.008\n')
        read(client, 12)
        if sys.argv[2] == 'unsupported':
            # Type 0x7f is deliberately unknown. The app must show its
            # localized compatibility explanation, not a backend diagnostic.
            client.sendall(b'\x01\x7f')
            assert client.recv(1) == b''
            sys.exit(0)
        if sys.argv[2] in ('tight-files', 'tight-download', 'tight-upload', 'tight-upload-multiple'):
            client.sendall(b'\x01\x10')
            assert read(client, 1) == b'\x10'
            client.sendall(struct.pack('!II', 0, 0))
        elif sys.argv[2] == 'password':
            client.sendall(b'\x01\x02')
            assert read(client, 1) == b'\x02'
            client.sendall(bytes(range(16)))
            # Fixed test-only challenge response for the dummy password vnc-test.
            response = read(client, 16)
            if response != bytes.fromhex('6462c8f87dc31b5642d39beecb016a32'):
                reason = b'Authentication failed'
                client.sendall(struct.pack('!II', 1, len(reason)) + reason)
                sys.exit(0)
        else:
            client.sendall(b'\x01\x01')
            assert read(client, 1) == b'\x01'
        client.sendall(struct.pack('!I', 0))
        read(client, 1)
        name = b'FjarrConnect local test'
        client.sendall(struct.pack('!HHBBBBHHHBBBxxxI', 2, 2, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0, len(name)) + name)
        if sys.argv[2] in ('tight-files', 'tight-download', 'tight-upload', 'tight-upload-multiple'):
            def capability(code, vendor, signature):
                return struct.pack('!I', code) + vendor.encode('ascii') + signature.encode('ascii')
            messages = [capability(130, 'TGHT', 'FTS_LSDT'), capability(131, 'TGHT', 'FTS_DNDT')]
            clients = [capability(130, 'TGHT', 'FTC_LSRQ'), capability(131, 'TGHT', 'FTC_DNRQ')]
            if sys.argv[2] in ('tight-files', 'tight-upload', 'tight-upload-multiple'):
                clients += [capability(132, 'TGHT', 'FTC_UPRQ'), capability(133, 'TGHT', 'FTC_UPDT')]
            client.sendall(struct.pack('!HHHH', len(messages), len(clients), 0, 0) + b''.join(messages + clients))
        first_frame = None
        resized = False
        initial_frame_sent = False
        resized_frame_sent = False
        sent_cursor = False
        sent_empty_cursor = False
        upload_data = b''
        def write_stage(stage):
            with open(sys.argv[1] + '.resize.stage', 'w') as out: out.write(stage)
        try:
            while True:
                kind = read(client, 1)[0]
                if kind == 0: read(client, 19)
                elif kind == 2:
                    count = struct.unpack('!xH', read(client, 3))[0]
                    encodings = struct.unpack('!' + 'i' * count, read(client, count * 4))
                    if sys.argv[2] == 'resize':
                        assert -240 in encodings, 'The client must advertise XCursor support'
                        assert 1104 in encodings, 'The client must advertise Apple Cursor Image support'
                elif kind == 3:
                    read(client, 9)
                    if sys.argv[2] == 'empty-cursor' and not sent_empty_cursor:
                        empty_cursor = struct.pack('!HHHHi', 0, 0, 0, 0, -240)
                        desktop = struct.pack('!HHHHi', 0, 0, 2, 2, 0) + b'\x00\x00\xff\x00' * 4
                        client.sendall(struct.pack('!BBH', 0, 0, 2) + empty_cursor + desktop)
                        sent_empty_cursor = True
                        continue
                    # Incremental requests with no new pixels should not
                    # trigger another framebuffer update. Repeating the
                    # resized frame here starves the app's main queue and
                    # does not model an RFB server waiting for changes.
                    if sys.argv[2] == 'resize' and resized_frame_sent:
                        continue
                    if sys.argv[2] == 'resize' and initial_frame_sent and not resized:
                        # Keep the one outstanding incremental request pending
                        # until the test asks the server to change geometry.
                        # Ignoring it would leave the client waiting forever
                        # without another request to observe the trigger.
                        while not os.path.exists(sys.argv[1] + '.resize') and client.fileno() >= 0:
                            time.sleep(0.01)
                    if sys.argv[2] == 'resize' and not sent_cursor:
                        xcursor = (
                            struct.pack('!HHHHi', 1, 1, 2, 2, -240)
                            + b'\xff\xff\xff\x00\x00\x00' + b'\xc0\xc0' + b'\xc0\xc0'
                        )
                        initial_pixels = struct.pack('!HHHHi', 0, 0, 2, 2, 0) + b'\x00\x00\xff\x00' * 4
                        client.sendall(struct.pack('!BBH', 0, 0, 2) + xcursor + initial_pixels)
                        sent_cursor = True
                        initial_frame_sent = True
                        continue
                    if sys.argv[2] == 'resize' and os.path.exists(sys.argv[1] + '.resize'):
                        if not resized:
                            # RFC 6143 requires DesktopSize to be the last
                            # rectangle in its update. Send it by itself, then
                            # deliver pixels and cursor data in the next one.
                            client.sendall(struct.pack('!BBHHHHHi', 0, 0, 1, 0, 0, 5, 3, -223))
                            resized = True
                            write_stage('desktop-size-sent')
                            continue

                        # The client requests another update after applying
                        # DesktopSize. Populate the new framebuffer and then
                        # exercise Apple's cached cursor format in that update.
                        apple_cursor = (
                            b'\xff\xff\x00\x00' + b'\x00\xff\xff\x00' + b'\xff\x00\xff\x00'
                            + b'\x00\x00\x00\x00' * 3 + b'\xff\xff' + b'\x00' * 4
                        )
                        green_cursor = b'\x00\xff\x00\x00\xff'
                        stored_cursors = [
                            (1000, 2, 1, 3, 2, apple_cursor),
                            (1001, 0, 0, 1, 1, green_cursor),
                        ]
                        rectangles = [
                            struct.pack('!HHHHi', 0, 0, 5, 3, 0) + b'\xff\x00\x00\x00' * 15,
                        ]
                        for cache_id, hotspot_x, hotspot_y, width, height, cursor_data in stored_cursors:
                            compressor = zlib.compressobj(9)
                            compressed = compressor.compress(cursor_data) + compressor.flush(zlib.Z_SYNC_FLUSH)
                            rectangles.append(
                                struct.pack('!HHHHiII', hotspot_x, hotspot_y, width, height, 1104, cache_id, len(compressed))
                                + compressed
                            )
                        rectangles.append(struct.pack('!HHHHiII', 0, 0, 0, 0, 1104, 1000, 0))
                        client.sendall(struct.pack('!BBH', 0, 0, len(rectangles)) + b''.join(rectangles))
                        resized_frame_sent = True
                        write_stage('resized-frame-and-apple-cursor-sent')
                        continue
                    if first_frame is None: first_frame = time.monotonic()
                    black = sys.argv[2] == 'black' and time.monotonic() - first_frame < 9
                    pixel = b'\xff\x00\x00\x00' if resized else (b'\x00\x00\x00\x00' if black else b'\x00\x00\xff\x00')
                    width, height = (5, 3) if resized else (2, 2)
                    client.sendall(struct.pack('!BBHHHHHi', 0, 0, 1, 0, 0, width, height, 0) + pixel * width * height)
                    if sys.argv[2] == 'resize' and resized:
                        resized_frame_sent = True
                    elif sys.argv[2] == 'resize':
                        initial_frame_sent = True
                elif kind == 4:
                    down = read(client, 1)[0]
                    read(client, 2)
                    keysym = struct.unpack('!I', read(client, 4))[0]
                    if sys.argv[2] == 'keyboard':
                        with open(sys.argv[1] + '.keys', 'a') as out:
                            out.write(f'{down}:{keysym:08x}\n')
                elif kind == 5:
                    read(client, 5)
                elif kind == 6:
                    count = struct.unpack('!xxxI', read(client, 7))[0]
                    read(client, count)
                elif kind == 130:
                    read(client, 1)  # flags
                    name_size = struct.unpack('!H', read(client, 2))[0]
                    read(client, name_size)
                    client.sendall(b'\x82\x00\x00\x00\x00\x00\x00\x00')
                elif kind == 132:
                    header = read(client, 7)
                    name_size = struct.unpack('!H', header[1:3])[0]
                    upload_name = read(client, name_size).decode('utf-8')
                    if sys.argv[2] == 'tight-upload-multiple':
                        assert upload_name in ('/first.txt', '/second.bin')
                    else:
                        assert upload_name == '/fjarrconnect-upload-fixture.txt'
                    upload_data = b''
                elif kind == 133:
                    header = read(client, 5)
                    real_size, encoded_size = struct.unpack('!HH', header[1:5])
                    assert real_size == encoded_size
                    if real_size == 0:
                        read(client, 4)  # modification time at end of upload
                        destination = (sys.argv[3] + '.' + upload_name.rsplit('/', 1)[-1]
                                       if sys.argv[2] == 'tight-upload-multiple' else sys.argv[3])
                        with open(destination, 'wb') as uploaded:
                            uploaded.write(upload_data)
                    else:
                        upload_data += read(client, encoded_size)
                else: break
        except (EOFError, ConnectionError): pass
"""#
}
