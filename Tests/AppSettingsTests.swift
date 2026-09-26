import XCTest
@testable import FjarrConnect

final class AppSettingsTests: XCTestCase {
    func testSidebarOnlyAutoHidesWhenEnabledAndASessionIsActive() {
        XCTAssertTrue(AppSettings.shouldShowSidebar(showSidebar: true,
                                                     autoHideWhileConnected: false,
                                                     hasActiveSessions: true))
        XCTAssertTrue(AppSettings.shouldShowSidebar(showSidebar: true,
                                                     autoHideWhileConnected: true,
                                                     hasActiveSessions: false))
        XCTAssertFalse(AppSettings.shouldShowSidebar(showSidebar: true,
                                                      autoHideWhileConnected: true,
                                                      hasActiveSessions: true))
        XCTAssertFalse(AppSettings.shouldShowSidebar(showSidebar: false,
                                                      autoHideWhileConnected: false,
                                                      hasActiveSessions: false))
    }

    func testSessionTabsOnlyAutoHideWhenEnabledAndASessionIsActive() {
        XCTAssertTrue(AppSettings.shouldShowSessionTabs(autoHideWhileConnected: false,
                                                         hasActiveSessions: true))
        XCTAssertTrue(AppSettings.shouldShowSessionTabs(autoHideWhileConnected: true,
                                                         hasActiveSessions: false))
        XCTAssertFalse(AppSettings.shouldShowSessionTabs(autoHideWhileConnected: true,
                                                          hasActiveSessions: true))
    }

    func testReleaseVersionComparisonHandlesTagsAndMissingPatchComponents() {
        XCTAssertEqual(ReleaseVersion.isNewer("v1.2.0", than: "1.1.9"), true)
        XCTAssertEqual(ReleaseVersion.isNewer("1.2", than: "v1.2.0"), false)
        XCTAssertEqual(ReleaseVersion.isNewer("1.10.0", than: "1.9.9"), true)
        XCTAssertNil(ReleaseVersion.isNewer("nightly", than: "1.0.0"))
    }
}
