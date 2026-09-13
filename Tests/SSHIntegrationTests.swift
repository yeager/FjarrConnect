import XCTest
import Combine
import Darwin
@testable import FjarrConnect

final class SSHIntegrationTests: XCTestCase {
    /// Exercise the actual embedded terminal and macOS SSH process, including
    /// its failure callback, instead of substituting a mock session.
    func testRefusedSSHConnectionReportsFailureAndCanBeClosed() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
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
        // Keep this port bound without listening, so no other service can claim it.
        let profile = ConnectionProfile(name: "Refused SSH", transport: .ssh, host: "127.0.0.1",
                                        port: UInt16(bigEndian: address.sin_port))
        let session = SSHRemoteSession(profile: profile, password: nil)
        let exited = expectation(description: "OpenSSH reports connection refusal")
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
