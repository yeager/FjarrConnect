import SwiftUI

/// User defaults shared by the Settings window and the session/discovery flows.
enum AppSettings {
    static let showSidebar = "settings.showSidebar"
    static let useLargeControls = "settings.useLargeControls"
    static let autoStartDiscovery = "settings.autoStartDiscovery"
    static let autoHideSidebarWhileConnected = "settings.autoHideSidebarWhileConnected"
    static let autoHideSessionTabsWhileConnected = "settings.autoHideSessionTabsWhileConnected"
    static let confirmClosingSessions = "settings.confirmClosingSessions"
    static let scanTimeout = "settings.scanTimeout"
    static let scanConcurrency = "settings.scanConcurrency"

    static var shouldAutoStartDiscovery: Bool {
        UserDefaults.standard.object(forKey: autoStartDiscovery) as? Bool ?? true
    }

    static var shouldConfirmClosingSessions: Bool {
        UserDefaults.standard.object(forKey: confirmClosingSessions) as? Bool ?? true
    }
}
