import SwiftUI

@main
struct FjarrConnectApp: App {
    @NSApplicationDelegateAdaptor(FjarrConnectAppDelegate.self) private var appDelegate
    @StateObject private var profiles = FjarrConnectApp.makeProfileStore()
    @StateObject private var discovery = BonjourBrowser()
    @StateObject private var connection = FjarrConnectApp.makeConnectionManager()

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
                .frame(minWidth: 900, minHeight: 560)
                .background(WindowCloseConfirmation(shouldClose: connection.confirmClosingAll))
                .onAppear {
                    appDelegate.shouldTerminate = connection.confirmClosingAll
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["FJARRCONNECT_DISABLE_DISCOVERY"] == "1" ||
                        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
                    #endif
                    discovery.start()
                }
                .onDisappear { connection.disconnectAll(); discovery.stop() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    connection.disconnectAll()
                    discovery.stop()
                }
        }
        .windowStyle(.titleBar)
    }
}
