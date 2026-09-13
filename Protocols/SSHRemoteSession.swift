import SwiftUI
import SwiftTerm

/// Apple's OpenSSH supplies host-key verification, ssh-agent, ~/.ssh/config,
/// password and keyboard-interactive authentication. No shell interpolation.
final class SSHRemoteSession: NSObject, RemoteSession, LocalProcessTerminalViewDelegate {
    let profile: ConnectionProfile
    @Published private(set) var status: SessionStatus = .idle
    private var terminal: LocalProcessTerminalView?

    init(profile: ConnectionProfile, password: String?) {
        self.profile = profile
        super.init()
    }

    func start() {
        guard terminal == nil else { return }
        let view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.processDelegate = self
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        terminal = view
        view.startProcess(executable: "/usr/bin/ssh", args: SSHArguments.make(profile))
        guard view.process.running else {
            status = .disconnected(reason: NSLocalizedString("ssh.ended", comment: ""))
            return
        }
        // Process running is not proof of successful authentication.
        status = .running
    }
    func stop() {
        terminal?.processDelegate = nil
        terminal?.terminate()
        terminal = nil
        status = .disconnected(reason: nil)
    }
    func makeScreenView() -> AnyView {
        AnyView(Group {
            if let terminal { TerminalWrapper(view: terminal) }
        })
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.terminal === source else { return }
            self.status = .disconnected(reason: exitCode == 0 ? nil : NSLocalizedString("ssh.ended", comment: ""))
        }
    }
}

private struct TerminalWrapper: NSViewRepresentable {
    let view: LocalProcessTerminalView
    func makeNSView(context: Context) -> LocalProcessTerminalView { view }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
