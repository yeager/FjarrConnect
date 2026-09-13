import Foundation
import Network
import Combine

struct DiscoveredHost: Identifiable, Hashable {
    var id: NWEndpoint { endpoint }
    let name: String
    let endpoint: NWEndpoint
}

final class BonjourBrowser: ObservableObject {
    @Published private(set) var hosts: [DiscoveredHost] = []
    @Published private(set) var errorMessage: String?
    private var browser: NWBrowser?
    private var resolutions: [UUID: NWConnection] = [:]

    func start() {
        guard browser == nil else { return }
        errorMessage = nil
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_rfb._tcp", domain: nil), using: params)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser, self.browser === browser else { return }
            self.hosts = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredHost(name: name, endpoint: result.endpoint)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser, self.browser === browser else { return }
            switch state {
            case .failed(let error), .waiting(let error): self.errorMessage = error.localizedDescription
            case .ready: self.errorMessage = nil
            default: break
            }
        }
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        for connection in resolutions.values { connection.cancel() }
        resolutions.removeAll()
        hosts = []
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
            case .failed(let error): finish(.failure(error))
            case .cancelled: finish(.failure(ResolveError.unavailable))
            default: break
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish(.failure(ResolveError.timeout)) }
    }
}
