import XCTest
import Network
import Combine
@testable import FjarrConnect

final class DiscoveryTests: XCTestCase {
    func testSubnetBoundsAndHostAddresses() throws {
        let subnet = try XCTUnwrap(IPv4Subnet(" 192.168.1.151/24 "))
        XCTAssertEqual(subnet.description, "192.168.1.0/24")
        XCTAssertEqual(subnet.hosts.count, 254)
        XCTAssertEqual(subnet.hosts.first, "192.168.1.1")
        XCTAssertEqual(subnet.hosts.last, "192.168.1.254")
        XCTAssertEqual(IPv4Subnet("10.0.0.1/31")?.hosts, ["10.0.0.0", "10.0.0.1"])
        XCTAssertEqual(IPv4Subnet("127.0.0.1/32")?.hosts, ["127.0.0.1"])
        XCTAssertEqual(IPv4Subnet("10.0.0.0/20")?.hosts.count, 4094)
        for value in ["", "example.local/24", "10.0.0.1/19", "10.0.0.1/33", "0.0.0.0/24", "224.0.0.1/24", "256.0.0.0/24", "10.0.0/24", "::1/32", "10.0.0.1/24/32"] {
            XCTAssertNil(IPv4Subnet(value), value)
        }
        XCTAssertEqual(ScanService.ports("5901, 5900,5901"), [5900,5901])
        for value in ["", "0", "65536", "22,", "-22", "1-65535", "1,2,3,4,5,6,7,8,9"] { XCTAssertNil(ScanService.ports(value)) }
    }

    func testProtocolIdentificationRequiresActualHandshakeAndHandlesFragments() {
        let vnc = Data("RFB 003.008\n".utf8)
        let rdp = Data([3,0,0,19,14,0xd0,0,0,0,0,0,2,0,8,0,2,0,0,0])
        let ssh = Data("Information åäö\r\nSSH-2.0-OpenSSH_9.6\r\n".utf8)
        for (transport, packet) in [(RemoteTransport.vnc,vnc), (.rdp,rdp), (.ssh,ssh)] {
            for length in 0..<packet.count {
                XCTAssertEqual(ServiceHandshake.inspect(Data(packet.prefix(length)), transport: transport), .incomplete, "\(transport) length \(length)")
            }
            XCTAssertEqual(ServiceHandshake.inspect(packet, transport: transport), .matched)
            XCTAssertEqual(ServiceHandshake.inspect(Data(repeating: 0, count: 4097), transport: transport), .invalid)
        }
        XCTAssertEqual(ServiceHandshake.inspect(Data("HTTP/1.1 200 OK\r\n".utf8), transport: .vnc), .invalid)
        XCTAssertEqual(ServiceHandshake.inspect(Data("SSH-2.0-\r\n".utf8), transport: .ssh), .invalid)
        XCTAssertEqual(ServiceHandshake.inspect(Data("SSH-1.5-old\n".utf8), transport: .ssh), .invalid)
        var refusal = rdp; refusal[11] = 3
        XCTAssertEqual(ServiceHandshake.inspect(refusal, transport: .rdp), .matched)
        XCTAssertEqual(ServiceHandshake.inspect(Data([3,0,0,11,6,0xd0,0,0,0,0,0]), transport: .rdp), .matched)
        for offset in [0,1,4,5,10,11,13,14] {
            var invalid = rdp; invalid[offset] = 0xff
            XCTAssertEqual(ServiceHandshake.inspect(invalid, transport: .rdp), .invalid, "offset \(offset)")
        }
    }

    @MainActor
    func testLoopbackScanFindsThreeProtocolsAndRejectsAnUnrelatedOpenPort() async throws {
        let vnc = try await DiscoveryFixture.open(reply: Data("RFB 003.008\n".utf8))
        let request = expectation(description: "RDP negotiation only")
        let rdp = try await DiscoveryFixture.open(reply: Data([3,0,0,19,14,0xd0,0,0,0,0,0,2,0,8,0,2,0,0,0]), request: { bytes in
            XCTAssertEqual(bytes, ServiceHandshake.rdpRequest)
            request.fulfill()
        })
        let ssh = try await DiscoveryFixture.open(reply: Data("Welcome\r\nSSH-2.0-fixture\r\n".utf8))
        let http = try await DiscoveryFixture.open(reply: Data("HTTP/1.1 200 OK\r\n".utf8))
        defer { [vnc,rdp,ssh,http].forEach { $0.close() } }
        let scanner = NetworkScanner()
        let done = expectation(description: "scan finishes")
        let observation = scanner.$state.sink { if $0 == .finished { done.fulfill() } }
        scanner.start(subnet: try XCTUnwrap(IPv4Subnet("127.0.0.1/32")), services: [
            ScanService(transport: .vnc, port: vnc.port), ScanService(transport: .rdp, port: rdp.port),
            ScanService(transport: .ssh, port: ssh.port), ScanService(transport: .vnc, port: http.port)
        ], concurrency: 2)
        await fulfillment(of: [done,request], timeout: 5)
        withExtendedLifetime(observation) {}
        XCTAssertEqual(Set(scanner.hosts.map(\.service.transport)), [.vnc,.rdp,.ssh])
        XCTAssertEqual(scanner.hosts.count, 3)
        XCTAssertEqual(scanner.completed, 4)
        XCTAssertNil(scanner.errorMessage)
    }

    @MainActor
    func testTimeoutCancellationAndRestartDoNotKeepOldResults() async throws {
        let silent = try await DiscoveryFixture.open(reply: nil)
        let valid = try await DiscoveryFixture.open(reply: Data("RFB 003.008\n".utf8), replyDelay: 0.3)
        defer { silent.close(); valid.close() }
        let scanner = NetworkScanner()
        let subnet = try XCTUnwrap(IPv4Subnet("127.0.0.1/32"))
        let timedOut = expectation(description: "silent service reaches deadline")
        var observation = scanner.$state.sink { if $0 == .finished { timedOut.fulfill() } }
        scanner.start(subnet: subnet, services: [ScanService(transport: .vnc, port: silent.port)], timeout: 0.15)
        await fulfillment(of: [timedOut], timeout: 3)
        XCTAssertEqual(scanner.completed, 1)
        XCTAssertTrue(scanner.hosts.isEmpty)
        observation.cancel()
        let accepted = expectation(description: "old connection is active before cancellation")
        silent.onNextConnection { accepted.fulfill() }
        scanner.start(subnet: subnet, services: [ScanService(transport: .vnc, port: silent.port)], timeout: 0.15)
        await fulfillment(of: [accepted], timeout: 3)
        scanner.stop()
        XCTAssertEqual(scanner.state, .cancelled)
        let restarted = expectation(description: "new scan finishes")
        observation = scanner.$state.sink { if $0 == .finished { restarted.fulfill() } }
        scanner.start(subnet: subnet, services: [ScanService(transport: .vnc, port: valid.port)])
        await fulfillment(of: [restarted], timeout: 3)
        withExtendedLifetime(observation) {}
        XCTAssertEqual(scanner.hosts.map(\.service.port), [valid.port])
        XCTAssertEqual(scanner.completed, 1)
    }

    @MainActor
    func testOptInLiveNetworkDiscovery() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let cidr = environment["FJARRCONNECT_TEST_DISCOVERY_CIDR"],
              let expected = environment["FJARRCONNECT_TEST_DISCOVERY_EXPECT"] else { throw XCTSkip("Explicit network and expected host required") }
        let subnet = try XCTUnwrap(IPv4Subnet(cidr))
        let scanner = NetworkScanner()
        let done = expectation(description: "live discovery")
        let observation = scanner.$state.sink { if $0 == .finished || $0 == .cancelled { done.fulfill() } }
        scanner.start(subnet: subnet, services: [ScanService(transport: .vnc, port: 5900), ScanService(transport: .vnc, port: 5901), ScanService(transport: .rdp, port: 3389), ScanService(transport: .ssh, port: 22)])
        await fulfillment(of: [done], timeout: 150)
        withExtendedLifetime(observation) {}
        XCTAssertNil(scanner.errorMessage)
        XCTAssertTrue(scanner.hosts.contains { $0.address == expected })
        for host in scanner.hosts { print("Discovered: \(host.profile.uri)") }
        print("Discovery completed: \(scanner.completed)/\(scanner.total)")
    }
}

private final class DiscoveryFixture: @unchecked Sendable {
    // Mutable fixture state is confined to queue. NWListener.port is thread-safe.
    private let listener: NWListener
    private let queue = DispatchQueue(label: "discovery.fixture")
    private var connections: [NWConnection] = []
    private var started = false
    private var nextConnection: (() -> Void)?
    var port: UInt16 { listener.port!.rawValue }
    private init(reply: Data?, request: ((Data) -> Void)?, replyDelay: TimeInterval) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.nextConnection?(); self.nextConnection = nil
            self.connections.append(connection)
            connection.start(queue: self.queue)
            func sendReply() {
                guard let reply else { return }
                connection.send(content: Data(reply.prefix(3)), completion: .contentProcessed { _ in
                    self.queue.asyncAfter(deadline: .now() + replyDelay) {
                        connection.send(content: Data(reply.dropFirst(3)), completion: .contentProcessed { _ in })
                    }
                })
            }
            if let request {
                connection.receive(minimumIncompleteLength: 19, maximumLength: 4096) { data, _, _, _ in
                    request(data ?? Data()); sendReply()
                }
            } else { sendReply() }
        }
    }
    static func open(reply: Data?, request: ((Data) -> Void)? = nil, replyDelay: TimeInterval = 0.03) async throws -> DiscoveryFixture {
        let fixture = try DiscoveryFixture(reply: reply, request: request, replyDelay: replyDelay)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            fixture.listener.stateUpdateHandler = { [weak fixture] state in
                guard let fixture, !fixture.started else { return }
                switch state {
                case .ready: fixture.started = true; continuation.resume()
                case .failed(let error): fixture.started = true; continuation.resume(throwing: error)
                default: break
                }
            }
            fixture.listener.start(queue: fixture.queue)
        }
        return fixture
    }
    func onNextConnection(_ callback: @escaping () -> Void) { queue.async { self.nextConnection = callback } }
    func close() {
        listener.cancel()
        queue.async { for connection in self.connections { connection.cancel() }; self.connections.removeAll() }
    }
}
