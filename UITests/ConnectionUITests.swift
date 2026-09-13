import XCTest

final class ConnectionUITests: XCTestCase {
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
