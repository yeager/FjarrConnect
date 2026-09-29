import AppKit
import SwiftUI

@main
struct FjarrConnectApp: App {
    @NSApplicationDelegateAdaptor(FjarrConnectAppDelegate.self) private var appDelegate
    @StateObject private var profiles = FjarrConnectApp.makeProfileStore()
    @StateObject private var discovery = BonjourBrowser()
    @StateObject private var connection = FjarrConnectApp.makeConnectionManager()
    @StateObject private var releaseUpdates = ReleaseUpdateChecker.shared

    private static func makeConnectionManager() -> ConnectionManager {
        #if DEBUG
        if ProcessInfo.processInfo.environment["FJARRCONNECT_TEST_PROFILE_PATH"] != nil,
           let path = ProcessInfo.processInfo.environment["FJARRCONNECT_TEST_SSH_CONFIG"] {
            return ConnectionManager { profile, credentials in
                if profile.transport == .sftp && profile.host == "127.0.0.1" {
                    return SFTPRemoteSession(profile: profile, sshConfiguration: URL(fileURLWithPath: path))
                }
                return ProtocolRegistry.makeSession(for: profile, credentials: credentials)
            }
        }
        #endif
        return ConnectionManager()
    }

    private static func makeProfileStore() -> ProfileStore {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["FJARRCONNECT_TEST_PROFILE_PATH"] {
            return ProfileStore(fileURL: URL(fileURLWithPath: path))
        }
        #endif
        return ProfileStore()
    }

    var body: some Scene {
        Window("FjärrConnect", id: "main") {
            ContentView()
                .environmentObject(profiles)
                .environmentObject(discovery)
                .environmentObject(connection)
                .environmentObject(releaseUpdates)
                .frame(minWidth: 900, minHeight: 560)
                .background(WindowCloseConfirmation(
                    shouldClose: connection.confirmClosingAll,
                    onClose: { connection.disconnectAll(); discovery.stop() }
                ).allowsHitTesting(false))
                .onAppear {
                    markSmokeLaunchReadyIfRequested()
                    appDelegate.shouldTerminate = connection.confirmClosingAll
                    releaseUpdates.checkOnLaunchIfEnabled()
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["FJARRCONNECT_DISABLE_DISCOVERY"] == "1" ||
                        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
                    #endif
                    if AppSettings.shouldAutoStartDiscovery { discovery.start() }
                }
                // `onDisappear` can run during transient SwiftUI scene/view
                // replacement. Keep sessions until the main window really closes.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    connection.disconnectAll()
                    discovery.stop()
                }
        }
        .windowStyle(.titleBar)

        Settings {
            SettingsView()
                .environmentObject(profiles)
                .environmentObject(releaseUpdates)
        }

        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("about.menu", action: AboutPanel.show)
            }
            CommandGroup(after: .appInfo) {
                Button("about.repository", action: AboutPanel.openRepository)
            }
            CommandMenu("menu.sessions") {
                Button("session.previous") { connection.selectPreviousSession() }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                    .disabled(connection.tabs.count < 2)
                Button("session.next") { connection.selectNextSession() }
                    .keyboardShortcut(.tab, modifiers: [.control])
                    .disabled(connection.tabs.count < 2)
            }
            CommandMenu("menu.favorites") {
                if profiles.favorites.isEmpty {
                    Text("menu.favorites.empty")
                } else {
                    ForEach(profiles.favorites) { profile in
                        Button(profile.name) {
                            NotificationCenter.default.post(name: .connectSavedProfile, object: profile.id)
                        }
                    }
                }
            }
        }
    }

    /// The release smoke test passes a random token and waits for the window
    /// content to appear. This distinguishes a live app from dyld being stuck
    /// while opening one of its embedded frameworks.
    private func markSmokeLaunchReadyIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--fc-smoke-ready"),
              arguments.indices.contains(index + 1),
              let token = UUID(uuidString: arguments[index + 1]) else { return }
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let marker = temporaryDirectory
            .appendingPathComponent("fjarrconnect-smoke-\(token.uuidString)")
        try? Data("ready".utf8).write(to: marker, options: .atomic)

        guard arguments.contains("--fc-smoke-rdp-runtime") else { return }
        let runtimeMarker = temporaryDirectory
            .appendingPathComponent("fjarrconnect-rdp-smoke-\(token.uuidString)")
        RDPRuntime.load { result in
            let status: String
            if case .success = result { status = "loaded" } else { status = "failed" }
            try? Data(status.utf8)
                .write(to: runtimeMarker, options: .atomic)
        }
    }
}

extension Notification.Name {
    static let connectSavedProfile = Notification.Name("se.fjarrconnect.connectSavedProfile")
}
