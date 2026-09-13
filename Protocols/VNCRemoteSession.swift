import SwiftUI
import RoyalVNCKit

/// VNC/RFB backend built on RoyalVNCKit (MIT). RoyalVNCKit implements the standard
/// VNC auth *and* Apple Remote Desktop auth, so this connects to any Mac with
/// System Settings ▸ General ▸ Sharing ▸ Screen Sharing enabled.
///
/// RoyalVNCKit's `VNCCAFramebufferView` both renders the framebuffer and forwards
/// local mouse/keyboard events to the server, so we don't inject input by hand.
final class VNCRemoteSession: NSObject, RemoteSession, VNCConnectionDelegate {
    let profile: ConnectionProfile
    private let password: String?

    @Published private(set) var status: SessionStatus = .idle

    private var connection: VNCConnection?
    private let logger = VNCPrintLogger()

    /// Built once, when the server hands us a framebuffer. Cached so SwiftUI
    /// re-renders don't recreate the AppKit view.
    private var framebufferView: VNCCAFramebufferView?

    init(profile: ConnectionProfile, password: String?) {
        self.profile = profile
        self.password = password
        super.init()
    }

    // MARK: RemoteSession

    func start() {
        guard connection == nil else { return }
        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false,
            hostname: profile.host,
            port: profile.port,
            isShared: true,
            isScalingEnabled: true,
            useDisplayLink: true,
            inputMode: .forwardKeyboardShortcutsIfNotInUseLocally,
            isClipboardRedirectionEnabled: true,
            colorDepth: .depth24Bit,
            frameEncodings: .default
        )

        let connection = VNCConnection(settings: settings, logger: logger)
        connection.delegate = self
        self.connection = connection

        setStatus(.connecting)
        connection.connect()
    }

    func stop() {
        let old = connection
        connection = nil
        old?.delegate = nil
        old?.disconnect()
        framebufferView = nil
        status = .disconnected(reason: nil)
    }

    func makeScreenView() -> AnyView {
        if let view = framebufferView {
            return AnyView(FramebufferViewWrapper(nsView: view))
        } else {
            return AnyView(
                VStack(spacing: 12) {
                    ProgressView()
                    Text(status.label).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        }
    }

    // MARK: VNCConnectionDelegate

    func connection(_ connection: VNCConnection,
                    stateDidChange connectionState: VNCConnection.ConnectionState) {
        guard self.connection === connection else { return }
        switch connectionState.status {
        case .connecting:    setStatus(.connecting)
        case .connected:     setStatus(.connected)
        case .disconnecting: setStatus(.disconnecting)
        case .disconnected:  setStatus(.disconnected(reason: connectionState.error?.localizedDescription))
        }
    }

    func connection(_ connection: VNCConnection,
                    credentialFor authenticationType: VNCAuthenticationType,
                    completion: @escaping ((any VNCCredential)?) -> Void) {
        // Mac Screen Sharing uses Apple Remote Desktop auth (username + password);
        // classic VNC servers want a password only.
        if authenticationType.requiresUsername, authenticationType.requiresPassword {
            completion(VNCUsernamePasswordCredential(username: profile.username ?? "",
                                                     password: password ?? ""))
        } else if authenticationType.requiresPassword {
            completion(VNCPasswordCredential(password: password ?? ""))
        } else {
            completion(nil)
        }
    }

    func connection(_ connection: VNCConnection,
                    didCreateFramebuffer framebuffer: VNCFramebuffer) {
        // RoyalVNCKit 1.0.0 renders via its display link; this session stays the delegate.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connection === connection else { return }
            let size = CGSize(width: CGFloat(framebuffer.size.width),
                              height: CGFloat(framebuffer.size.height))
            self.framebufferView = VNCCAFramebufferView(
                frame: CGRect(origin: .zero, size: size),
                framebuffer: framebuffer,
                connection: connection
            )
            self.objectWillChange.send()   // let the UI swap the placeholder for the screen
        }
    }

    func connection(_ connection: VNCConnection,
                    didResizeFramebuffer framebuffer: VNCFramebuffer) {
        self.connection(connection, didCreateFramebuffer: framebuffer)
    }

    func connection(_ connection: VNCConnection,
                    didUpdateFramebuffer framebuffer: VNCFramebuffer,
                    x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connection === connection else { return }
            self.framebufferView?.connection(connection, didUpdateFramebuffer: framebuffer,
                                            x: x, y: y, width: width, height: height)
        }
    }

    func connection(_ connection: VNCConnection,
                    didUpdateCursor cursor: VNCCursor) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connection === connection else { return }
            self.framebufferView?.connection(connection, didUpdateCursor: cursor)
        }
    }

    // MARK: Helpers

    private func setStatus(_ new: SessionStatus) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connection != nil else { return }
            self.status = new
        }
    }
}

/// Bridges the cached AppKit framebuffer view into SwiftUI.
private struct FramebufferViewWrapper: NSViewRepresentable {
    let nsView: VNCCAFramebufferView
    func makeNSView(context: Context) -> VNCCAFramebufferView { nsView }
    func updateNSView(_ nsView: VNCCAFramebufferView, context: Context) { }
}
