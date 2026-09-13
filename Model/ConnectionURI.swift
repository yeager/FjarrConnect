import Foundation

/// Parses Remmina-style quick-connect URIs such as:
///   vnc://studio.local
///   vnc://admin@studio.local:5901
///   rdp://user@10.0.0.5
enum ConnectionURI {
    static func profile(from string: String) -> ConnectionProfile? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

        // Allow a bare "host" or "host:port" with no scheme → default to VNC.
        let normalized = trimmed.contains("://") ? trimmed : "vnc://\(trimmed)"

        guard let comps = URLComponents(string: normalized),
              let scheme = comps.scheme?.lowercased(),
              let transport = RemoteTransport(rawValue: scheme),
              let host = comps.host, !host.isEmpty
        else { return nil }

        let port = comps.port.map { UInt16($0) } ?? transport.defaultPort
        let username = comps.user.flatMap { $0.isEmpty ? nil : $0 }

        return ConnectionProfile(
            name: host,
            transport: transport,
            host: host,
            port: port,
            username: username
        )
    }
}
