import Foundation

/// Supported transports. VNC is implemented; RDP and SSH are scaffolded behind the
/// same `RemoteSession` seam (FreeRDP for RDP, SwiftTerm + an SSH lib for SSH).
enum RemoteTransport: String, Codable, CaseIterable, Identifiable {
    case vnc
    case rdp
    case ssh

    var id: String { rawValue }

    /// Localised in the UI via `displayNameKey`; this raw form is for logs/debug.
    var displayName: String {
        switch self {
        case .vnc: return "VNC / Screen Sharing"
        case .rdp: return "RDP"
        case .ssh: return "SSH"
        }
    }

    /// Key into Localizable.strings so pickers read correctly in sv/da/nb.
    var displayNameKey: String { "transport.\(rawValue)" }

    var defaultPort: UInt16 {
        switch self {
        case .vnc: return 5900
        case .rdp: return 3389
        case .ssh: return 22
        }
    }

    var uriScheme: String { rawValue }

    /// SSH is a terminal, not a framebuffer — the UI uses this to decide chrome.
    var isGraphical: Bool { self != .ssh }
}

/// A saved machine — the app's analogue of a Remmina `.remmina` profile file.
///
/// Deliberately does NOT contain the password: like Remmina (libsecret) and
/// Constellation, secrets live in the Keychain, keyed by `id`.
struct ConnectionProfile: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var transport: RemoteTransport
    var host: String
    var port: UInt16
    var username: String?

    /// Optional Remmina-style organisation.
    var group: String?

    init(id: UUID = UUID(),
         name: String,
         transport: RemoteTransport = .vnc,
         host: String,
         port: UInt16? = nil,
         username: String? = nil,
         group: String? = nil) {
        self.id = id
        self.name = name
        self.transport = transport
        self.host = host
        self.port = port ?? transport.defaultPort
        self.username = username
        self.group = group
    }

    /// A Remmina-style URI, e.g. `vnc://admin@studio.local:5900`.
    var uri: String {
        var s = "\(transport.uriScheme)://"
        if let u = username, !u.isEmpty { s += "\(u)@" }
        s += host
        if port != transport.defaultPort { s += ":\(port)" }
        return s
    }
}
