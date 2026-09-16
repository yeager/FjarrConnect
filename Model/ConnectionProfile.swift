import Foundation

/// The three supported remote transports.
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

    // Optional on disk so profiles created before favorites decode unchanged.
    private var favorite: Bool?
    private var sshCommandLogging: Bool?
    var logsSSHCommands: Bool {
        get { transport == .ssh && (sshCommandLogging ?? false) }
        set { sshCommandLogging = newValue ? true : nil }
    }
    var isFavorite: Bool {
        get { favorite ?? false }
        set { favorite = newValue }
    }

    init(id: UUID = UUID(),
         name: String,
         transport: RemoteTransport = .vnc,
         host: String,
         port: UInt16? = nil,
         username: String? = nil,
         group: String? = nil,
         isFavorite: Bool = false,
         logsSSHCommands: Bool = false) {
        self.id = id
        self.name = name
        self.transport = transport
        self.host = host
        self.port = port ?? transport.defaultPort
        self.username = username
        self.group = group
        self.favorite = isFavorite ? true : nil
        self.sshCommandLogging = logsSSHCommands ? true : nil
    }

    /// A Remmina-style URI, e.g. `vnc://admin@studio.local:5900`.
    var uri: String {
        var components = URLComponents()
        components.scheme = transport.uriScheme
        components.host = host.contains(":") ? "[\(host)]" : host
        components.user = username.flatMap { $0.isEmpty ? nil : $0 }
        if port != transport.defaultPort { components.port = Int(port) }
        return components.string ?? "\(transport.uriScheme)://\(host)"
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        ConnectionURI.validHost(host) && port > 0 &&
        username?.contains(where: { $0.isNewline || $0.asciiValue == 0 }) != true
    }
}
