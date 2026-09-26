import XCTest
import Combine
import SwiftUI
@testable import RoyalVNCKit
@testable import FjarrConnect

private struct VNCSessionScreenView: View {
    @ObservedObject var session: VNCRemoteSession
    var body: some View { session.makeScreenView() }
}

/// A local RFB server exercises the actual RoyalVNCKit handshake and session lifecycle.
final class VNCIntegrationTests: XCTestCase {
    func testVNCConnectsToLocalServerAndStops() throws {
        try exerciseServer(requiresUsername: false)
    }

    func testAppleVNCExplainsMissingUsername() throws {
        try exerciseServer(requiresUsername: true)
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

    func testAuthenticatedLiveMacVNCUsesSavedKeychainProfileAndReportsCapabilities() throws {
        guard ProcessInfo.processInfo.environment["FJARRCONNECT_TEST_LIVE_MAC_VNC_AUTHENTICATED"] == "1",
              let host = ProcessInfo.processInfo.environment["FJARRCONNECT_TEST_LIVE_MAC_VNC_HOST"],
              ConnectionURI.validHost(host) else {
            throw XCTSkip("Opt in with FJARRCONNECT_TEST_LIVE_MAC_VNC_AUTHENTICATED=1 and FJARRCONNECT_TEST_LIVE_MAC_VNC_HOST; credentials are read from the saved profile Keychain item")
        }
        let store = ProfileStore()
        guard let profile = store.profiles.first(where: {
            $0.host == host && $0.transport == .vnc && $0.usesMacScreenSharingAuthentication
        }) else {
            throw XCTSkip("No saved Mac Screen Sharing profile exists for the selected host")
        }
        guard !profile.requiresBiometricUnlock else {
            throw XCTSkip("The saved profile requires interactive biometric authentication")
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

        let session = VNCRemoteSession(profile: profile, password: password)
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
        }

        session.start()
        XCTAssertEqual(XCTWaiter.wait(for: [resolved], timeout: 30), .completed,
                       "The saved Mac VNC profile should authenticate or return a bounded connection error")
        XCTAssertTrue(session.status.isEstablished, "The saved Mac VNC credential was not accepted")
        guard session.status.isEstablished else { return }

        print("[VNC live] Mac Screen Sharing authenticated; file-list/download=\(session.fileTransferAvailable); upload=\(session.fileUploadAvailable)")
        let framebuffer = session.recordingView as? VNCCAFramebufferView
        let visibleMetalLayer = framebuffer?.layer?.sublayers?.contains { layer in
            layer is CAMetalLayer && !layer.isHidden
        } ?? false
        print("[VNC live] framebuffer-created=\(framebuffer != nil); framebuffer-size=\(framebuffer?.framebufferSize.width ?? 0)x\(framebuffer?.framebufferSize.height ?? 0); metal-layer-active=\(visibleMetalLayer)")
        XCTAssertNotNil(framebuffer, "An established VNC session should install its framebuffer in the application session")
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

    func testVNCAuthenticatesWithPasswordAndReceivesDesktop() throws {
        try exerciseServer(requiresUsername: false, requiresPassword: true)
    }

    func testRejectedVNCPasswordIsReportedForCredentialRetry() throws {
        try exerciseServer(requiresUsername: false, requiresPassword: true,
                           clientPassword: "wrong-test-password", expectsCredentialRejection: true)
    }

    func testTightFileBrowserAppearsWhenTheServerAdvertisesDownloadChannels() throws {
        try exerciseServer(requiresUsername: false, tightFileTransfer: true)
    }

    func testTightReadOnlyServerStillOffersFileDownloads() throws {
        try exerciseServer(requiresUsername: false, tightDownloadOnly: true)
    }

    func testTightUploadSendsFileWhenServerAdvertisesUploadChannel() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("fjarrconnect-upload-fixture.txt")
        let payload = Data((0..<150_000).map { UInt8($0 % 251) })
        try payload.write(to: source, options: .atomic)
        defer { try? FileManager.default.removeItem(at: source) }
        try exerciseServer(requiresUsername: false, uploadFile: source, expectedUpload: payload)
    }

    func testTightUploadSendsDroppedFilesSequentially() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = [directory.appendingPathComponent("first.txt"), directory.appendingPathComponent("second.bin")]
        let payloads = [Data("first-file".utf8), Data((0..<90_000).map { UInt8($0 % 239) })]
        for (source, payload) in zip(sources, payloads) { try payload.write(to: source, options: .atomic) }
        try exerciseServer(requiresUsername: false, uploadFiles: sources, expectedUploads: payloads)
    }

    func testBlackDesktopHintClearsWhenServerStartsSendingContent() throws {
        try exerciseServer(requiresUsername: false, blackInitially: true)
    }

    func testDesktopResizeReplacesTheDisplayedFramebuffer() throws {
        try exerciseServer(requiresUsername: false, resize: true)
    }

    func testConnectedVNCDesktopReceivesInitialKeyboardFocus() throws {
        try exerciseServer(requiresUsername: false, verifyInitialFocus: true)
    }

    func testInternationalKeyboardCharactersReachVNCServer() throws {
        try exerciseServer(requiresUsername: false, keyboard: true)
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

    func testVNCRejectsAnUnknownSecurityType() throws {
        try exerciseServer(requiresUsername: false, unsupportedSecurity: true)
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

    private func exerciseServer(requiresUsername: Bool, requiresPassword: Bool = false,
                                blackInitially: Bool = false, resize: Bool = false, keyboard: Bool = false,
                                verifyInitialFocus: Bool = false,
                                unsupportedSecurity: Bool = false, tightFileTransfer: Bool = false,
                                tightDownloadOnly: Bool = false, uploadFile: URL? = nil,
                                expectedUpload: Data? = nil, uploadFiles: [URL]? = nil,
                                expectedUploads: [Data]? = nil, clientPassword: String? = nil,
                                expectsCredentialRejection: Bool = false) throws {
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
        let ready = expectation(description: "RFB server listening")
        DispatchQueue.global().async {
            for _ in 0..<220 {
                if FileManager.default.fileExists(atPath: portFile.path) || !server.isRunning { ready.fulfill(); return }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        wait(for: [ready], timeout: 12)
        guard FileManager.default.fileExists(atPath: portFile.path) else {
            XCTFail("RFB fixture did not start: " + ((try? String(contentsOf: diagnostics, encoding: .utf8)) ?? "No diagnostics"))
            return
        }
        let port = try XCTUnwrap(UInt16(String(contentsOf: portFile, encoding: .utf8)))
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
        wait(for: [connected], timeout: 10)
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
            XCTAssertEqual(session.status, .connected)
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
                XCTAssertEqual(XCTWaiter.wait(for: [listingLoaded], timeout: 5), .completed)
                session.uploadLocalFile(uploadFile)
                let uploadSent = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    session.fileTransferNotice == NSLocalizedString("vnc.files.uploadSent", comment: "")
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [uploadSent], timeout: 5), .completed)
                let uploadedFile = URL(fileURLWithPath: portFile.path + ".uploaded")
                let received = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    (try? Data(contentsOf: uploadedFile)) == expectedUpload
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 5), .completed)
            }
            if let uploadFiles, let expectedUploads {
                XCTAssertFalse(session.canUploadLocalFiles(uploadFiles), "Do not upload before checking remote-name conflicts.")
                session.browseRemoteFiles("/")
                let listingLoaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    session.listedRemoteDirectory == "/" && !session.isLoadingRemoteFiles
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [listingLoaded], timeout: 5), .completed)
                XCTAssertTrue(session.canUploadLocalFiles(uploadFiles))
                XCTAssertFalse(session.canUploadLocalFiles([uploadFiles[0].deletingLastPathComponent()]))
                session.uploadLocalFiles(uploadFiles)
                let received = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    !session.isUploadingFile && zip(uploadFiles, expectedUploads).allSatisfy { source, payload in
                        let receivedURL = URL(fileURLWithPath: portFile.path + ".uploaded." + source.lastPathComponent)
                        return (try? Data(contentsOf: receivedURL)) == payload
                    }
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 10), .completed)
            }
            try assertRenderedDesktop(session, isBlack: blackInitially)
            if resize { try assertResize(session, trigger: URL(fileURLWithPath: portFile.path + ".resize")) }
            if keyboard { try assertKeyboardCharacters(session, receivedKeys: URL(fileURLWithPath: portFile.path + ".keys")) }
            if verifyInitialFocus { try assertInitialFocus(session) }
            if blackInitially {
                let warning = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    session.notice == NSLocalizedString("vnc.blackScreen", comment: "")
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [warning], timeout: 12), .completed)
                let recovered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    session.notice == nil
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [recovered], timeout: 6), .completed)
                XCTAssertEqual(session.status, .connected)
            }
        }
        session.stop()
        XCTAssertEqual(session.status, .disconnected(reason: nil))
        subscription.cancel()
    }

    private func assertKeyboardCharacters(_ session: VNCRemoteSession, receivedKeys: URL) throws {
        let host = NSHostingView(rootView: VNCSessionScreenView(session: session))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func framebuffer(in view: NSView) -> VNCCAFramebufferView? {
            if let frame = view as? VNCCAFramebufferView { return frame }
            return view.subviews.lazy.compactMap { framebuffer(in: $0) }.first
        }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            framebuffer(in: host)?.framebufferSize == CGSize(width: 2, height: 2)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        let view = try XCTUnwrap(framebuffer(in: host))
        XCTAssertTrue(window.makeFirstResponder(view))

        // Swedish macOS uses Option+2 for @. Also emulate resolved characters
        // from QWERTZ/AZERTY and Unicode input sources, then inspect the RFB wire.
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
            return contents.split(separator: "\n").count >= 41
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [sent], timeout: 5), .completed)
        let contents = try String(contentsOf: receivedKeys, encoding: .utf8)
        let events = try contents.split(separator: "\n").map { line -> (Bool, UInt32) in
            let fields = line.split(separator: ":")
            guard fields.count == 2, let down = Int(fields[0]), let keysym = UInt32(fields[1], radix: 16) else {
                throw NSError(domain: "VNC keyboard fixture", code: 1)
            }
            return (down == 1, keysym)
        }
        XCTAssertEqual(events.map { $0.1 }, [
            0xFFE9, 0xFFE9, 0x40, 0x40, 0xFFE9, 0xFFE9,
            0xFFE1, 0xFFE1, 0x40, 0x40, 0xFFE1, 0xFFE1,
            0x40, 0x40,
            0xFFE9, 0xFFE9, 0x40, 0x40, 0xFFE9,
            0x79, 0x79,
            0xE9, 0xE9,
            0xE5, 0xE4, 0xF6, 0xE5, 0xE4, 0xF6,
            0x010020AC, 0x010065E5, 0x0101F642,
            0x010020AC, 0x010065E5, 0x0101F642,
            0xFF08, 0xFF08, 0xFF0D, 0xFF0D, 0xFF09, 0xFF09
        ])
        XCTAssertEqual(events.map { $0.0 }, [
            true, false, true, false, true, false,
            true, false, true, false, true, false,
            true, false,
            true, false, true, false, false,
            true, false, true, false,
            true, true, true, false, false, false,
            true, true, true, false, false, false,
            true, false, true, false, true, false
        ])
    }

    private func assertResize(_ session: VNCRemoteSession, trigger: URL) throws {
        let host = NSHostingView(rootView: VNCSessionScreenView(session: session))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func framebuffer(in view: NSView) -> VNCCAFramebufferView? {
            if let frame = view as? VNCCAFramebufferView { return frame }
            return view.subviews.lazy.compactMap { framebuffer(in: $0) }.first
        }
        let original = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            framebuffer(in: host)?.framebufferSize == CGSize(width: 2, height: 2)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [original], timeout: 5), .completed)
        let originalView = try XCTUnwrap(framebuffer(in: host))
        let originalCursor = originalView.currentCursor
        XCTAssertEqual(originalCursor.image.size, CGSize(width: 2, height: 2))
        XCTAssertTrue(window.makeFirstResponder(originalView))
        try Data().write(to: trigger)
        let resized = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            framebuffer(in: host)?.framebufferSize == CGSize(width: 5, height: 3)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [resized], timeout: 5), .completed)
        let painted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let image = framebuffer(in: host)?.framebuffer?.cgImage else { return false }
            guard image.width == 5, image.height == 3,
                  let pixel = NSBitmapImageRep(cgImage: image).colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else { return false }
            return pixel.blueComponent > 0.95 && pixel.redComponent < 0.05
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [painted], timeout: 5), .completed)
        if window.isKeyWindow {
            XCTAssertTrue(window.firstResponder === framebuffer(in: host), "Keyboard focus must follow the resized desktop")
        }
        let cursor = try XCTUnwrap(framebuffer(in: host)?.currentCursor)
        XCTAssertEqual(cursor.image.size, originalCursor.image.size)
        XCTAssertEqual(cursor.hotSpot, originalCursor.hotSpot)
        let cursorData = try XCTUnwrap(cursor.image.tiffRepresentation)
        let cursorPixel = try XCTUnwrap(NSBitmapImageRep(data: cursorData)?.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(cursorPixel.alphaComponent, 0.95, "The server cursor must remain visible after a resize")
        XCTAssertGreaterThan(cursorPixel.redComponent, 0.95)
        XCTAssertGreaterThan(cursorPixel.greenComponent, 0.95)
        XCTAssertGreaterThan(cursorPixel.blueComponent, 0.95)
        XCTAssertEqual(session.status, .connected)
    }

    private func assertInitialFocus(_ session: VNCRemoteSession) throws {
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
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            framebuffer(in: host)?.framebufferSize == CGSize(width: 2, height: 2)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        guard window.isKeyWindow else {
            throw XCTSkip("Initial keyboard focus requires an unlocked macOS window session")
        }
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let view = framebuffer(in: host) else { return false }
            return window.firstResponder === view
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed,
                       "A connected VNC desktop should receive keyboard focus without a click")
    }

    private func assertRenderedDesktop(_ session: VNCRemoteSession, isBlack: Bool) throws {
        // A successful handshake alone does not prove that the app shows pixels.
        let host = NSHostingView(rootView: VNCSessionScreenView(session: session))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func framebuffer(in view: NSView) -> VNCCAFramebufferView? {
            if let frame = view as? VNCCAFramebufferView { return frame }
            return view.subviews.lazy.compactMap { framebuffer(in: $0) }.first
        }
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            framebuffer(in: host)?.layer?.contents != nil
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 5), .completed)
        let view = try XCTUnwrap(framebuffer(in: host))
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

    private static let server = #"""
import os, socket, struct, sys, time

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
        sent_cursor = False
        upload_data = b''
        try:
            while True:
                kind = read(client, 1)[0]
                if kind == 0: read(client, 19)
                elif kind == 2:
                    count = struct.unpack('!xH', read(client, 3))[0]
                    read(client, count * 4)
                elif kind == 3:
                    read(client, 9)
                    if sys.argv[2] == 'resize' and not sent_cursor:
                        client.sendall(struct.pack('!BBHHHHHi', 0, 0, 1, 0, 0, 2, 2, -239) + b'\xff\xff\xff\x00' * 4 + b'\xc0\xc0')
                        sent_cursor = True
                    if sys.argv[2] == 'resize' and not resized and os.path.exists(sys.argv[1] + '.resize'):
                        # An unaligned width exercises the CALayer image path;
                        # aligned IOSurfaces use Metal and have no layer.contents.
                        client.sendall(struct.pack('!BBHHHHHi', 0, 0, 1, 0, 0, 5, 3, -223))
                        resized = True
                        continue
                    if first_frame is None: first_frame = time.monotonic()
                    black = sys.argv[2] == 'black' and time.monotonic() - first_frame < 9
                    pixel = b'\xff\x00\x00\x00' if resized else (b'\x00\x00\x00\x00' if black else b'\x00\x00\xff\x00')
                    width, height = (5, 3) if resized else (2, 2)
                    client.sendall(struct.pack('!BBHHHHHi', 0, 0, 1, 0, 0, width, height, 0) + pixel * width * height)
                elif kind == 4:
                    down = read(client, 1)[0]
                    read(client, 2)
                    keysym = struct.unpack('!I', read(client, 4))[0]
                    if sys.argv[2] == 'keyboard':
                        with open(sys.argv[1] + '.keys', 'a') as out:
                            out.write(f'{down}:{keysym:08x}\n')
                elif kind == 5: read(client, 5)
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
