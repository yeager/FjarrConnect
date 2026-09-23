import XCTest
import Combine
import SwiftUI
import RoyalVNCKit
@testable import FjarrConnect

/// A local RFB server exercises the actual RoyalVNCKit handshake and session lifecycle.
final class VNCIntegrationTests: XCTestCase {
    func testVNCConnectsToLocalServerAndStops() throws {
        try exerciseServer(requiresUsername: false)
    }

    func testAppleVNCExplainsMissingUsername() throws {
        try exerciseServer(requiresUsername: true)
    }

    func testVNCAuthenticatesWithPasswordAndReceivesDesktop() throws {
        try exerciseServer(requiresUsername: false, requiresPassword: true)
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

    func testBlackDesktopHintClearsWhenServerStartsSendingContent() throws {
        try exerciseServer(requiresUsername: false, blackInitially: true)
    }

    func testDesktopResizeReplacesTheDisplayedFramebuffer() throws {
        try exerciseServer(requiresUsername: false, resize: true)
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

    private func exerciseServer(requiresUsername: Bool, requiresPassword: Bool = false,
                                blackInitially: Bool = false, resize: Bool = false, keyboard: Bool = false,
                                unsupportedSecurity: Bool = false, tightFileTransfer: Bool = false,
                                tightDownloadOnly: Bool = false, uploadFile: URL? = nil,
                                expectedUpload: Data? = nil) throws {
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
        else if uploadFile != nil { mode = "tight-upload" }
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
        let session = VNCRemoteSession(profile: ConnectionProfile(name: "Local RFB", host: "127.0.0.1", port: port), password: requiresPassword ? "vnc-test" : nil)
        let connected = expectation(description: "Authenticated RFB session")
        var observed = false
        let subscription = session.$status.sink { state in
            if ((requiresUsername || unsupportedSecurity) ? state.isFinished : state == .connected) && !observed { observed = true; connected.fulfill() }
        }
        session.start()
        wait(for: [connected], timeout: 10)
        if requiresUsername {
            XCTAssertEqual(session.status.error, NSLocalizedString("vnc.usernameRequired", comment: ""))
        } else if unsupportedSecurity {
            XCTAssertTrue(session.status.error?.contains(NSLocalizedString("vnc.unsupportedSecurity", comment: "")) == true)
        } else {
            XCTAssertEqual(session.status, .connected)
            XCTAssertEqual(session.fileTransferAvailable, tightFileTransfer || tightDownloadOnly || uploadFile != nil,
                            "A server advertising file-list and download messages should expose the read-only file browser.")
            XCTAssertEqual(session.fileUploadAvailable, tightFileTransfer || uploadFile != nil,
                            "Upload must be available only when the server advertises upload messages.")
            if let uploadFile {
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
            try assertRenderedDesktop(session, isBlack: blackInitially)
            if resize { try assertResize(session, trigger: URL(fileURLWithPath: portFile.path + ".resize")) }
            if keyboard { try assertKeyboardCharacters(session, receivedKeys: URL(fileURLWithPath: portFile.path + ".keys")) }
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
        let host = NSHostingView(rootView: session.makeScreenView())
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

        let sent = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let contents = try? String(contentsOf: receivedKeys, encoding: .utf8) else { return false }
            return contents.split(separator: "\n").count >= 20
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
            0xFFE9, 0x32, 0x32, 0xFFE9,
            0x79, 0x79,
            0xE9, 0xE9,
            0xE5, 0xE4, 0xF6, 0xE5, 0xE4, 0xF6,
            0x010020AC, 0x010065E5, 0x0101F642,
            0x010020AC, 0x010065E5, 0x0101F642
        ])
        XCTAssertEqual(events.map { $0.0 }, [
            true, true, false, false,
            true, false, true, false,
            true, true, true, false, false, false,
            true, true, true, false, false, false
        ])
    }

    private func assertResize(_ session: VNCRemoteSession, trigger: URL) throws {
        let host = NSHostingView(rootView: session.makeScreenView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        // Mirrors SessionTab's forwarding of backend changes into SwiftUI.
        let updates = session.objectWillChange.sink {
            DispatchQueue.main.async { host.rootView = session.makeScreenView() }
        }
        defer { updates.cancel() }
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
            guard let contents = framebuffer(in: host)?.layer?.contents else { return false }
            let image = contents as! CGImage
            guard image.width == 5, image.height == 3,
                  let pixel = NSBitmapImageRep(cgImage: image).colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else { return false }
            return pixel.blueComponent > 0.95 && pixel.redComponent < 0.05
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [painted], timeout: 5), .completed)
        XCTAssertTrue(window.firstResponder === framebuffer(in: host), "Keyboard focus must follow the resized desktop")
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

    private func assertRenderedDesktop(_ session: VNCRemoteSession, isBlack: Bool) throws {
        // A successful handshake alone does not prove that the app shows pixels.
        let host = NSHostingView(rootView: session.makeScreenView())
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
        if sys.argv[2] in ('tight-files', 'tight-download', 'tight-upload'):
            client.sendall(b'\x01\x10')
            assert read(client, 1) == b'\x10'
            client.sendall(struct.pack('!II', 0, 0))
        elif sys.argv[2] == 'password':
            client.sendall(b'\x01\x02')
            assert read(client, 1) == b'\x02'
            client.sendall(bytes(range(16)))
            # Fixed test-only challenge response for the dummy password vnc-test.
            assert read(client, 16) == bytes.fromhex('6462c8f87dc31b5642d39beecb016a32')
        else:
            client.sendall(b'\x01\x01')
            assert read(client, 1) == b'\x01'
        client.sendall(struct.pack('!I', 0))
        read(client, 1)
        name = b'FjarrConnect local test'
        client.sendall(struct.pack('!HHBBBBHHHBBBxxxI', 2, 2, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0, len(name)) + name)
        if sys.argv[2] in ('tight-files', 'tight-download', 'tight-upload'):
            def capability(code, vendor, signature):
                return struct.pack('!I', code) + vendor.encode('ascii') + signature.encode('ascii')
            messages = [capability(130, 'TGHT', 'FTS_LSDT'), capability(131, 'TGHT', 'FTS_DNDT')]
            clients = [capability(130, 'TGHT', 'FTC_LSRQ'), capability(131, 'TGHT', 'FTC_DNRQ')]
            if sys.argv[2] in ('tight-files', 'tight-upload'):
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
                elif kind == 132:
                    header = read(client, 7)
                    name_size = struct.unpack('!H', header[1:3])[0]
                    upload_name = read(client, name_size).decode('utf-8')
                    assert upload_name == '/fjarrconnect-upload-fixture.txt'
                elif kind == 133:
                    header = read(client, 5)
                    real_size, encoded_size = struct.unpack('!HH', header[1:5])
                    assert real_size == encoded_size
                    if real_size == 0:
                        read(client, 4)  # modification time at end of upload
                        with open(sys.argv[3], 'wb') as uploaded:
                            uploaded.write(upload_data)
                    else:
                        upload_data += read(client, encoded_size)
                else: break
        except (EOFError, ConnectionError): pass
"""#
}
