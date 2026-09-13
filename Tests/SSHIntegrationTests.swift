import XCTest
import Combine
import Darwin
@testable import FjarrConnect

final class SSHIntegrationTests: XCTestCase {
    /// Exercise the actual embedded terminal and macOS SSH process, including
    /// its failure callback, instead of substituting a mock session.
    func testClosedSSHConnectionReportsFailureAndCanBeClosed() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { shutdown(descriptor, SHUT_RDWR); Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        guard bound == 0 else { return }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        XCTAssertEqual(read, 0)
        // Accept SSH and close after the client banner, making failure deterministic
        // across macOS firewall settings instead of relying on an unused port.
        XCTAssertEqual(listen(descriptor, 1), 0)
        DispatchQueue.global().async {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            defer { Darwin.close(client) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let banner = Array("SSH-2.0-FjarrConnect-Test\r\n".utf8)
            banner.withUnsafeBytes { _ = Darwin.send(client, $0.baseAddress, $0.count, 0) }
            var bytes = [UInt8](repeating: 0, count: 1024)
            _ = Darwin.recv(client, &bytes, bytes.count, 0)
        }
        let profile = ConnectionProfile(name: "Closed SSH", transport: .ssh, host: "127.0.0.1",
                                        port: UInt16(bigEndian: address.sin_port))
        let session = SSHRemoteSession(profile: profile, password: nil)
        let exited = expectation(description: "OpenSSH reports server disconnect")
        var received = false
        let subscription = session.$status.sink { status in
            if status.isFinished && !received { received = true; exited.fulfill() }
        }
        session.start()
        XCTAssertEqual(session.status, .running)
        wait(for: [exited], timeout: 10)
        XCTAssertNotNil(session.status.error)
        session.stop()
        XCTAssertEqual(session.status, .disconnected(reason: nil))
        subscription.cancel()
    }
}
