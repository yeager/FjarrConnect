import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.showSidebar) private var showSidebar = true
    @AppStorage(AppSettings.useLargeControls) private var useLargeControls = false
    @AppStorage(AppSettings.autoStartDiscovery) private var autoStartDiscovery = true
    @AppStorage(AppSettings.confirmClosingSessions) private var confirmClosingSessions = true
    @AppStorage(AppSettings.autoHideSidebarWhileConnected) private var autoHideSidebarWhileConnected = false
    @AppStorage(AppSettings.autoHideSessionTabsWhileConnected) private var autoHideSessionTabsWhileConnected = false
    @AppStorage(AppSettings.scanTimeout) private var scanTimeout = 2.0
    @AppStorage(AppSettings.scanConcurrency) private var scanConcurrency = 32

    var body: some View {
        TabView {
            Form {
                Section("settings.appearance") {
                    Toggle("settings.showSidebar", isOn: $showSidebar)
                    Toggle("settings.useLargeControls", isOn: $useLargeControls)
                    Toggle("settings.autoHideSidebarWhileConnected", isOn: $autoHideSidebarWhileConnected)
                    Toggle("settings.autoHideSessionTabsWhileConnected", isOn: $autoHideSessionTabsWhileConnected)
                }
                Section("settings.connections") {
                    Toggle("settings.autoStartDiscovery", isOn: $autoStartDiscovery)
                    Toggle("settings.confirmClosingSessions", isOn: $confirmClosingSessions)
                }
            }
            .formStyle(.grouped)
            .padding()
            .tabItem { Label("settings.simple", systemImage: "slider.horizontal.3") }

            Form {
                Section("settings.networkScan") {
                    Stepper(value: $scanTimeout, in: 0.1...10, step: 0.1) {
                        Text(String(format: NSLocalizedString("settings.scanTimeout", comment: ""), scanTimeout))
                    }
                    Text("settings.scanTimeout.hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Stepper(value: $scanConcurrency, in: 1...64) {
                        Text(String(format: NSLocalizedString("settings.scanConcurrency", comment: ""), scanConcurrency))
                    }
                    Text("settings.scanConcurrency.hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding()
            .tabItem { Label("settings.advanced", systemImage: "gearshape.2") }
        }
        .frame(width: 500, height: 280)
    }
}
