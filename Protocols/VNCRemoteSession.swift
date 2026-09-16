import SwiftUI
import RoyalVNCKit

/// VNC/RFB backend built on RoyalVNCKit (MIT). RoyalVNCKit implements the standard
/// VNC auth and Apple Remote Desktop auth. The remote Mac must grant the account
/// screen access and authorize its sharing agent to capture the screen.
///
/// RoyalVNCKit's `VNCCAFramebufferView` both renders the framebuffer and forwards
/// local mouse/keyboard events to the server, so we don't inject input by hand.
final class VNCRemoteSession: NSObject, RemoteSession, VNCConnectionDelegate {
    let profile: ConnectionProfile
    private var password: String?
    private var connectionDeadline: DispatchWorkItem?
    private var credentialFailure: String?
    private var frameCheck: DispatchWorkItem?

    @Published private(set) var status: SessionStatus = .idle
    @Published private(set) var notice: String?

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
        credentialFailure = nil
        notice = nil
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
        let deadline = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection, self.connection === connection,
                  self.status == .connecting else { return }
            self.stop()
            self.status = .disconnected(reason: NSLocalizedString("session.timeout", comment: ""))
        }
        connectionDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: deadline)
    }

    func stop() {
        frameCheck?.cancel()
        frameCheck = nil
        notice = nil
        connectionDeadline?.cancel()
        connectionDeadline = nil
        password = nil
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
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connection === connection else { return }
            switch connectionState.status {
            case .connecting: self.status = .connecting
            case .connected:
                self.connectionDeadline?.cancel()
                self.password = nil
                self.status = .connected
                self.checkInitialImage(connection, after: 8)
            case .disconnecting: self.status = .disconnecting
            case .disconnected:
                self.frameCheck?.cancel()
                self.notice = nil
                self.connectionDeadline?.cancel()
                self.password = nil
                self.status = .disconnected(reason: self.credentialFailure ?? connectionState.error.map { error in
                    let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    return "VNC \(self.profile.host):\(self.profile.port)\n\(detail)"
                })
            }
        }
    }

    func connection(_ connection: VNCConnection,
                    credentialFor authenticationType: VNCAuthenticationType,
                    completion: @escaping ((any VNCCredential)?) -> Void) {
        // Credential checks run on the main queue with the session state.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connection === connection else { completion(nil); return }
            if authenticationType.requiresUsername,
               self.profile.username?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                self.credentialFailure = NSLocalizedString("vnc.usernameRequired", comment: "")
                completion(nil)
                return
            }
            self.provideCredential(for: authenticationType, completion: completion)
        }
    }

    private func provideCredential(for authenticationType: VNCAuthenticationType,
                                   completion: @escaping ((any VNCCredential)?) -> Void) {
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

    private func checkInitialImage(_ connection: VNCConnection, after delay: TimeInterval) {
        frameCheck?.cancel()
        let check = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection, self.connection === connection,
                  self.status == .connected else { return }
            if let image = connection.framebuffer?.cgImage {
                guard VNCFrameDiagnostics.isBlack(image) else { self.notice = nil; return }
                self.notice = NSLocalizedString("vnc.blackScreen", comment: "")
            } else {
                self.notice = NSLocalizedString("vnc.waitingForImage", comment: "")
            }
            // Clear the hint automatically if the server starts sending content.
            self.checkInitialImage(connection, after: 3)
        }
        frameCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: check)
    }

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
