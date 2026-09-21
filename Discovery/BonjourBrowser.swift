import Foundation
import Network
import Combine

struct DiscoveredHost: Identifiable, Hashable {
    var id: NWEndpoint { endpoint }
    let name: String
    let endpoint: NWEndpoint
    let transport: RemoteTransport
}

final class BonjourBrowser: ObservableObject {
    @Published private(set) var hosts: [DiscoveredHost] = []
    @Published private(set) var errorMessage: String?
    private var browsers: [NWBrowser] = []
    private var resultsByType: [RemoteTransport: [DiscoveredHost]] = [:]
    private var errorsByType: [RemoteTransport: String] = [:]
    private var resolutions: [UUID: NWConnection] = [:]

    func start() {
        guard browsers.isEmpty else { return }
        errorMessage = nil
        for (type, transport) in [("_rfb._tcp", RemoteTransport.vnc), ("_rdp._tcp", .rdp), ("_ssh._tcp", .ssh)] {
            let params = NWParameters()
            params.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: params)
            browsers.append(browser)
            browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
                guard let self, let browser, self.browsers.contains(where: { $0 === browser }) else { return }
                self.resultsByType[transport] = results.compactMap { result in
                    guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                    return DiscoveredHost(name: name, endpoint: result.endpoint, transport: transport)
                }
                self.hosts = self.resultsByType.values.flatMap { $0 }.sorted {
                    $0.name == $1.name ? $0.transport.rawValue < $1.transport.rawValue : $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }
            browser.stateUpdateHandler = { [weak self, weak browser] state in
                guard let self, let browser, self.browsers.contains(where: { $0 === browser }) else { return }
                switch state {
                case .failed(let error), .waiting(let error): self.errorsByType[transport] = error.localizedDescription
                case .ready: self.errorsByType[transport] = nil
                default: break
                }
                self.errorMessage = self.errorsByType.values.sorted().first
            }
            browser.start(queue: .main)
        }
    }

    func stop() {
        let previous = browsers; browsers.removeAll()
        for browser in previous { browser.cancel() }
        for connection in resolutions.values { connection.cancel() }
        resolutions.removeAll()
        resultsByType.removeAll(); errorsByType.removeAll()
        hosts = []; errorMessage = nil
    }

    struct Endpoint { let host: String; let port: UInt16 }
    enum ResolveError: LocalizedError {
        case timeout, unavailable
        var errorDescription: String? { NSLocalizedString("discovery.resolveFailed", comment: "") }
    }

    /// Every attempt has one completion, a deadline, and an owned connection.
    func resolve(_ host: DiscoveredHost, completion: @escaping (Result<Endpoint, Error>) -> Void) {
        let id = UUID()
        let connection = NWConnection(to: host.endpoint, using: .tcp)
        resolutions[id] = connection
        var finished = false
        func finish(_ result: Result<Endpoint, Error>) {
            guard !finished else { return }
            finished = true
            connection.stateUpdateHandler = nil
            connection.cancel()
            self.resolutions.removeValue(forKey: id)
            completion(result)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if case let .hostPort(h, p)? = connection.currentPath?.remoteEndpoint {
                    // Keep IPv6 scope identifiers; link-local addresses need them.
                    finish(.success(Endpoint(host: "\(h)", port: p.rawValue)))
                } else { finish(.failure(ResolveError.unavailable)) }
            case .failed: finish(.failure(ResolveError.unavailable))
            case .cancelled: finish(.failure(ResolveError.unavailable))
            default: break
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish(.failure(ResolveError.timeout)) }
    }
}
