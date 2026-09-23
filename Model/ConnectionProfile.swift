import Foundation

/// Remote desktop, terminal and file-transfer transports.
enum RemoteTransport: String, Codable, CaseIterable, Identifiable {
    case vnc
    case rdp
    case remoteApp
    case ssh
    case sftp

    var id: String { rawValue }

    /// Localised in the UI via `displayNameKey`; this raw form is for logs/debug.
    var displayName: String {
        switch self {
        case .vnc: return "VNC / Screen Sharing"
        case .rdp: return "RDP"
        case .remoteApp: return "RemoteApp"
        case .ssh: return "SSH"
        case .sftp: return "SFTP"
        }
    }

    /// Key into Localizable.strings so pickers read correctly in sv/da/nb.
    var displayNameKey: String { "transport.\(rawValue)" }

    var defaultPort: UInt16 {
        switch self {
        case .vnc: return 5900
        case .rdp, .remoteApp: return 3389
        case .ssh, .sftp: return 22
        }
    }

    var uriScheme: String { rawValue }

    /// SSH is a terminal, not a framebuffer — the UI uses this to decide chrome.
    var isGraphical: Bool { self == .vnc || self == .rdp || self == .remoteApp }
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
    /// User-defined labels used for filtering and quick access.
    var tags: [String]?
    var lastConnected: Date?
    var ssh: SSHOptions?
    var rdp: RDPOptions?
    var links: HostLinks?
    var clipboardEnabled: Bool?
    var sharesClipboard: Bool { clipboardEnabled ?? true }

    // Optional on disk so profiles created before favorites decode unchanged.
    private var favorite: Bool?
    private var sshCommandLogging: Bool?
    /// Kept optional for backwards-compatible decoding of existing profiles.
    private var biometricLock: Bool?
    var logsSSHCommands: Bool {
        get { transport == .ssh && (sshCommandLogging ?? false) }
        set { sshCommandLogging = newValue ? true : nil }
    }
    var isFavorite: Bool {
        get { favorite ?? false }
        set { favorite = newValue }
    }

    /// Requires a local biometric check before this profile can read saved
    /// desktop credentials from the Keychain.
    var requiresBiometricUnlock: Bool {
        get { biometricLock ?? false }
        set { biometricLock = newValue ? true : nil }
    }

    var normalizedTags: [String] {
        Array(Set((tags ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
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
        username?.contains(where: { $0.isNewline || $0.asciiValue == 0 }) != true &&
        (transport != .remoteApp || rdp?.remoteAppProgram != nil) &&
        (ssh?.isValid ?? true) && (rdp?.isValid ?? true) && (links?.isValid ?? true) &&
        !(logsSSHCommands && !(ssh?.startCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
    }

    var fileProfile: ConnectionProfile {
        var result = self
        result.transport = .sftp
        if transport != .ssh && transport != .sftp {
            result.host = ssh?.host ?? host
            result.port = ssh?.port ?? 22
            result.username = ssh?.username ?? username
        }
        return result
    }

    func serviceURL(_ scheme: String) -> URL? {
        let configured = scheme == "smb" ? links?.smb : links?.web
        if let configured { return HostLinks.url(configured, scheme: scheme) }
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = ConnectionOptions.bracketed(host)
        return parts.url
    }
}
