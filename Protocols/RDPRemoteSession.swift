import SwiftUI

/// Owns one embedded desktop, including its native connection worker. Changing
/// tabs detaches the view without stopping the connection.
final class RDPRemoteSession: NSObject, RemoteSession {
    let profile: ConnectionProfile
    private var credentials: SessionCredentials
    @Published private(set) var status: SessionStatus = .idle
    private var screen: NSView?
    private var timer: Timer?
    private var active = false
    private let runtime: RDPRuntime?

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
    }
    private func updateStatus() {
        guard let pointer, let runtime else { return }
        switch runtime.status(pointer) {
        case 2: if status != .connected { status = .connected }
        case 3:
            timer?.invalidate(); timer = nil
            let code = runtime.error(pointer)
            if code == 0 { status = .disconnected(reason: nil); return }
            let key: String
            switch runtime.failure(pointer) {
            case 1: key = "rdp.error.network"
            case 2: key = "rdp.error.certificate"
            case 3: key = "rdp.error.authentication"
            case 4: key = "rdp.error.account"
            case 5: key = "rdp.error.activationTimeout"
            default: key = "rdp.ended"
            }
            status = .disconnected(reason: "RDP \(profile.host):\(profile.port)\n" +
                NSLocalizedString(key, comment: "") + "\n" + NSLocalizedString("rdp.exitCode", comment: "") + " " + String(format: "0x%08X", code))
        default: break
        }
    }
    func setActive(_ active: Bool) {
        self.active = active
        if let pointer { runtime?.activate(pointer, active ? 1 : 0) }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        if let pointer { runtime?.stop(pointer) }
        credentials = SessionCredentials()
        status = .disconnected(reason: nil)
    }
    deinit { timer?.invalidate(); if let pointer { runtime?.stop(pointer) } }
    func makeScreenView() -> AnyView {
        guard let screen else { return AnyView(ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)) }
        return AnyView(RDPDesktopView(screen: screen))
    }
}

private struct RDPDesktopView: NSViewRepresentable {
    let screen: NSView
    func makeNSView(context: Context) -> NSView { screen }
    func updateNSView(_ view: NSView, context: Context) {}
}
