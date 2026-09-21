import XCTest

final class SFTPBrowserUITests: XCTestCase {
    func testFileSelectionNavigationPickersAndCloseConfirmation() throws {
        continueAfterFailure = false
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "/tmp/fjarrconnect-sftp-ui-fixture.json"))) as? [String: Any])
        let root = URL(fileURLWithPath: try XCTUnwrap(fixture["directory"] as? String))
        let remote = try XCTUnwrap(fixture["remote"] as? String)
        let source = URL(fileURLWithPath: try XCTUnwrap(fixture["upload"] as? String))
        let downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let profiles = root.appendingPathComponent("profiles.json")
        let profile: [String: Any] = [
            "id": UUID().uuidString, "name": "UI files", "transport": "sftp", "host": "127.0.0.1",
            "port": try XCTUnwrap(fixture["port"] as? Int), "username": try XCTUnwrap(fixture["username"] as? String),
            "ssh": ["startDirectory": remote]
        ]
        try JSONSerialization.data(withJSONObject: [profile]).write(to: profiles)
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["FJARRCONNECT_TEST_PROFILE_PATH"] = profiles.path
        app.launchEnvironment["FJARRCONNECT_DISABLE_DISCOVERY"] = "1"
        app.launchEnvironment["FJARRCONNECT_TEST_SSH_CONFIG"] = try XCTUnwrap(fixture["configuration"] as? String)
        app.launch(); defer { app.terminate() }
        let profileRow = app.buttons["connect.UI files"].firstMatch
        XCTAssertTrue(profileRow.waitForExistence(timeout: 15)); profileRow.doubleClick()
        let first = entry("first.txt", in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 12))
        let download = app.buttons["files.download"]
        XCTAssertFalse(download.isEnabled)
        first.click()
        XCTAssertTrue(download.isEnabled)
        XCTAssertEqual(app.textFields["files.path"].value as? String, URL(fileURLWithPath: remote).resolvingSymlinksInPath().path)

        entry("folder", in: app).doubleClick()
        XCTAssertTrue(entry("nested.txt", in: app).waitForExistence(timeout: 8))
        XCTAssertFalse(first.exists)
        XCTAssertFalse(download.isEnabled)
        app.buttons["files.parent"].click()
        XCTAssertTrue(first.waitForExistence(timeout: 8))

        first.rightClick()
        app.menuItems["Rename…"].click()
        let name = app.textFields["files.itemName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click(); name.typeKey("a", modifierFlags: .command); name.typeText("renamed.txt")
        app.buttons["OK"].firstMatch.click()
        XCTAssertTrue(entry("renamed.txt", in: app).waitForExistence(timeout: 8))
        XCTAssertFalse(first.exists)

        app.buttons["files.upload"].click()
        choose(path: source.path, confirm: "Open", in: app)
        let uploaded = entry(source.lastPathComponent, in: app)
        XCTAssertTrue(uploaded.waitForExistence(timeout: 8))
        let bytes = try Data(contentsOf: source)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: remote).appendingPathComponent(source.lastPathComponent)), bytes)
        uploaded.click()
        XCTAssertTrue(download.isEnabled); download.click()
        choose(path: downloads.path, confirm: "Save", in: app)
        let saved = downloads.appendingPathComponent(source.lastPathComponent)
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? Data(contentsOf: saved)) == bytes
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 8), .completed)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "SFTP real server: selected file after round-trip transfer"
        attachment.lifetime = .keepAlways; add(attachment)

        uploaded.rightClick(); app.menuItems["Delete"].click()
        XCTAssertTrue(app.buttons["OK"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["OK"].firstMatch.click()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !FileManager.default.fileExists(atPath: URL(fileURLWithPath: remote).appendingPathComponent(source.lastPathComponent).path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 8), .completed)

        app.buttons["Disconnect"].click()
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(entry("renamed.txt", in: app).exists)
        app.buttons["files.refresh"].click()
        XCTAssertTrue(entry("renamed.txt", in: app).waitForExistence(timeout: 8))
        app.buttons["Disconnect"].click()
        XCTAssertTrue(app.buttons["Close sessions"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Close sessions"].firstMatch.click()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.tables["files.table"])
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
    }

    private func entry(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "files.entry.\(name)").firstMatch
    }

    private func choose(path: String, confirm: String, in app: XCUIApplication) {
        // Use the real standard file panel and its Go to Folder command.
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(path)
        app.typeKey(.return, modifierFlags: [])
        let button = app.buttons[confirm].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5)); button.click()
    }
}
