import SwiftUI

/// Owns one embedded desktop, including its native connection worker. Changing
/// tabs detaches the view without stopping the connection.
final class RDPRemoteSession: NSObject, RemoteSession, SessionRecordingSource, SessionHealthProviding {
    private static let connectionTimeout: TimeInterval = 15
    /// Safe presence bits from FreeRDP settings; credential contents never leave the native runtime.
    var inputState: UInt32? {
        guard let pointer else { return nil }
        return runtime?.inputState(pointer)
    }

    static func failureLocalizationKey(for category: Int32) -> String {
        switch category {
        case 1: return "rdp.error.network"
        case 2: return "rdp.error.certificate"
        case 3: return "rdp.error.authentication"
        case 4: return "rdp.error.account"
        case 5: return "rdp.error.activationTimeout"
        case 6: return "rdp.error.nla"
        case 7: return "rdp.error.license"
        case 8: return "rdp.error.serverEndedSession"
        case 9: return "rdp.error.securityNegotiation"
        default: return "rdp.ended"
        }
    }

    let profile: ConnectionProfile
    private var credentials: SessionCredentials
    @Published private(set) var status: SessionStatus = .idle
    @Published private(set) var hasReceivedFrame = false
    private var screen: NSView?
    private var timer: Timer?
    private var connectionDeadlineTimer: Timer?
    private var active = false
    private let runtime: RDPRuntime?

    var recordingView: NSView? { screen }
    var negotiatedCodec: String? {
        guard let pointer, let value = runtime?.codec(pointer) else { return nil }
        let codec = String(cString: value)
        return codec.isEmpty ? nil : codec
    }
    var connectionPhase: String? {
        guard let pointer, let value = runtime?.phase(pointer) else { return nil }
        return String(cString: value)
    }
    var requestedSecurityProtocols: UInt32? {
        guard let pointer, securityProtocolWasSelected else { return nil }
        return runtime?.requestedProtocols(pointer)
    }
    var selectedSecurityProtocol: UInt32? {
        guard let pointer, securityProtocolWasSelected else { return nil }
        return runtime?.selectedProtocol(pointer)
    }

    /// FreeRDP publishes the protocol fields after the server's negotiation
    /// response, before CredSSP/NLA finishes. Zero is ambiguous until a later
    /// phase because it also represents the initial value and legacy RDP.
    private var securityProtocolWasSelected: Bool {
        guard let pointer, let connectionPhase else { return false }
        let requested = runtime?.requestedProtocols(pointer) ?? 0
        let selected = runtime?.selectedProtocol(pointer) ?? 0
        if requested != 0 || selected != 0 {
            return true
        }
        return connectionPhase != "CONNECTION_STATE_INITIAL" && connectionPhase != "CONNECTION_STATE_NEGO"
    }

    static var isAvailable: Bool { RDPRuntime.shared != nil }
    init(profile: ConnectionProfile, password: String?, gatewayPassword: String? = nil, runtime: RDPRuntime? = .shared) {
        self.profile = profile
        self.credentials = SessionCredentials(password: password, gatewayPassword: gatewayPassword)
        self.runtime = runtime
        super.init()
    }
    private var pointer: UnsafeMutableRawPointer? { screen.map { Unmanaged.passUnretained($0).toOpaque() } }
    func start() {
        guard screen == nil else { return }
        defer { credentials = SessionCredentials() }
        guard let runtime else {
            status = .disconnected(reason: NSLocalizedString("rdp.install", comment: "")); return
        }
        guard let input = RDPArguments.input(profile: profile, password: credentials.password, gatewayPassword: credentials.gatewayPassword) else {
            status = .disconnected(reason: NSLocalizedString("rdp.invalid", comment: "")); return
        }
        let arguments = String(decoding: input, as: UTF8.self)
        let view = arguments.withCString { arguments in
            RDPRuntime.translations.withCString { runtime.create(arguments, $0) }
        }
        guard let view else {
            status = .disconnected(reason: NSLocalizedString("rdp.install", comment: "")); return
        }
        screen = Unmanaged<NSView>.fromOpaque(view).takeRetainedValue()
        status = .connecting
        runtime.activate(view, active ? 1 : 0)
        runtime.start(view)
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.updateStatus() }
        connectionDeadlineTimer = Timer.scheduledTimer(withTimeInterval: Self.connectionTimeout, repeats: false) { [weak self] _ in
            guard let self, self.status == .connecting, let pointer = self.pointer else { return }
            self.connectionDeadlineTimer = nil
            self.timer?.invalidate(); self.timer = nil
            self.runtime?.stop(pointer)
            self.status = .disconnected(reason: "RDP \(self.profile.host):\(self.profile.port)\n" +
                NSLocalizedString("rdp.error.connectTimeout", comment: ""))
        }
    }
    private func updateStatus() {
        guard let pointer, let runtime else { return }
        let receivedFrame = runtime.hasFrame(pointer) != 0
        if hasReceivedFrame != receivedFrame { hasReceivedFrame = receivedFrame }
        switch runtime.status(pointer) {
        case 2:
            connectionDeadlineTimer?.invalidate(); connectionDeadlineTimer = nil
            if status != .connected { status = .connected }
        case 3:
            connectionDeadlineTimer?.invalidate(); connectionDeadlineTimer = nil
            timer?.invalidate(); timer = nil
            let code = runtime.error(pointer)
            if code == 0 { status = .disconnected(reason: nil); return }
            let key = Self.failureLocalizationKey(for: runtime.failure(pointer))
            let phase = connectionPhase.map { "\n\(NSLocalizedString("rdp.phase", comment: "")) \($0)" } ?? ""
            status = .disconnected(reason: "RDP \(profile.host):\(profile.port)\n" +
                NSLocalizedString(key, comment: "") + phase + "\n" + NSLocalizedString("rdp.exitCode", comment: "") + " " + String(format: "0x%08X", code))
        default: break
        }
    }
    func setActive(_ active: Bool) {
        self.active = active
        if let pointer { runtime?.activate(pointer, active ? 1 : 0) }
    }
    func sendSecureAttentionSequence() {
        guard status == .connected, let pointer else { return }
        runtime?.secureAttention(pointer)
    }
    func stop() {
        connectionDeadlineTimer?.invalidate(); connectionDeadlineTimer = nil
        timer?.invalidate(); timer = nil
        if let pointer { runtime?.stop(pointer) }
        credentials = SessionCredentials()
        status = .disconnected(reason: nil)
    }
    deinit { connectionDeadlineTimer?.invalidate(); timer?.invalidate(); if let pointer { runtime?.stop(pointer) } }
    func makeScreenView() -> AnyView {
        guard let screen else { return AnyView(ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)) }
        return AnyView(ZStack {
            RDPDesktopView(screen: screen, shouldFocus: status == .connected)
            if !hasReceivedFrame {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("rdp.waitingForDesktop")
                }
                .foregroundStyle(.white)
                .padding(20)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
                .allowsHitTesting(false)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity))
    }
}

private struct RDPDesktopView: NSViewRepresentable {
    let screen: NSView
    let shouldFocus: Bool

    final class Coordinator {
        var requestedInitialFocus = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> RDPDesktopContainer {
        let container = RDPDesktopContainer()
        container.show(screen)
        requestInitialFocus(for: container, coordinator: context.coordinator)
        return container
    }
    func updateNSView(_ view: RDPDesktopContainer, context: Context) {
        view.show(screen)
        requestInitialFocus(for: view, coordinator: context.coordinator)
    }
    private func requestInitialFocus(for container: RDPDesktopContainer, coordinator: Coordinator) {
        guard shouldFocus, !coordinator.requestedInitialFocus else { return }
        func focus(_ attempt: Int) {
            guard !coordinator.requestedInitialFocus else { return }
            guard let window = container.window, let screen = container.screenView else {
                if attempt < 5 { DispatchQueue.main.async { focus(attempt + 1) } }
                return
            }
            coordinator.requestedInitialFocus = window.makeFirstResponder(screen)
        }
        DispatchQueue.main.async { focus(0) }
    }
}

/// Keep the FreeRDP NSView as a child of a host owned by SwiftUI. This mirrors
/// the VNC framebuffer bridge and lets a reconnect replace the native surface
/// without replacing a view that participates in SwiftUI's own layout tree.
private final class RDPDesktopContainer: NSView {
    private(set) var screenView: NSView?

    func show(_ view: NSView) {
        guard screenView !== view else { return }
        let restoreFocus = screenView != nil && window?.firstResponder === screenView
        screenView?.removeFromSuperview()
        screenView = view
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        layoutSubtreeIfNeeded()
        if restoreFocus { window?.makeFirstResponder(view) }
    }

    override func layout() {
        super.layout()
        screenView?.frame = bounds
    }
}
