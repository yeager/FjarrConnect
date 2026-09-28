import XCTest

final class ConnectionUITests: XCTestCase {
    private func assertVisible(_ element: XCUIElement, inside window: XCUIElement,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.isHittable, "Expected element to remain hittable", file: file, line: line)
        let frame = element.frame
        let bounds = window.frame
        XCTAssertGreaterThanOrEqual(frame.minX - bounds.minX, -4, "Element moved past the left edge", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY - bounds.minY, -4, "Element moved above the window", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX - bounds.maxX, 4, "Element moved past the right edge", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY - bounds.maxY, 4, "Element moved below the window", file: file, line: line)
    }

    func testSessionNavigationMenuIsAccessibleWithoutOpenSessions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["FJARRCONNECT_TEST_PROFILE_PATH"] = directory.appendingPathComponent("profiles.json").path
        app.launchEnvironment["FJARRCONNECT_DISABLE_DISCOVERY"] = "1"
        app.launch(); defer { app.terminate() }

        let menu = app.menuBars.menuBarItems["Sessions"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.click()
        XCTAssertTrue(app.menuItems["Previous session"].exists)
        XCTAssertTrue(app.menuItems["Next session"].exists)
        XCTAssertFalse(app.menuItems["Previous session"].isEnabled)
        XCTAssertFalse(app.menuItems["Next session"].isEnabled)
    }

    func testEmptyHomeShowsSidebarAndWelcomeContent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["FJARRCONNECT_TEST_PROFILE_PATH"] = directory.appendingPathComponent("profiles.json").path
        app.launchEnvironment["FJARRCONNECT_DISABLE_DISCOVERY"] = "1"
        app.launch()
        defer { app.terminate() }

        let quickConnect = app.textFields["sidebar.quickConnect"]
        let welcome = app.staticTexts["welcome.title"]
        XCTAssertTrue(quickConnect.waitForExistence(timeout: 15),
                      "The sidebar quick-connect field should render with no saved profiles")
        XCTAssertTrue(quickConnect.isHittable,
                      "The sidebar should be visible and usable with no saved profiles")
        XCTAssertTrue(app.staticTexts["sidebar.quickConnect.title"].exists,
                      "The sidebar heading should render with no saved profiles")
        XCTAssertTrue(welcome.waitForExistence(timeout: 5),
                      "The main welcome view should render with no selected session")
        XCTAssertTrue(welcome.isHittable,
                      "The main welcome view should not be covered by another view")
    }

    func testAboutPanelKeepsMainWindowAndSidebarAvailable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["FJARRCONNECT_TEST_PROFILE_PATH"] = directory.appendingPathComponent("profiles.json").path
        app.launchEnvironment["FJARRCONNECT_DISABLE_DISCOVERY"] = "1"
        app.launch()
        defer { app.terminate() }

        let quickConnect = app.textFields["sidebar.quickConnect"]
        XCTAssertTrue(quickConnect.waitForExistence(timeout: 15))
        XCTAssertTrue(quickConnect.isHittable)

        // macOS uses the bundle name without the UI's diacritic in the app menu.
        let appMenu = app.menuBars.menuBarItems["FjarrConnect"]
        XCTAssertTrue(appMenu.waitForExistence(timeout: 5))
        appMenu.click()
        let about = app.menuItems["About FjärrConnect"]
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.click()

        XCTAssertTrue(quickConnect.waitForExistence(timeout: 5),
                      "Opening About must not replace or close the main window")
        XCTAssertGreaterThan(quickConnect.frame.width, 0,
                             "The sidebar must retain a visible frame behind the About panel")
        XCTAssertTrue(quickConnect.isHittable,
                      "The main window sidebar should remain available after opening About")
    }

    func testQuickConnectStaysVisibleWhenSidebarListScrollsAndIsShownAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileFile = directory.appendingPathComponent("profiles.json")
        let profiles: [[String: Any]] = (0..<24).map { index in
            ["id": UUID().uuidString, "name": "Sidebar profile \(index)", "transport": "vnc",
             "host": "sidebar-\(index).invalid", "port": 5900]
        }
        try JSONSerialization.data(withJSONObject: profiles).write(to: profileFile)
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["FJARRCONNECT_TEST_PROFILE_PATH"] = profileFile.path
        app.launchEnvironment["FJARRCONNECT_DISABLE_DISCOVERY"] = "1"
        app.launch()
        defer { app.terminate() }

        let quickConnect = app.textFields["sidebar.quickConnect"]
        XCTAssertTrue(quickConnect.waitForExistence(timeout: 15))
        XCTAssertTrue(quickConnect.isHittable)
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(quickConnect.isHittable,
                      "Quick Connect should stay above the scrolling list of saved connections")

        let sidebarToggle = app.buttons.matching(identifier: "sidebar.toggle").firstMatch
        XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(sidebarToggle.label, "Hide Sidebar")
        sidebarToggle.click()
        let showSidebar = app.buttons.matching(identifier: "sidebar.toggle").firstMatch
        let showSidebarLabel = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Show Sidebar"),
                                                         object: showSidebar)
        XCTAssertEqual(XCTWaiter.wait(for: [showSidebarLabel], timeout: 5), .completed)
        showSidebar.click()

        XCTAssertTrue(quickConnect.waitForExistence(timeout: 5))
        let topRowIsVisible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"),
                                                        object: quickConnect)
        XCTAssertEqual(XCTWaiter.wait(for: [topRowIsVisible], timeout: 5), .completed,
                       "The top sidebar row should be visible after showing the sidebar again")
    }

    func testRDPProfileOffersOneSessionFileClipboardActionWithoutSavingOptIn() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profiles.json")
        let profile: [String: Any] = [
            "id": UUID().uuidString, "name": "RDP file test", "transport": "rdp",
            "host": "rdp.invalid", "port": 3389, "rdp": ["clipboardFiles": false]
        ]
        try JSONSerialization.data(withJSONObject: [profile]).write(to: file)
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["FJARRCONNECT_TEST_PROFILE_PATH"] = file.path
        app.launchEnvironment["FJARRCONNECT_DISABLE_DISCOVERY"] = "1"
        app.launch()
        defer { app.terminate() }

        let row = app.buttons["connect.RDP file test"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.rightClick()
        XCTAssertTrue(app.menuItems["Connect once with file clipboard"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])

        let savedProfiles = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        let savedRDP = try XCTUnwrap(savedProfiles.first?["rdp"] as? [String: Any])
        XCTAssertEqual(savedRDP["clipboardFiles"] as? Bool, false)
    }

    func testSessionTabsStayAtTopOfWindowAfterConnectionStarts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profiles.json")
        let profile: [String: Any] = [
            "id": UUID().uuidString, "name": "Layout test", "transport": "ssh",
            "host": "127.0.0.1", "port": 45999
        ]
        try JSONSerialization.data(withJSONObject: [profile]).write(to: file)
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["FJARRCONNECT_TEST_PROFILE_PATH"] = file.path
        app.launchEnvironment["FJARRCONNECT_DISABLE_DISCOVERY"] = "1"
        app.launch()
        defer { app.terminate() }

        let profileRow = app.buttons["connect.Layout test"].firstMatch
        XCTAssertTrue(profileRow.waitForExistence(timeout: 15))
        profileRow.doubleClick()
        let sessionTab = app.buttons["session.select.Layout test"].firstMatch
        XCTAssertTrue(sessionTab.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists)
        XCTAssertLessThan(sessionTab.frame.minY - window.frame.minY, 180,
                          "The session tab bar should remain directly below the window toolbar, including after a connection error")
    }

    func testFailedVNCConnectionKeepsSessionMenuAtTop() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profiles.json")
        let profile: [String: Any] = [
            "id": UUID().uuidString, "name": "VNC layout test", "transport": "vnc",
            "host": "127.0.0.1", "port": 45906, "clipboardEnabled": false
        ]
        try JSONSerialization.data(withJSONObject: [profile]).write(to: file)
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["FJARRCONNECT_TEST_PROFILE_PATH"] = file.path
        app.launchEnvironment["FJARRCONNECT_DISABLE_DISCOVERY"] = "1"
        app.launch()
        defer { app.terminate() }

        let profileRow = app.buttons["connect.VNC layout test"].firstMatch
        XCTAssertTrue(profileRow.waitForExistence(timeout: 15))
        profileRow.doubleClick()
        let connect = app.buttons["auth.connect"].firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        connect.click()
        XCTAssertTrue(app.buttons["session.select.VNC layout test"].waitForExistence(timeout: 10))
        let tab = app.buttons["session.select.VNC layout test"].firstMatch
        let reconnect = app.buttons["Reconnect"].firstMatch
        // The VNC session's production connection deadline is 20 seconds.
        // Leave margin for the UI to publish its disconnected state afterward.
        XCTAssertTrue(reconnect.waitForExistence(timeout: 25),
                      "The closed VNC test connection should reach its disconnected state")
        let window = app.windows.firstMatch
        let quickConnect = app.textFields["sidebar.quickConnect"]
        assertVisible(quickConnect, inside: window)
        XCTAssertGreaterThanOrEqual(quickConnect.frame.minY - window.frame.minY, -4,
                                    "A failed VNC connection must keep the sidebar inside the window")
        assertVisible(tab, inside: window)
        XCTAssertLessThan(tab.frame.minY - window.frame.minY, 180,
                          "A failed VNC session should not push the session menu down the window")
        XCTAssertTrue(quickConnect.exists,
                      "A failed VNC session should preserve the visible sidebar preference")
        XCTAssertGreaterThan(tab.frame.height, 0,
                             "The failed session's tab should retain a visible frame after disconnection")
        assertVisible(reconnect, inside: window)
        XCTAssertLessThan(reconnect.frame.minY - window.frame.minY, 240,
                          "The session controls should stay directly below the tab bar after a connection error")
    }

    func testFailedRDPConnectionKeepsSidebarAndSessionBarsAtTop() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
#if arch(arm64)
        let architecture = "arm64"
#elseif arch(x86_64)
        let architecture = "x86_64"
#else
        throw XCTSkip("No matching embedded FreeRDP runtime for this test architecture")
#endif
        let runtimeCandidates = [
            root.appendingPathComponent("build/debug-\(architecture)/Build/Products/Debug/FjarrConnect.app/Contents/Frameworks/libFjarrRDP.dylib"),
            root.appendingPathComponent("build/rdp-\(architecture)/FreeRDP-build/libFjarrRDP.dylib"),
            root.appendingPathComponent("build/rdp-output/\(architecture)/libFjarrRDP.dylib"),
            root.appendingPathComponent("build/verify-release-\(architecture)/Build/Products/Release/FjarrConnect.app/Contents/Frameworks/libFjarrRDP.dylib")
        ]
        guard let runtime = runtimeCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("A local embedded FreeRDP runtime is needed to exercise the RDP failure layout")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profiles.json")
        let profile: [String: Any] = [
            "id": UUID().uuidString, "name": "RDP layout test", "transport": "rdp",
            "host": "127.0.0.1", "port": 45999, "username": "layout-test"
        ]
        try JSONSerialization.data(withJSONObject: [profile]).write(to: file)
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["FJARRCONNECT_TEST_PROFILE_PATH"] = file.path
        app.launchEnvironment["FJARRCONNECT_DISABLE_DISCOVERY"] = "1"
        app.launchEnvironment["FJARRCONNECT_RDP_LIBRARY"] = runtime.path
        app.launchEnvironment["FJARRCONNECT_TEST_RDP_LOAD_DELAY"] = "15"
        app.launch()
        defer { app.terminate() }

        let profileRow = app.buttons["connect.RDP layout test"].firstMatch
        XCTAssertTrue(profileRow.waitForExistence(timeout: 15))
        let window = app.windows.firstMatch
        let quickConnect = app.textFields["sidebar.quickConnect"]
        assertVisible(quickConnect, inside: window)
        profileRow.doubleClick()
        let runtimeLoading = app.descendants(matching: .any)["rdp.runtimeLoading"]
        XCTAssertTrue(runtimeLoading.waitForExistence(timeout: 5),
                      "The app should show RDP runtime loading while it prepares a first connection")
        XCTAssertTrue(quickConnect.isHittable,
                      "Loading FreeRDP must not block the sidebar or the main event loop")
        // macOS exposes both the toolbar wrapper and its clickable child with
        // this identifier; test the actual button, not the wrapper element.
        let newConnectionButton = app.buttons.matching(identifier: "newConnection").element(boundBy: 1)
        XCTAssertTrue(newConnectionButton.isHittable,
                      "The toolbar should remain responsive while FreeRDP loads")
        let password = app.secureTextFields["auth.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 30))
        password.click()
        password.typeText("ui-test-only")
        app.buttons["auth.connect"].click()

        let tab = app.buttons["session.select.RDP layout test"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        let reconnect = app.buttons["Reconnect"].firstMatch
        XCTAssertTrue(reconnect.waitForExistence(timeout: 20), "The closed RDP test port should fail promptly")
        assertVisible(quickConnect, inside: window)
        XCTAssertLessThan(quickConnect.frame.minY - window.frame.minY, 180,
                          "A failed RDP connection must not push the sidebar down")
        assertVisible(tab, inside: window)
        XCTAssertLessThan(tab.frame.minY - window.frame.minY, 180,
                          "A failed RDP connection must keep session tabs under the window toolbar")
        assertVisible(reconnect, inside: window)
        XCTAssertLessThan(reconnect.frame.minY - window.frame.minY, 260,
                          "A multiline RDP error must keep session controls near the tab bar")
        XCTAssertTrue(reconnect.isHittable, "The reconnect action must remain reachable after a failed connection")

        reconnect.click()
        let retryPassword = app.secureTextFields["auth.password"]
        XCTAssertTrue(retryPassword.waitForExistence(timeout: 5),
                      "Manual RDP reconnect should ask for credentials before restarting the session")
        retryPassword.click()
        retryPassword.typeText("ui-test-only")
        app.buttons["auth.connect"].click()
        XCTAssertTrue(app.staticTexts["Disconnected"].waitForExistence(timeout: 20),
                      "The retry should finish in its disconnected state")
        XCTAssertTrue(reconnect.waitForExistence(timeout: 5),
                      "The closed RDP test port should fail again and restore the reconnect action")
        XCTAssertEqual(app.buttons.matching(identifier: "session.select.RDP layout test").count, 1,
                       "A failed retry should reuse the original session tab instead of creating a duplicate")
        assertVisible(quickConnect, inside: window)
        XCTAssertLessThan(quickConnect.frame.minY - window.frame.minY, 180,
                          "Retrying a failed RDP connection must not push the sidebar down")
        assertVisible(tab, inside: window)
        XCTAssertLessThan(tab.frame.minY - window.frame.minY, 180,
                          "Retrying a failed RDP connection must keep session tabs under the window toolbar")
        assertVisible(reconnect, inside: window)
        XCTAssertLessThan(reconnect.frame.minY - window.frame.minY, 260,
                          "After a retry fails, the session controls must remain near the tab bar")
        XCTAssertTrue(app.staticTexts["Disconnected"].exists,
                      "The failed retry should render the disconnected placeholder in the session view")
    }

    func testMacScreenSharingProfileRequiresUsernameBeforeSave() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profiles.json")
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["FJARRCONNECT_TEST_PROFILE_PATH"] = file.path
        app.launchEnvironment["FJARRCONNECT_DISABLE_DISCOVERY"] = "1"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["newConnection"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["newConnection"].firstMatch.click()
        let name = app.textFields["profile.name"].firstMatch
        let host = app.textFields["profile.host"].firstMatch
        let username = app.textFields["profile.username"].firstMatch
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        name.click(); name.typeText("Mac desktop")
        host.click(); host.typeText("mac.local")
        let authentication = app.popUpButtons["profile.vncAuthenticationMode"].firstMatch
        XCTAssertTrue(authentication.exists)
        authentication.click()
        app.menuItems["Mac Screen Sharing (username required)"].click()
        XCTAssertEqual(username.label, "Username (required)")
        XCTAssertFalse(app.buttons["profile.save"].isEnabled)
        username.click(); username.typeText("macuser")
        XCTAssertTrue(app.buttons["profile.save"].isEnabled)
        let password = app.secureTextFields["profile.password"]
        XCTAssertTrue(password.exists)
        let advanced = app.buttons["profile.advancedOptions"]
        XCTAssertTrue(advanced.exists)
        advanced.click()
        XCTAssertEqual(advanced.value as? String, "expanded")
        app.buttons["profile.save"].click()
        let profiles = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        XCTAssertEqual(profiles.first?["username"] as? String, "macuser")
        XCTAssertEqual(profiles.first?["macScreenSharing"] as? Bool, true)
    }

    func testSavedMacProfileShowsPasswordFieldAndExpandsAdvancedOptions() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profiles.json")
        let profile: [String: Any] = [
            "id": UUID().uuidString, "name": "Remote Mac", "transport": "vnc",
            "host": "mac.invalid", "port": 5900, "username": "macuser", "macScreenSharing": true
        ]
        try JSONSerialization.data(withJSONObject: [profile]).write(to: file)
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["FJARRCONNECT_TEST_PROFILE_PATH"] = file.path
        app.launchEnvironment["FJARRCONNECT_DISABLE_DISCOVERY"] = "1"
        app.launch()
        defer { app.terminate() }

        let row = app.buttons["connect.Remote Mac"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.rightClick()
        app.menuItems["Edit"].click()
        let password = app.secureTextFields["profile.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        XCTAssertTrue(password.isHittable, "The saved Mac profile must expose an editable Keychain password field")
        let advanced = app.buttons["profile.advancedOptions"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        advanced.click()
        XCTAssertEqual(advanced.value as? String, "expanded")
        XCTAssertTrue(app.textFields["profile.files.sshHost"].waitForExistence(timeout: 5))
    }

    func testStandardVNCUsernameRemainsOptional() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profiles.json")
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["FJARRCONNECT_TEST_PROFILE_PATH"] = file.path
        app.launchEnvironment["FJARRCONNECT_DISABLE_DISCOVERY"] = "1"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["newConnection"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["newConnection"].firstMatch.click()
        let name = app.textFields["profile.name"].firstMatch
        let host = app.textFields["profile.host"].firstMatch
        let username = app.textFields["profile.username"].firstMatch
        name.click(); name.typeText("Standard VNC")
        host.click(); host.typeText("vnc.local")
        XCTAssertEqual(username.label, "Username (required)")
        let authentication = app.popUpButtons["profile.vncAuthenticationMode"].firstMatch
        XCTAssertTrue(authentication.exists)
        authentication.click()
        app.menuItems["Standard VNC (password)"].click()
        XCTAssertEqual(username.label, "Username")
        XCTAssertTrue(app.buttons["profile.save"].isEnabled)
    }

    func testNetworkSearchVerifiesAndSavesALoopbackVNCService() throws {
        continueAfterFailure = false
        // Xcode's UI-test runner cannot listen on sockets. The test wrapper owns
        // this loopback-only banner server and stops it when xcodebuild exits.
        let port: UInt16 = 45905
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profiles.json")
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["FJARRCONNECT_TEST_PROFILE_PATH"] = file.path
        app.launchEnvironment["FJARRCONNECT_DISABLE_DISCOVERY"] = "1"
        app.launch(); defer { app.terminate() }
        let search = app.buttons["network.scan"]
        XCTAssertTrue(search.waitForExistence(timeout: 15)); search.click()
        let range = app.textFields["scan.range"]
        XCTAssertTrue(range.waitForExistence(timeout: 5))
        func replace(_ field: XCUIElement, with value: String) {
            field.click(); field.typeKey("a", modifierFlags: .command); field.typeText(value)
        }
        replace(range, with: "0.0.0.0/0")
        XCTAssertFalse(app.buttons["scan.start"].isEnabled)
        replace(range, with: "127.0.0.1/32")
        app.checkBoxes["scan.enable.rdp"].click()
        app.checkBoxes["scan.enable.ssh"].click()
        replace(app.textFields["scan.ports.vnc"], with: String(port))
        XCTAssertTrue(app.buttons["scan.start"].isEnabled)
        app.buttons["scan.start"].click()
        let result = app.descendants(matching: .any).matching(identifier: "scan.host.vnc.127.0.0.1").firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 8)); result.click()
        XCTAssertTrue(app.buttons["scan.save"].isEnabled)
        capture(app, name: "Verified VNC network search")
        app.buttons["scan.save"].click()
        XCTAssertTrue(app.buttons["connect.127.0.0.1"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.secureTextFields["auth.password"].exists)
        let profiles = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?["host"] as? String, "127.0.0.1")
        XCTAssertEqual(profiles.first?["transport"] as? String, "vnc")
        XCTAssertEqual(profiles.first?["port"] as? Int, Int(port))
    }

    func testSavedProfilesRequireDoubleClickToConnectIncludingFavorites() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profiles.json")
        let profile: [String: Any] = ["id": UUID().uuidString, "name": "Double click host", "transport": "vnc", "host": "test.invalid", "port": 5900]
        try JSONSerialization.data(withJSONObject: [profile]).write(to: file)
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["FJARRCONNECT_TEST_PROFILE_PATH"] = file.path
        app.launchEnvironment["FJARRCONNECT_DISABLE_DISCOVERY"] = "1"
        app.launch()
        defer { app.terminate() }
        let row = app.buttons["connect.Double click host"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.click()
        XCTAssertFalse(app.secureTextFields["auth.password"].waitForExistence(timeout: 1))
        row.doubleClick()
        XCTAssertTrue(app.secureTextFields["auth.password"].waitForExistence(timeout: 5))
        app.buttons["auth.cancel"].click()
        app.buttons["favorite.Double click host"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Favorites"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.secureTextFields["auth.password"].exists)
        row.click()
        XCTAssertFalse(app.secureTextFields["auth.password"].waitForExistence(timeout: 1))
        row.doubleClick()
        XCTAssertTrue(app.secureTextFields["auth.password"].waitForExistence(timeout: 5))
        app.buttons["auth.cancel"].click()
    }

    func testMacScreenSharingCredentialsRequireUsernameAndLockTheMode() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profiles.json")
        let profile: [String: Any] = [
            "id": UUID().uuidString, "name": "Remote Mac", "transport": "vnc",
            "host": "mac.invalid", "port": 5900, "username": "macuser", "macScreenSharing": true
        ]
        try JSONSerialization.data(withJSONObject: [profile]).write(to: file)
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["FJARRCONNECT_TEST_PROFILE_PATH"] = file.path
        app.launchEnvironment["FJARRCONNECT_DISABLE_DISCOVERY"] = "1"
        app.launch()
        defer { app.terminate() }
        let row = app.buttons["connect.Remote Mac"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.doubleClick()
        let username = app.textFields["auth.username"]
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        XCTAssertEqual(username.label, "Username (required)")
        XCTAssertFalse(app.popUpButtons["auth.vncAuthenticationMode"].exists)
        username.click(); username.typeKey("a", modifierFlags: .command); username.typeKey(.delete, modifierFlags: [])
        XCTAssertFalse(app.buttons["auth.connect"].isEnabled)
        username.typeText("macuser")
        XCTAssertTrue(app.buttons["auth.connect"].isEnabled)
        app.buttons["auth.cancel"].click()
    }

    func testLocalizedProfileEditorInEveryLanguage() throws {
        continueAfterFailure = false
        let languages = [
            ("en", "en_US", "Log SSH command names", "Save"),
            ("sv", "sv_SE", "Logga SSH-kommandonamn", "Spara"),
            ("da", "da_DK", "Log SSH-kommandonavne", "Gem"),
            ("nb", "nb_NO", "Logg SSH-kommandonavn", "Lagre"),
            ("de", "de_DE", "SSH-Befehlsnamen protokollieren", "Sichern"),
            ("fi", "fi_FI", "Kirjaa SSH-komentojen nimet", "Tallenna"),
            ("fr", "fr_FR", "Journaliser les noms des commandes SSH", "Enregistrer"),
            ("es", "es_ES", "Registrar nombres de comandos SSH", "Guardar"),
            ("ja", "ja_JP", "SSHコマンド名を記録", "保存")
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = XCUIApplication()
        defer { app.terminate() }
        for (language, locale, logLabel, saveLabel) in languages {
            app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
            app.launchEnvironment["FJARRCONNECT_TEST_PROFILE_PATH"] = directory.appendingPathComponent("profiles.json").path
            app.launchEnvironment["FJARRCONNECT_DISABLE_DISCOVERY"] = "1"
            app.launch()
            XCTAssertTrue(app.buttons["newConnection"].firstMatch.waitForExistence(timeout: 15), language)
            app.buttons["newConnection"].firstMatch.click()
            XCTAssertTrue(app.popUpButtons["profile.transport"].firstMatch.waitForExistence(timeout: 5), language)
            app.popUpButtons["profile.transport"].firstMatch.click()
            app.menuItems["SSH"].firstMatch.click()
            let toggle = app.checkBoxes["profile.sshLogging"].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), language)
            XCTAssertEqual(toggle.label, logLabel, language)
            XCTAssertEqual(app.buttons["profile.save"].firstMatch.label, saveLabel, language)
            XCTAssertTrue(toggle.isHittable, language)
            capture(app, name: "Localized SSH profile — \(language)")
            app.terminate()
        }
    }

    func testSSHLogOptInViewerAndOptOutPersist() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profiles.json")
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["FJARRCONNECT_TEST_PROFILE_PATH"] = file.path
        app.launchEnvironment["FJARRCONNECT_DISABLE_DISCOVERY"] = "1"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["newConnection"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["newConnection"].firstMatch.click()
        let name = app.textFields["profile.name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click(); name.typeText("Audit host")
        app.textFields["profile.host"].firstMatch.click()
        app.textFields["profile.host"].firstMatch.typeText("audit.example")
        app.popUpButtons["profile.transport"].firstMatch.click()
        app.menuItems["SSH"].firstMatch.click()
        let toggle = app.checkBoxes["profile.sshLogging"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let toggleState = (toggle.value as? NSNumber)?.intValue ?? (toggle.value as? String).flatMap(Int.init)
        XCTAssertEqual(toggleState, 0)
        toggle.click()
        capture(app, name: "SSH log opt-in")
        app.buttons["profile.save"].firstMatch.click()
        let row = app.buttons["connect.Audit host"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        XCTAssertEqual(saved.first?["sshCommandLogging"] as? Bool, true)
        row.rightClick()
        app.menuItems["SSH command log"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["No commands logged"].firstMatch.waitForExistence(timeout: 5))
        capture(app, name: "Encrypted SSH log viewer")
        app.buttons["ssh.log.close"].firstMatch.click()
        row.rightClick()
        app.menuItems["Stop command logging"].firstMatch.click()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["connect.Audit host"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["connect.Audit host"].firstMatch.rightClick()
        XCTAssertTrue(app.menuItems["Log SSH command names"].firstMatch.waitForExistence(timeout: 5))
        let disabled = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        XCTAssertNotEqual(disabled.first?["sshCommandLogging"] as? Bool, true)
    }

    func testCreateFavoriteAndPersistAcrossLaunches() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["FJARRCONNECT_TEST_PROFILE_PATH"] = directory.appendingPathComponent("profiles.json").path
        app.launchEnvironment["FJARRCONNECT_DISABLE_DISCOVERY"] = "1"
        addUIInterruptionMonitor(withDescription: "Local network permission") { dialog in
            if dialog.buttons["Allow"].exists { dialog.buttons["Allow"].click(); return true }
            return false
        }
        app.launch()
        XCTAssertTrue(app.buttons["newConnection"].firstMatch.waitForExistence(timeout: 15))
        capture(app, name: "Welcome")
        app.buttons["newConnection"].firstMatch.click()
        let name = app.textFields["profile.name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        name.typeText("Studio Mac")
        // Tab follows the editor's keyboard order and avoids AppKit's flaky
        // hit point calculation for SwiftUI scroll views after interruptions.
        app.typeKey(.tab, modifierFlags: [])
        app.typeText("studio.local")
        let username = app.textFields["profile.username"].firstMatch
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        username.click()
        username.typeText("studio")
        XCTAssertTrue(app.buttons["profile.save"].firstMatch.isEnabled)
        app.buttons["profile.save"].firstMatch.click()
        let favorite = app.buttons["favorite.Studio Mac"].firstMatch
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        favorite.click()
        XCTAssertTrue(app.staticTexts["Favorites"].waitForExistence(timeout: 5))
        capture(app, name: "Saved favorite")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Favorites"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["favorite.Studio Mac"].firstMatch.exists)
        app.buttons["favorite.Studio Mac"].firstMatch.click()
        let removed = NSPredicate(format: "exists == false")
        expectation(for: removed, evaluatedWith: app.staticTexts["Favorites"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["favorite.Studio Mac"].firstMatch.exists)
        app.terminate()
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
