import XCTest

final class ConnectionUITests: XCTestCase {
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
        XCTAssertEqual(username.placeholderValue, "Username (required)")
        XCTAssertFalse(app.buttons["profile.save"].isEnabled)
        username.click(); username.typeText("macuser")
        XCTAssertTrue(app.buttons["profile.save"].isEnabled)
        app.buttons["profile.save"].click()
        let profiles = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        XCTAssertEqual(profiles.first?["username"] as? String, "macuser")
        XCTAssertEqual(profiles.first?["macScreenSharing"] as? Bool, true)
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
        XCTAssertEqual(username.placeholderValue, "Username")
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

    func testMacScreenSharingCredentialsMarkUsernameAsRequired() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profiles.json")
        let profile: [String: Any] = [
            "id": UUID().uuidString, "name": "Remote Mac", "transport": "vnc",
            "host": "mac.invalid", "port": 5900, "macScreenSharing": true
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
        XCTAssertEqual(username.placeholderValue, "Username (required)")
        XCTAssertFalse(app.buttons["auth.connect"].isEnabled)
        username.click(); username.typeText("macuser")
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
