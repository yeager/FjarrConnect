import SwiftUI

/// Runs the native macOS SDL client. FreeRDP owns its graphical window and
/// interactive certificate checks; this session owns and terminates the process.
final class RDPRemoteSession: NSObject, RemoteSession {
    let profile: ConnectionProfile
    private var password: String?
    @Published private(set) var status: SessionStatus = .idle
    private var process: Process?

    static var executable: URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sdl-freerdp").path
        let paths = [bundled, "/opt/homebrew/bin/sdl-freerdp", "/usr/local/bin/sdl-freerdp",
                     "/opt/homebrew/bin/sdl-freerdp3", "/usr/local/bin/sdl-freerdp3"]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    init(profile: ConnectionProfile, password: String?) {
        self.profile = profile
        self.password = password
        super.init()
    }
    func start() {
        guard process == nil else { return }
        guard let executable = Self.executable else {
            status = .disconnected(reason: NSLocalizedString("rdp.install", comment: "")); return
        }
        guard let input = RDPArguments.input(profile: profile, password: password) else {
            status = .disconnected(reason: NSLocalizedString("rdp.invalid", comment: "")); return
        }
        password = nil
        let task = Process()
        let pipe = Pipe()
        task.executableURL = executable
        task.arguments = ["/args-from:stdin"]
        task.standardInput = pipe
        // Do not capture backend diagnostics which could include credentials.
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                guard let self, self.process === ended else { return }
                self.process = nil
                self.status = .disconnected(reason: ended.terminationStatus == 0 ? nil : NSLocalizedString("rdp.ended", comment: ""))
            }
        }
        do {
            try task.run()
            process = task
            status = .running
            // Only the anonymous pipe contains credentials, never argv or a file.
            DispatchQueue.global(qos: .userInitiated).async {
                try? pipe.fileHandleForWriting.write(contentsOf: input)
                try? pipe.fileHandleForWriting.close()
            }
        } catch { status = .disconnected(reason: error.localizedDescription) }
    }
    func stop() {
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        password = nil
        status = .disconnected(reason: nil)
    }
    func makeScreenView() -> AnyView {
        AnyView(VStack(spacing: 16) {
            Image(systemName: "rectangle.on.rectangle").font(.system(size: 48)).foregroundStyle(.tint)
            Text("rdp.window.title").font(.title2.bold())
            Text("rdp.window.description").foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("rdp.showWindow") {
                if let process = self.process, process.isRunning {
                    NSRunningApplication(processIdentifier: process.processIdentifier)?.activate(options: [.activateIgnoringOtherApps])
                }
            }.buttonStyle(.borderedProminent)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity))
    }
}
