import Carbon
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
    static let recordingRetentionDays = "settings.recordingRetentionDays"
    static let keyboardLayout = "settings.keyboardLayout"

    static var shouldAutoStartDiscovery: Bool {
        UserDefaults.standard.object(forKey: autoStartDiscovery) as? Bool ?? true
    }

    static var shouldConfirmClosingSessions: Bool {
        UserDefaults.standard.object(forKey: confirmClosingSessions) as? Bool ?? true
    }
}

enum RDPKeyboardLayout: String, CaseIterable, Identifiable {
    case automatic
    case usEnglish
    case britishEnglish
    case german
    case french
    case swedish
    case danish
    case norwegian
    case finnish
    case spanish
    case italian

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .automatic: "settings.keyboardLayout.automatic"
        case .usEnglish: "settings.keyboardLayout.usEnglish"
        case .britishEnglish: "settings.keyboardLayout.britishEnglish"
        case .german: "settings.keyboardLayout.german"
        case .french: "settings.keyboardLayout.french"
        case .swedish: "settings.keyboardLayout.swedish"
        case .danish: "settings.keyboardLayout.danish"
        case .norwegian: "settings.keyboardLayout.norwegian"
        case .finnish: "settings.keyboardLayout.finnish"
        case .spanish: "settings.keyboardLayout.spanish"
        case .italian: "settings.keyboardLayout.italian"
        }
    }

    var windowsLayoutID: UInt32? {
        switch self {
        case .automatic: nil
        case .usEnglish: 0x00000409
        case .britishEnglish: 0x00000809
        case .german: 0x00000407
        case .french: 0x0000040C
        case .swedish: 0x0000041D
        case .danish: 0x00000406
        case .norwegian: 0x00000414
        case .finnish: 0x0000040B
        case .spanish: 0x0000040A
        case .italian: 0x00000410
        }
    }

    static func resolvedWindowsLayoutID(selection: String, inputSourceID: String?) -> UInt32? {
        guard let selected = RDPKeyboardLayout(rawValue: selection) else { return nil }
        if selected != .automatic { return selected.windowsLayoutID }
        guard let inputSourceID else { return nil }
        let source = inputSourceID.lowercased()
        if source.contains("keylayout.us") { return RDPKeyboardLayout.usEnglish.windowsLayoutID }
        if source.contains("keylayout.british") { return RDPKeyboardLayout.britishEnglish.windowsLayoutID }
        if source.contains("keylayout.swedish") { return RDPKeyboardLayout.swedish.windowsLayoutID }
        if source.contains("keylayout.german") { return RDPKeyboardLayout.german.windowsLayoutID }
        if source.contains("keylayout.french") { return RDPKeyboardLayout.french.windowsLayoutID }
        if source.contains("keylayout.danish") { return RDPKeyboardLayout.danish.windowsLayoutID }
        if source.contains("keylayout.norwegian") { return RDPKeyboardLayout.norwegian.windowsLayoutID }
        if source.contains("keylayout.finnish") { return RDPKeyboardLayout.finnish.windowsLayoutID }
        if source.contains("keylayout.spanish") { return RDPKeyboardLayout.spanish.windowsLayoutID }
        if source.contains("keylayout.italian") { return RDPKeyboardLayout.italian.windowsLayoutID }
        return nil
    }

    static var currentInputSourceID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
    }

    static var selectedWindowsLayoutID: UInt32? {
        let selection = UserDefaults.standard.string(forKey: AppSettings.keyboardLayout) ?? Self.automatic.rawValue
        return resolvedWindowsLayoutID(selection: selection, inputSourceID: currentInputSourceID)
    }
}
