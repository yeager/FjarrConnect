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
        app.launch()
        XCTAssertTrue(app.buttons["newConnection"].waitForExistence(timeout: 15))
        capture(app, name: "Welcome")
        app.buttons["newConnection"].click()
        let name = app.textFields["profile.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("Studio Mac")
        app.textFields["profile.host"].click()
        app.textFields["profile.host"].typeText("studio.local")
        XCTAssertTrue(app.buttons["profile.save"].isEnabled)
        app.buttons["profile.save"].click()
        let favorite = app.buttons["favorite.Studio Mac"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        favorite.click()
        XCTAssertTrue(app.staticTexts["Favorites"].waitForExistence(timeout: 5))
        capture(app, name: "Saved favorite")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Favorites"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["favorite.Studio Mac"].exists)
        app.buttons["favorite.Studio Mac"].click()
        let removed = NSPredicate(format: "exists == false")
        expectation(for: removed, evaluatedWith: app.staticTexts["Favorites"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["favorite.Studio Mac"].exists)
        app.terminate()
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
