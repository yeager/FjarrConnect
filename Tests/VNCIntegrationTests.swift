import XCTest
import Combine
@testable import FjarrConnect

/// A local RFB server exercises the actual RoyalVNCKit handshake and session lifecycle.
final class VNCIntegrationTests: XCTestCase {
    func testVNCConnectsToLocalServerAndStops() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let portFile = directory.appendingPathComponent("port")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-c", Self.server, portFile.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        let ready = expectation(description: "RFB server listening")
        DispatchQueue.global().async {
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: portFile.path) { ready.fulfill(); return }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        wait(for: [ready], timeout: 6)
        let port = try XCTUnwrap(UInt16(String(contentsOf: portFile, encoding: .utf8)))
        let session = VNCRemoteSession(profile: ConnectionProfile(name: "Local RFB", host: "127.0.0.1", port: port), password: nil)
        let connected = expectation(description: "Authenticated RFB session")
        var observed = false
        let subscription = session.$status.sink { state in
            if state == .connected && !observed { observed = true; connected.fulfill() }
        }
        session.start()
        wait(for: [connected], timeout: 10)
        XCTAssertEqual(session.status, .connected)
        session.stop()
        XCTAssertEqual(session.status, .disconnected(reason: nil))
        subscription.cancel()
    }

    private static let server = #"""
import os, socket, struct, sys

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
        client.sendall(b'\x01\x01')
        assert read(client, 1) == b'\x01'
        client.sendall(struct.pack('!I', 0))
        read(client, 1)
        name = b'FjarrConnect local test'
        client.sendall(struct.pack('!HHBBBBHHHBBBxxxI', 2, 2, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0, len(name)) + name)
        try:
            while True:
                kind = read(client, 1)[0]
                if kind == 0: read(client, 19)
                elif kind == 2:
                    count = struct.unpack('!xH', read(client, 3))[0]
                    read(client, count * 4)
                elif kind == 3:
                    read(client, 9)
                    client.sendall(struct.pack('!BBHHHHHi', 0, 0, 1, 0, 0, 2, 2, 0) + b'\x00\x00\xff\x00' * 4)
                elif kind == 4: read(client, 7)
                elif kind == 5: read(client, 5)
                elif kind == 6:
                    count = struct.unpack('!xxxI', read(client, 7))[0]
                    read(client, count)
                else: break
        except (EOFError, ConnectionError): pass
"""#
}
