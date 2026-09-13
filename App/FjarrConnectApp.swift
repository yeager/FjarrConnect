import SwiftUI

@main
struct FjarrConnectApp: App {
    @StateObject private var profiles = FjarrConnectApp.makeProfileStore()
    @StateObject private var discovery = BonjourBrowser()
    @StateObject private var connection = ConnectionManager()

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
                .onAppear {
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
