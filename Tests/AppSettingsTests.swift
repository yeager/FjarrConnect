import XCTest
@testable import FjarrConnect

final class AppSettingsTests: XCTestCase {
    func testSidebarOnlyAutoHidesAfterSelectedSessionIsEstablished() {
        XCTAssertTrue(AppSettings.shouldShowSidebar(showSidebar: true,
                                                     autoHideWhileConnected: false,
                                                     selectedSessionStatus: .connected))
        XCTAssertTrue(AppSettings.shouldShowSidebar(showSidebar: true,
                                                     autoHideWhileConnected: true,
                                                     selectedSessionStatus: .connecting))
        XCTAssertFalse(AppSettings.shouldShowSidebar(showSidebar: true,
                                                      autoHideWhileConnected: true,
                                                      selectedSessionStatus: .connected))
        XCTAssertTrue(AppSettings.shouldShowSidebar(showSidebar: true,
                                                     autoHideWhileConnected: true,
                                                     selectedSessionStatus: .disconnected(reason: "failed")))
        XCTAssertFalse(AppSettings.shouldShowSidebar(showSidebar: false,
                                                      autoHideWhileConnected: false,
                                                      selectedSessionStatus: nil))
    }

    func testSessionTabsOnlyAutoHideAfterSelectedSessionIsEstablished() {
        XCTAssertTrue(AppSettings.shouldShowSessionTabs(autoHideWhileConnected: false,
                                                         selectedSessionStatus: .connected))
        XCTAssertTrue(AppSettings.shouldShowSessionTabs(autoHideWhileConnected: true,
                                                         selectedSessionStatus: .connecting))
        XCTAssertTrue(AppSettings.shouldShowSessionTabs(autoHideWhileConnected: true,
                                                         selectedSessionStatus: .disconnected(reason: "failed")))
        XCTAssertFalse(AppSettings.shouldShowSessionTabs(autoHideWhileConnected: true,
                                                          selectedSessionStatus: .running))
        XCTAssertTrue(AppSettings.shouldShowSessionTabs(autoHideWhileConnected: true,
                                                         selectedSessionStatus: .disconnected(reason: "network timeout")))
        XCTAssertTrue(AppSettings.shouldShowSessionTabs(autoHideWhileConnected: true,
                                                         selectedSessionStatus: nil))
    }

    func testUpdateChecksCanBeDisabledAndDefaultToEnabled() {
        XCTAssertFalse(AppSettings.shouldCheckForUpdates(storedPreference: false))
        XCTAssertTrue(AppSettings.shouldCheckForUpdates(storedPreference: true))
        XCTAssertTrue(AppSettings.shouldCheckForUpdates(storedPreference: nil))
    }

    @MainActor
    func testDisabledPreferenceSkipsManualUpdateCheck() async {
        let defaults = UserDefaults.standard
        let key = ReleaseUpdateChecker.automaticChecksKey
        let previousValue = defaults.object(forKey: key)
        defaults.set(false, forKey: key)
        defer {
            if let previousValue { defaults.set(previousValue, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        await ReleaseUpdateChecker.shared.checkNow()

        XCTAssertEqual(ReleaseUpdateChecker.shared.status, .idle)
    }

    func testReleaseVersionComparisonHandlesTagsAndMissingPatchComponents() {
        XCTAssertEqual(ReleaseVersion.isNewer("v1.2.0", than: "1.1.9"), true)
        XCTAssertEqual(ReleaseVersion.isNewer("1.2", than: "v1.2.0"), false)
        XCTAssertEqual(ReleaseVersion.isNewer("1.10.0", than: "1.9.9"), true)
        XCTAssertNil(ReleaseVersion.isNewer("nightly", than: "1.0.0"))
    }
}
