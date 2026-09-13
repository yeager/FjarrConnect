import SwiftUI

/// SSH backend. Unlike VNC/RDP this is a *terminal*, not a framebuffer, so its
/// `makeScreenView()` returns a terminal emulator rather than a bitmap surface.
///
/// Recommended open-source pieces (all permissive, App-Store-safe):
///   • Terminal UI: SwiftTerm (BSD/MIT) — https://github.com/migueldeicaza/SwiftTerm
///   • SSH transport: Citadel (MIT, SwiftNIO SSH) — https://github.com/orlandos-nl/Citadel
///     or NIOSSH directly (Apache-2.0).
///
/// Wiring sketch (once those packages are added):
///   1. Open an SSHClient to profile.host:profile.port with username/password
///      (or a key from the Keychain).
///   2. Request a PTY + shell channel.
///   3. Pipe channel stdout → SwiftTerm's `feed(byteArray:)`, and
///      SwiftTerm's `send` callback → channel stdin.
///   4. Map `status` from the channel/connection lifecycle.
final class SSHRemoteSession: NSObject, RemoteSession {
    let profile: ConnectionProfile
    private let password: String?

    @Published private(set) var status: SessionStatus = .idle

    init(profile: ConnectionProfile, password: String?) {
        self.profile = profile
        self.password = password
        super.init()
    }

    func start() {
        // TODO: replace with a real Citadel/NIOSSH connection + SwiftTerm PTY.
        status = .disconnected(reason: NSLocalizedString("backend.ssh.pending", comment: ""))
    }

    func stop() {
        status = .disconnected(reason: nil)
    }

    func makeScreenView() -> AnyView {
        AnyView(
            BackendPlaceholderView(
                transport: .ssh,
                host: "\(profile.username.map { "\($0)@" } ?? "")\(profile.host):\(profile.port)"
            )
        )
    }
}
