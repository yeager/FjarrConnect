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

    func testBlackDesktopHintClearsWhenServerStartsSendingContent() throws {
        try exerciseServer(requiresUsername: false, blackInitially: true)
    }

    func testDesktopResizeReplacesTheDisplayedFramebuffer() throws {
        try exerciseServer(requiresUsername: false, resize: true)
    }

    private func exerciseServer(requiresUsername: Bool, requiresPassword: Bool = false,
                                blackInitially: Bool = false, resize: Bool = false) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let portFile = directory.appendingPathComponent("port")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-c", Self.server, portFile.path, requiresUsername ? "username" : (requiresPassword ? "password" : (blackInitially ? "black" : (resize ? "resize" : "none")))]
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
            if (requiresUsername ? state.isFinished : state == .connected) && !observed { observed = true; connected.fulfill() }
        }
        session.start()
        wait(for: [connected], timeout: 10)
        if requiresUsername {
            XCTAssertEqual(session.status.error, NSLocalizedString("vnc.usernameRequired", comment: ""))
        } else {
            XCTAssertEqual(session.status, .connected)
            try assertRenderedDesktop(session, isBlack: blackInitially)
            if resize { try assertResize(session, trigger: URL(fileURLWithPath: portFile.path + ".resize")) }
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
            framebuffer(in: host)?.framebufferSize == CGSize(width: 4, height: 3)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [resized], timeout: 5), .completed)
        let painted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let contents = framebuffer(in: host)?.layer?.contents else { return false }
            let image = contents as! CGImage
            guard image.width == 4, image.height == 3,
                  let pixel = NSBitmapImageRep(cgImage: image).colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else { return false }
            return pixel.blueComponent > 0.95 && pixel.redComponent < 0.05
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [painted], timeout: 5), .completed)
        XCTAssertTrue(window.firstResponder === framebuffer(in: host), "Keyboard focus must follow the resized desktop")
        XCTAssertTrue(framebuffer(in: host)?.currentCursor === originalCursor, "The server cursor must survive a desktop resize")
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
        client.sendall(b'RFB 003.008\n')
        read(client, 12)
        if sys.argv[2] == 'username':
            client.sendall(b'\x01\x1e')
            assert read(client, 1) == b'\x1e'
            # No credentials are submitted: only the ARD challenge is needed.
            client.sendall(struct.pack('!HH', 5, 512) + b'\xff' * 512 + b'\x01' * 512)
            assert client.recv(1) == b''
            sys.exit(0)
        if sys.argv[2] == 'password':
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
        first_frame = None
        resized = False
        sent_cursor = False
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
                        client.sendall(struct.pack('!BBHHHHHi', 0, 0, 1, 0, 0, 4, 3, -223))
                        resized = True
                        continue
                    if first_frame is None: first_frame = time.monotonic()
                    black = sys.argv[2] == 'black' and time.monotonic() - first_frame < 9
                    pixel = b'\xff\x00\x00\x00' if resized else (b'\x00\x00\x00\x00' if black else b'\x00\x00\xff\x00')
                    width, height = (4, 3) if resized else (2, 2)
                    client.sendall(struct.pack('!BBHHHHHi', 0, 0, 1, 0, 0, width, height, 0) + pixel * width * height)
                elif kind == 4: read(client, 7)
                elif kind == 5: read(client, 5)
                elif kind == 6:
                    count = struct.unpack('!xxxI', read(client, 7))[0]
                    read(client, count)
                else: break
        except (EOFError, ConnectionError): pass
"""#
}
