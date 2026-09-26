import Carbon
import Foundation
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
    static let automaticUpdateChecks = "settings.automaticUpdateChecks"

    static func shouldShowSidebar(showSidebar: Bool, autoHideWhileConnected: Bool,
                                  hasActiveSessions: Bool) -> Bool {
        showSidebar && !(autoHideWhileConnected && hasActiveSessions)
    }

    static func shouldShowSessionTabs(autoHideWhileConnected: Bool,
                                      hasActiveSessions: Bool) -> Bool {
        !autoHideWhileConnected || !hasActiveSessions
    }

    static func shouldCheckForUpdatesAutomatically(storedPreference: Bool?) -> Bool {
        storedPreference ?? true
    }

    static var shouldAutoStartDiscovery: Bool {
        UserDefaults.standard.object(forKey: autoStartDiscovery) as? Bool ?? true
    }

    static var shouldConfirmClosingSessions: Bool {
        UserDefaults.standard.object(forKey: confirmClosingSessions) as? Bool ?? true
    }
}

enum ReleaseUpdateStatus: Equatable {
    case idle
    case checking
    case available(version: String, releaseURL: URL)
    case upToDate
    case failed
}

/// Checks GitHub Releases for a newer stable version. It never downloads or installs updates.
@MainActor
final class ReleaseUpdateChecker: ObservableObject {
    static let shared = ReleaseUpdateChecker()
    static let automaticChecksKey = AppSettings.automaticUpdateChecks

    @Published private(set) var status: ReleaseUpdateStatus = .idle
    private var didCheckOnLaunch = false

    private init() {}

    func checkOnLaunchIfEnabled() {
        guard !didCheckOnLaunch else { return }
        didCheckOnLaunch = true
#if DEBUG
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
#endif
        let storedPreference = UserDefaults.standard.object(forKey: Self.automaticChecksKey) as? Bool
        guard AppSettings.shouldCheckForUpdatesAutomatically(storedPreference: storedPreference) else { return }
        Task { await checkNow() }
    }

    func checkNow() async {
        status = .checking
        guard let endpoint = URL(string: "https://api.github.com/repos/yeager/FjarrConnect/releases/latest") else {
            status = .failed
            return
        }

        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("FjarrConnect", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                status = .failed
                return
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard !release.draft, !release.prerelease,
                  let releaseURL = URL(string: release.htmlURL),
                  releaseURL.scheme == "https",
                  releaseURL.host == "github.com",
                  let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                  let isNewer = ReleaseVersion.isNewer(release.tagName, than: currentVersion) else {
                status = .failed
                return
            }
            status = isNewer ? .available(version: release.tagName, releaseURL: releaseURL) : .upToDate
        } catch {
            status = .failed
        }
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
            case prerelease
        }
    }
}

enum ReleaseVersion {
    static func isNewer(_ candidate: String, than current: String) -> Bool? {
        guard let candidateParts = components(candidate),
              let currentParts = components(current) else { return nil }
        for index in 0..<max(candidateParts.count, currentParts.count) {
            let candidatePart = index < candidateParts.count ? candidateParts[index] : 0
            let currentPart = index < currentParts.count ? currentParts[index] : 0
            if candidatePart != currentPart { return candidatePart > currentPart }
        }
        return false
    }

    private static func components(_ version: String) -> [Int]? {
        var normalized = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.first == "v" || normalized.first == "V" { normalized.removeFirst() }
        normalized = normalized.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? ""
        let parts = normalized.split(separator: ".")
        guard !parts.isEmpty else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == parts.count ? numbers : nil
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
