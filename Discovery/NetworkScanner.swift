import Foundation
import Network
import Combine

struct ScanService: Hashable {
    let transport: RemoteTransport
    let port: UInt16

    static func ports(_ text: String) -> [UInt16]? {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        guard (1...8).contains(parts.count) else { return nil }
        var ports = Set<UInt16>()
        for part in parts {
            let value = part.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }), let port = UInt16(value), port > 0 else { return nil }
            ports.insert(port)
        }
        return ports.sorted()
    }
}

struct ScannedHost: Identifiable, Hashable {
    let id = UUID()
    let address: String
    let service: ScanService
    var profile: ConnectionProfile { ConnectionProfile(name: address, transport: service.transport, host: address, port: service.port) }
}

/// Public state and lifecycle are owned by the main queue; socket work is serialized off it.
final class NetworkScanner: ObservableObject {
    enum State { case idle, scanning, finished, cancelled }
    @Published private(set) var state = State.idle
    @Published private(set) var hosts: [ScannedHost] = []
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var errorMessage: String?
    var isScanning: Bool { state == .scanning }
    private(set) var lastSubnet: String?
    private(set) var lastServices: [ScanService] = []
    private var run: DiscoveryScanRun?
    private var generation = UUID()

    func start(subnet: IPv4Subnet, services: [ScanService], timeout: TimeInterval = 2, concurrency: Int = 32) {
        stop()
        let services = Array(Set(services))
        let addresses = subnet.hosts
        guard !services.isEmpty, services.allSatisfy({ $0.transport != .sftp && $0.port > 0 }),
              addresses.count * services.count <= 16384 else {
            errorMessage = NSLocalizedString("discovery.scan.invalid", comment: ""); return
        }
        lastSubnet = subnet.description; lastServices = services
        hosts = []; completed = 0; total = addresses.count * services.count; errorMessage = nil
        state = .scanning
        let token = UUID(); generation = token
        let run = DiscoveryScanRun(addresses: addresses, services: services, timeout: timeout, concurrency: concurrency) { [weak self] completed, host, denied in
            DispatchQueue.main.async {
                guard let self, self.generation == token, self.isScanning else { return }
                self.completed = completed
                if let host {
                    self.hosts.append(host)
                    self.hosts.sort {
                        let left = IPv4Subnet.number($0.address) ?? 0, right = IPv4Subnet.number($1.address) ?? 0
                        return left == right ? $0.service.port < $1.service.port : left < right
                    }
                }
                if denied {
                    self.errorMessage = NSLocalizedString("discovery.scan.denied", comment: "")
                    self.stop()
                } else if completed == self.total { self.state = .finished; self.run = nil }
            }
        }
        self.run = run
        run.start()
    }

    func stop() {
        generation = UUID()
        run?.cancel(); run = nil
        if isScanning { state = .cancelled }
    }
    deinit { run?.cancel() }
}

private final class DiscoveryScanRun {
    private let queue = DispatchQueue(label: "se.fjarrconnect.discovery", qos: .utility)
    private let addresses: [String]
    private let services: [ScanService]
    private let timeout: TimeInterval
    private let concurrency: Int
    private let report: (Int, ScannedHost?, Bool) -> Void
    private var probes: [Int: ServiceProbe] = [:]
    private var next = 0
    private var completed = 0
    private var stopped = false
    private var count: Int { addresses.count * services.count }

    init(addresses: [String], services: [ScanService], timeout: TimeInterval, concurrency: Int,
         report: @escaping (Int, ScannedHost?, Bool) -> Void) {
        self.addresses = addresses; self.services = services
        self.timeout = min(10, max(0.1, timeout)); self.concurrency = min(64, max(1, concurrency)); self.report = report
    }
    func start() { queue.async { self.fillSlots() } }
    func cancel() {
        queue.async { self.stopOnQueue() }
    }
    private func stopOnQueue() {
        guard !stopped else { return }
        stopped = true
        let probes = Array(self.probes.values); self.probes.removeAll()
        for probe in probes { probe.cancel() }
    }
    private func fillSlots() {
        guard !stopped else { return }
        while probes.count < concurrency && next < count {
            let index = next; next += 1
            let host = ScannedHost(address: addresses[index / services.count], service: services[index % services.count])
            let probe = ServiceProbe(host: host, queue: queue, timeout: timeout) { [weak self] matched, denied in
                guard let self, !self.stopped else { return }
                self.probes.removeValue(forKey: index); self.completed += 1
                if matched || denied || self.completed % 16 == 0 || self.completed == self.count {
                    self.report(self.completed, matched ? host : nil, denied)
                }
                if denied { self.stopOnQueue() } else { self.fillSlots() }
            }
            probes[index] = probe
            probe.start()
        }
    }
}

private final class ServiceProbe {
    private let host: ScannedHost
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let timeout: TimeInterval
    private let completion: (Bool, Bool) -> Void
    private var deadline: DispatchSourceTimer?
    private var reply = Data()
    private var finished = false
    private var ready = false

    init(host: ScannedHost, queue: DispatchQueue, timeout: TimeInterval, completion: @escaping (Bool, Bool) -> Void) {
        self.host = host; self.queue = queue; self.timeout = timeout; self.completion = completion
        connection = NWConnection(host: NWEndpoint.Host(host.address), port: NWEndpoint.Port(rawValue: host.service.port)!, using: .tcp)
    }
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in self?.finish() }
        deadline = timer; timer.resume()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.finished else { return }
            switch state {
            case .ready:
                guard !self.ready else { return }; self.ready = true
                if self.host.service.transport == .rdp {
                    self.connection.send(content: ServiceHandshake.rdpRequest, completion: .contentProcessed { [weak self] error in
                        guard let self, !self.finished else { return }
                        if error != nil { self.finish() } else { self.receive() }
                    })
                } else { self.receive() }
            case .failed(let error), .waiting(let error):
                let denied = self.connection.currentPath?.unsatisfiedReason == .localNetworkDenied ||
                    error == .posix(.EACCES) || error == .posix(.EPERM)
                self.finish(denied: denied)
            case .cancelled: self.finish()
            default: break
            }
        }
        connection.start(queue: queue)
    }
    func cancel() { finish() }
    private func receive() {
        guard !finished, reply.count < ServiceHandshake.maximumReply else { finish(); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: ServiceHandshake.maximumReply - reply.count) { [weak self] data, _, ended, error in
            guard let self, !self.finished else { return }
            if let data { self.reply.append(data) }
            switch ServiceHandshake.inspect(self.reply, transport: self.host.service.transport) {
            case .matched: self.finish(matched: true)
            case .invalid: self.finish()
            case .incomplete:
                if ended || error != nil { self.finish() } else { self.receive() }
            }
        }
    }
    private func finish(matched: Bool = false, denied: Bool = false) {
        guard !finished else { return }
        finished = true
        deadline?.cancel(); deadline = nil
        connection.stateUpdateHandler = nil; connection.cancel()
        completion(matched, denied)
    }
}
