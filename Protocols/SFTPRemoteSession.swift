import SwiftUI
import SwiftTerm

/// OpenSSH handles authentication in a terminal. SFTP then uses the authenticated
/// private control socket, with no passwords in arguments, files or logs.
final class SFTPRemoteSession: NSObject, RemoteSession, LocalProcessTerminalViewDelegate {
    let profile: ConnectionProfile
    @Published private(set) var status: SessionStatus = .idle
    @Published private(set) var entries: [SFTPEntry] = []
    @Published private(set) var directory = ""
    @Published private(set) var busy = false
    @Published private(set) var transferred: UInt64 = 0
    @Published var errorMessage: String?
    private(set) var terminal: LocalProcessTerminalView?
    private var socketDirectory: URL?
    private var authenticationTimer: Timer?
    private let queue = DispatchQueue(label: "se.fjarrconnect.sftp", qos: .userInitiated)
    private let clientLock = NSLock()
    private var client: SFTPClient?
    private var stopped = false

    init(profile: ConnectionProfile) { self.profile = profile; super.init() }
    func start() {
        guard terminal == nil else { return }
        do {
            // Darwin Unix-domain socket paths are limited to 104 bytes.
            let folder = URL(fileURLWithPath: "/tmp/fjarr-sftp-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            socketDirectory = folder
            let view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 550))
            view.processDelegate = self
            view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            terminal = view
            view.startProcess(executable: "/usr/bin/ssh",
                args: ["-M", "-S", folder.appendingPathComponent("control").path, "-N", "-o", "ControlPersist=no"] + SSHArguments.connection(profile) + ["--", profile.host],
                environment: SSHArguments.environment())
            guard view.process.running else { throw SFTPFailure.disconnected }
            status = .connecting
            authenticationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.checkAuthentication() }
        } catch { stop(); status = .disconnected(reason: error.localizedDescription) }
    }
    private func checkAuthentication() {
        guard let socket = socketDirectory?.appendingPathComponent("control").path,
              FileManager.default.fileExists(atPath: socket) else { return }
        authenticationTimer?.invalidate(); authenticationTimer = nil
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let client = try SFTPClient(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments:
                    ["-S", socket, "-o", "BatchMode=yes", "-o", "ControlMaster=no", "-o", "ClearAllForwardings=yes",
                     "-o", "RemoteCommand=none", "-o", "RequestTTY=no"] + SSHArguments.connection(self.profile) + ["-s", "--", self.profile.host, "sftp"])
                self.clientLock.lock()
                if self.stopped { self.clientLock.unlock(); client.close(); return }
                self.client = client; self.clientLock.unlock()
                let path = try client.realPath(self.profile.ssh?.startDirectory ?? ".")
                let entries = try client.list(path)
                DispatchQueue.main.async {
                    guard !self.status.isFinished else { return }
                    self.entries = entries; self.directory = path; self.busy = false; self.status = .connected
                }
            } catch { DispatchQueue.main.async { if !self.status.isFinished { self.stop(); self.status = .disconnected(reason: error.localizedDescription) } } }
        }
    }
    func browse(_ path: String) {
        perform { client in
            let canonical = try client.realPath(path)
            let entries = try client.list(canonical)
            return (canonical, entries)
        }
    }
    func upload(_ files: [(URL, Bool)]) {
        let destination = directory
        perform { client in
            for (file, overwrite) in files {
                try client.upload(file, to: SFTPClient.join(destination, file.lastPathComponent), overwrite: overwrite)
            }
            return (destination, try client.list(destination))
        }
    }
    func download(_ entry: SFTPEntry, to destination: URL, overwrite: Bool) {
        let remote = SFTPClient.join(directory, entry.name), current = directory
        perform { client in
            try client.download(remote, to: destination, overwrite: overwrite)
            return (current, try client.list(current))
        }
    }
    func makeDirectory(_ name: String) {
        guard SFTPClient.safeName(name) else { return }
        let current = directory
        perform { client in try client.makeDirectory(SFTPClient.join(current, name)); return (current, try client.list(current)) }
    }
    func rename(_ entry: SFTPEntry, to name: String) {
        guard SFTPClient.safeName(name) else { return }
        let current = directory
        perform { client in
            try client.rename(SFTPClient.join(current, entry.name), to: SFTPClient.join(current, name))
            return (current, try client.list(current))
        }
    }
    func remove(_ entry: SFTPEntry) {
        let current = directory
        perform { client in
            try client.remove(SFTPClient.join(current, entry.name), directory: entry.isDirectory)
            return (current, try client.list(current))
        }
    }
    private func perform(_ operation: @escaping (SFTPClient) throws -> (String, [SFTPEntry])) {
        guard !busy, status == .connected else { return }
        busy = true; transferred = 0; errorMessage = nil
        queue.async { [weak self] in
            guard let self else { return }
            self.clientLock.lock(); let client = self.client; self.clientLock.unlock()
            guard let client else { return }
            var bytes: UInt64 = 0, lastUpdate = ProcessInfo.processInfo.systemUptime
            client.onProgress = { count in
                bytes += count
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastUpdate > 0.15 {
                    lastUpdate = now; let total = bytes
                    DispatchQueue.main.async { self.transferred = total }
                }
            }
            let result = Result { try operation(client) }
            client.onProgress = nil
            let total = bytes
            DispatchQueue.main.async {
                guard !self.status.isFinished else { return }
                self.busy = false; self.transferred = total
                switch result {
                case .success(let (path, entries)): self.directory = path; self.entries = entries
                case .failure(let error):
                    if let failure = error as? SFTPFailure, failure.isFatal {
                        self.stop(); self.status = .disconnected(reason: failure.localizedDescription)
                    } else { self.errorMessage = error.localizedDescription }
                }
            }
        }
    }
    func stop() {
        authenticationTimer?.invalidate(); authenticationTimer = nil
        clientLock.lock(); stopped = true; let client = self.client; self.client = nil; clientLock.unlock()
        client?.cancel()
        let folder = socketDirectory
        queue.async { client?.close(); if let folder { try? FileManager.default.removeItem(at: folder) } }
        terminal?.processDelegate = nil; terminal?.terminate(); terminal = nil
        socketDirectory = nil; busy = false
        status = .disconnected(reason: nil)
    }
    func makeScreenView() -> AnyView { AnyView(SFTPBrowserView(session: self)) }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.status.isFinished else { return }
            self.stop(); self.status = .disconnected(reason: NSLocalizedString("files.error.connection", comment: ""))
        }
    }
}
