import SwiftUI

@main
struct FjarrConnectApp: App {
    @StateObject private var profiles = ProfileStore()
    @StateObject private var discovery = BonjourBrowser()
    @StateObject private var connection = ConnectionManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(profiles)
                .environmentObject(discovery)
                .environmentObject(connection)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { discovery.start() }
        }
        .windowStyle(.titleBar)
    }
}
