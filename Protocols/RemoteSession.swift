import SwiftUI
import Combine

enum SessionStatus: Equatable {
    case idle, connecting, connected, running, disconnecting
    case disconnected(reason: String?)

    var label: String {
        switch self {
        case .idle: return NSLocalizedString("status.idle", comment: "")
        case .connecting: return NSLocalizedString("status.connecting", comment: "")
        case .connected: return NSLocalizedString("status.connected", comment: "")
        case .running: return NSLocalizedString("status.running", comment: "")
        case .disconnecting: return NSLocalizedString("status.disconnecting", comment: "")
        case .disconnected: return NSLocalizedString("status.disconnected", comment: "")
        }
    }
    var isFinished: Bool { if case .disconnected = self { return true }; return false }
    var isActive: Bool {
        switch self {
        case .connecting, .connected, .running, .disconnecting: return true
        case .idle, .disconnected: return false
        }
    }
    var error: String? { if case .disconnected(let reason) = self { return reason }; return nil }
}

protocol RemoteSession: ObservableObject, AnyObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    var profile: ConnectionProfile { get }
    var status: SessionStatus { get }
    var notice: String? { get }
    func start()
    func stop()
    func setActive(_ active: Bool)
    func makeScreenView() -> AnyView
}

extension RemoteSession {
    var notice: String? { nil }
    func setActive(_ active: Bool) {}
}

enum ProtocolRegistry {
    static func makeSession(for profile: ConnectionProfile, credentials: SessionCredentials) -> any RemoteSession {
        switch profile.transport {
        case .vnc: return VNCRemoteSession(profile: profile, password: credentials.password)
        case .rdp: return RDPRemoteSession(profile: profile, password: credentials.password, gatewayPassword: credentials.gatewayPassword)
        case .sftp: return SFTPRemoteSession(profile: profile)
        case .ssh: return SSHRemoteSession(profile: profile, password: credentials.password)
        }
    }
    static var available: [RemoteTransport] { RemoteTransport.allCases }
}
