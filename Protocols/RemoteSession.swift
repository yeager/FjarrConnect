import SwiftUI
import Combine

/// The lifecycle status of a remote session, protocol-agnostic.
enum SessionStatus: Equatable {
    case idle
    case connecting
    case connected
    case disconnecting
    case disconnected(reason: String?)

    var label: String {
        switch self {
        case .idle:                     return "Idle"
        case .connecting:               return "Connecting…"
        case .connected:                return "Connected"
        case .disconnecting:            return "Disconnecting…"
        case .disconnected(let reason): return reason.map { "Disconnected: \($0)" } ?? "Disconnected"
        }
    }
}

/// The "plugin" seam, inspired by Remmina's protocol-plugin architecture.
///
/// Every transport (VNC today; RDP/SPICE/SSH later) implements this. The rest of
/// the app talks only to `RemoteSession` and never to a concrete library, so adding
/// FreeRDP means adding one file — not touching the UI.
protocol RemoteSession: ObservableObject, AnyObject {
    var profile: ConnectionProfile { get }
    var status: SessionStatus { get }

    /// Begin connecting. Idempotent-ish; call once per session instance.
    func start()

    /// Tear down the connection and release resources.
    func stop()

    /// The live remote screen as a SwiftUI view (or a placeholder until it exists).
    func makeScreenView() -> AnyView
}

/// Maps a profile's protocol to a concrete backend — the equivalent of Remmina's
/// plugin registry. This is the ONLY place that knows which libraries exist.
enum ProtocolRegistry {
    static func makeSession(for profile: ConnectionProfile, password: String?) -> (any RemoteSession)? {
        switch profile.transport {
        case .vnc:
            return VNCRemoteSession(profile: profile, password: password)
        case .rdp:
            return RDPRemoteSession(profile: profile, password: password)
        case .ssh:
            return SSHRemoteSession(profile: profile, password: password)
        }
    }

    /// All three transports are represented in the UI; RDP and SSH are stubs until
    /// their native libraries are wired in (see the respective session files).
    static var available: [RemoteTransport] { RemoteTransport.allCases }
}
