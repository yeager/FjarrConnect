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
}
