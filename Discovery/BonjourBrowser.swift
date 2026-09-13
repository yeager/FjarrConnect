import Foundation
import Network
import Combine

/// A Mac advertising Screen Sharing on the LAN.
struct DiscoveredHost: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let endpoint: NWEndpoint
}

/// Discovers Macs running Screen Sharing the way Apple Remote Desktop does:
/// they advertise the VNC/RFB service over Bonjour as `_rfb._tcp`.
///
/// Note: on macOS 15+, browsing the local network prompts the user for the
/// Local Network privacy permission the first time.
final class BonjourBrowser: ObservableObject {
    @Published private(set) var hosts: [DiscoveredHost] = []

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }

        let params = NWParameters()
        params.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjour(type: "_rfb._tcp", domain: nil),
            using: params
        )

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> DiscoveredHost? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredHost(name: name, endpoint: result.endpoint)
            }
            DispatchQueue.main.async {
                self?.hosts = found.sorted { $0.name < $1.name }
            }
        }

        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        hosts = []
    }

    /// RoyalVNCKit connects by hostname:port, not by an NWEndpoint.service, so we
    /// resolve the Bonjour service to a concrete host/port before handing it off.
    func resolve(_ host: DiscoveredHost,
                 completion: @escaping (_ host: String, _ port: UInt16) -> Void) {
        let connection = NWConnection(to: host.endpoint, using: .tcp)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if case let .hostPort(host: h, port: p)? = connection.currentPath?.remoteEndpoint {
                    completion("\(h)".components(separatedBy: "%").first ?? "\(h)",
                               p.rawValue)
                }
                connection.cancel()
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }

        connection.start(queue: .global())
    }
}
