import SwiftUI
import SwiftTerm

/// Apple's OpenSSH supplies host-key verification, ssh-agent, ~/.ssh/config,
/// password and keyboard-interactive authentication. No shell interpolation.
final class SSHRemoteSession: NSObject, RemoteSession, LocalProcessTerminalViewDelegate {
    let profile: ConnectionProfile
    @Published private(set) var status: SessionStatus = .idle
    @Published private(set) var notice: String?
    private var terminal: LocalProcessTerminalView?
    private var loggingEnabled: Bool
    private var loggingReady = false
    private var loggingFailed = false
    private let logStore: SSHCommandLogStore
    private let logQueue = DispatchQueue(label: "se.fjarrconnect.ssh-command-log")

    init(profile: ConnectionProfile, password: String?, logStore: SSHCommandLogStore = .shared) {
        self.profile = profile
        self.logStore = logStore
        loggingEnabled = profile.logsSSHCommands
        super.init()
    }

    func start() {
        guard terminal == nil else { return }
        let view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.processDelegate = self
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        terminal = view
        var arguments = SSHArguments.make(profile)
        if profile.logsSSHCommands {
            notice = NSLocalizedString("ssh.log.waiting", comment: "")
            arguments.append(SSHCommandLogging.remoteCommand)
            view.getTerminal().registerOscHandler(code: SSHCommandLogging.oscCode) { [weak self] bytes in
                guard let event = SSHCommandLogging.event(bytes) else { return }
                self?.receiveLogEvent(event)
            }
        }
        view.startProcess(executable: "/usr/bin/ssh", args: arguments,
                          environment: SSHArguments.environment())
        guard view.process.running else {
            status = .disconnected(reason: NSLocalizedString("ssh.ended", comment: ""))
            return
        }
        // Process running is not proof of successful authentication.
        status = .running
    }

    func updateLoggingPreference(_ enabled: Bool) {
        loggingEnabled = enabled
        if !enabled { notice = nil }
        else if !profile.logsSSHCommands { notice = NSLocalizedString("ssh.log.reconnect", comment: "") }
        else if loggingFailed { notice = NSLocalizedString("ssh.log.failed", comment: "") }
        else { notice = NSLocalizedString(loggingReady ? "ssh.log.active" : "ssh.log.waiting", comment: "") }
    }

    func receiveLogEvent(_ event: SSHCommandLogging.Event) {
        guard profile.logsSSHCommands, loggingEnabled, !loggingFailed, !status.isFinished else { return }
        switch event {
        case .ready:
            loggingReady = true
            notice = NSLocalizedString("ssh.log.active", comment: "")
        case .unavailable:
            loggingReady = false
            notice = NSLocalizedString("ssh.log.unavailable", comment: "")
        case .command(let name):
            guard loggingReady else { return }
            let id = profile.id
            let date = Date()
            let store = logStore
            logQueue.async { [weak self] in
                do { try store.append(command: name, for: id, now: date) }
                catch {
                    DispatchQueue.main.async {
                        self?.loggingFailed = true
                        if self?.loggingEnabled == true { self?.notice = NSLocalizedString("ssh.log.failed", comment: "") }
                    }
                }
            }
        }
    }
    #if DEBUG
    var diagnosticText: String {
        guard let data = terminal?.getTerminal().getBufferAsData() else { return "No terminal" }
        return String(decoding: data, as: UTF8.self)
    }
    #endif

    func stop() {
        loggingEnabled = false
        logQueue.sync {} // Finish already accepted events before profile/log deletion.
        terminal?.processDelegate = nil
        terminal?.terminate()
        terminal = nil
        status = .disconnected(reason: nil)
    }
    func makeScreenView() -> AnyView {
        AnyView(Group {
            if let terminal { TerminalWrapper(view: terminal, shouldFocus: status == .running) }
        })
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.terminal === source, !self.status.isFinished else { return }
            // SwiftTerm 1.10.1 uses waitpid(WNOHANG) without checking its return
            // value, so zero is not reliable proof of a clean SSH exit. Keep
            // the terminal message available for every externally ended session.
            self.status = .disconnected(reason: NSLocalizedString("ssh.ended", comment: ""))
        }
    }
}

private struct TerminalWrapper: NSViewRepresentable {
    let view: LocalProcessTerminalView
    let shouldFocus: Bool
    final class Coordinator {
        var requestedInitialFocus = false
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        requestInitialFocus(for: view, coordinator: context.coordinator)
        return view
    }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        requestInitialFocus(for: nsView, coordinator: context.coordinator)
    }
    private func requestInitialFocus(for view: LocalProcessTerminalView, coordinator: Coordinator) {
        guard shouldFocus, !coordinator.requestedInitialFocus else { return }
        func focus(_ attempt: Int) {
            guard !coordinator.requestedInitialFocus else { return }
            guard let window = view.window else {
                if attempt < 5 { DispatchQueue.main.async { focus(attempt + 1) } }
                return
            }
            coordinator.requestedInitialFocus = window.makeFirstResponder(view)
        }
        DispatchQueue.main.async { focus(0) }
    }
}
