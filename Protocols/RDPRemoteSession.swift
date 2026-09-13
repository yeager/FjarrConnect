import SwiftUI

/// RDP backend for connecting to Windows machines.
///
/// FreeRDP 3 ("freerdp3") is Apache-2.0, so it can be compiled into an
/// `xcframework` and bundled without copyleft obligations — the same approach the
/// open-source Constellation client uses for its RDP tab.
///   • FreeRDP: https://github.com/FreeRDP/FreeRDP  (Apache-2.0)
///
/// Wiring sketch (once a FreeRDP.xcframework is added):
///   1. Create a FreeRDP context; set hostname/port/username; pull the password
///      from the Keychain (never store it in the profile).
///   2. Provide a graphics callback that copies each updated region into a
///      CGImage/IOSurface-backed layer.
///   3. Forward NSEvents (mouse/keyboard) into FreeRDP input functions.
///   4. Map `status` from FreeRDP's connect/disconnect callbacks.
final class RDPRemoteSession: NSObject, RemoteSession {
    let profile: ConnectionProfile
    private let password: String?

    @Published private(set) var status: SessionStatus = .idle

    init(profile: ConnectionProfile, password: String?) {
        self.profile = profile
        self.password = password
        super.init()
    }

    func start() {
        // TODO: replace with a real FreeRDP session driving a Metal/CALayer surface.
        status = .disconnected(reason: NSLocalizedString("backend.rdp.pending", comment: ""))
    }

    func stop() {
        status = .disconnected(reason: nil)
    }

    func makeScreenView() -> AnyView {
        AnyView(
            BackendPlaceholderView(
                transport: .rdp,
                host: "\(profile.host):\(profile.port)"
            )
        )
    }
}
