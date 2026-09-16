import XCTest

final class ConnectionUITests: XCTestCase {
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
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.click()
        capture(app, name: "SSH log opt-in")
        app.buttons["profile.save"].firstMatch.click()
        let row = app.staticTexts["Audit host"].firstMatch
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
        XCTAssertTrue(app.staticTexts["Audit host"].firstMatch.waitForExistence(timeout: 15))
        app.staticTexts["Audit host"].firstMatch.rightClick()
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
        name.click()
        name.typeText("Studio Mac")
        app.textFields["profile.host"].firstMatch.click()
        app.textFields["profile.host"].firstMatch.typeText("studio.local")
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
