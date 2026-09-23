import XCTest
@testable import FjarrConnect

final class ConnectionTests: XCTestCase {
    func testLegacyProfileDefaultsToNotFavorite() throws {
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111","name":"Studio","transport":"vnc","host":"studio.local","port":5900}
        """
        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: Data(json.utf8))
        XCTAssertFalse(profile.isFavorite)
    }

    func testFavoritesPersistAndDoNotDuplicateGroupedProfiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profiles.json")
        let store = ProfileStore(fileURL: file)
        let profile = ConnectionProfile(name: "Studio", host: "studio.local")
        try store.save(profile, password: nil)
        try store.toggleFavorite(profile.id)
        XCTAssertEqual(store.favorites.map(\.id), [profile.id])
        XCTAssertTrue(store.grouped.isEmpty)
        let reloaded = ProfileStore(fileURL: file)
        XCTAssertEqual(reloaded.favorites.map(\.id), [profile.id])
        var edited = try XCTUnwrap(reloaded.profiles.first)
        edited.name = "Office"
        try reloaded.save(edited, password: nil)
        XCTAssertTrue(try XCTUnwrap(reloaded.profiles.first).isFavorite)
        try reloaded.toggleFavorite(profile.id)
        XCTAssertTrue(reloaded.favorites.isEmpty)
        XCTAssertEqual(reloaded.grouped.flatMap(\.profiles).map(\.id), [profile.id])
        XCTAssertFalse(try XCTUnwrap(ProfileStore(fileURL: file).profiles.first).isFavorite)
    }

    func testQuickConnectDefaultsAndProtocols() {
        XCTAssertEqual(ConnectionURI.profile(from: " studio.local ")?.port, 5900)
        XCTAssertEqual(ConnectionURI.profile(from: "ssh://user@host")?.port, 22)
        XCTAssertEqual(ConnectionURI.profile(from: "RDP://host:3390")?.transport, .rdp)
        XCTAssertEqual(ConnectionURI.profile(from: "vnc://host:65535")?.port, 65535)
    }
    func testInvalidAddressesDoNotTrapOrSilentlyChangeMeaning() {
        for input in ["", " ", "vnc://host:65536", "vnc://host:0", "vnc://host:-1",
                      "vnc://host:999999999999999999999999", "ftp://host", "vnc://host/path",
                      "vnc://host?password=example", "vnc://host#fragment", "vnc://user:example@host",
                      "vnc://-oProxyCommand=touch", "vnc://a b", "vnc://user%0Aadmin@host"] {
            XCTAssertNil(ConnectionURI.profile(from: input), input)
        }
    }
    func testIPv6AndEscapedUsernameRoundTrip() throws {
        let source = ConnectionProfile(name: "IPv6", transport: .ssh, host: "fe80::1%en0", port: 2222, username: "test@domain")
        let parsed = try XCTUnwrap(ConnectionURI.profile(from: source.uri))
        XCTAssertEqual(parsed.host, source.host)
        XCTAssertEqual(parsed.username, source.username)
        XCTAssertEqual(parsed.port, source.port)
        XCTAssertEqual(ConnectionURI.profile(from: "vnc://[::1]:5901")?.host, "::1")
    }
    func testSSHRetainsAgentAndCommandSearchPath() {
        let environment = SSHArguments.environment(from: ["SSH_AUTH_SOCK": "/tmp/test-agent", "PATH": "/usr/bin:/opt/homebrew/bin"])
        XCTAssertTrue(environment.contains("SSH_AUTH_SOCK=/tmp/test-agent"))
        XCTAssertTrue(environment.contains("PATH=/usr/bin:/opt/homebrew/bin"))
        XCTAssertTrue(environment.contains("TERM=xterm-256color"))
    }

    func testSSHArgumentsKeepUserDataSeparate() {
        let profile = ConnectionProfile(name: "test", transport: .ssh, host: "host", username: "name;echo example")
        let args = SSHArguments.make(profile)
        XCTAssertEqual(Array(args.suffix(2)), ["--", "host"])
        XCTAssertTrue(args.contains("name;echo example"))
        XCTAssertTrue(args.contains("StrictHostKeyChecking=ask"))
    }
    func testRDPCredentialsUsePipeFormatAndRejectLineInjection() throws {
        let profile = ConnectionProfile(name: "test", transport: .rdp, host: "::1", username: "test user")
        let input = try XCTUnwrap(RDPArguments.input(profile: profile, password: "example with spaces"))
        let text = String(decoding: input, as: UTF8.self)
        XCTAssertTrue(text.contains("/v:[::1]:3389\n"))
        XCTAssertTrue(text.contains("/p:example with spaces\n"))
        XCTAssertFalse(text.contains("/cert:ignore"))
        XCTAssertNil(RDPArguments.input(profile: profile, password: "example\n/cert:ignore"))
    }
    func testCorruptProfilesArePreserved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profiles.json")
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: file)
        let store = ProfileStore(fileURL: file)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertThrowsError(try store.save(ConnectionProfile(name: "test", host: "host"), password: nil))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }
    func testSaveReloadAndEditWithoutCredentials() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profiles.json")
        let store = ProfileStore(fileURL: file)
        var profile = ConnectionProfile(name: "Studio", host: "studio.local")
        try store.save(profile, password: nil)
        profile.name = "Office"
        try store.save(profile, password: nil)
        XCTAssertEqual(ProfileStore(fileURL: file).profiles, [profile])
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("password"))
    }

    func testTagsAreNormalizedPersistedAndAvailableForSearch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profiles.json")
        let store = ProfileStore(fileURL: file)
        var profile = ConnectionProfile(name: "Studio", host: "studio.local")
        profile.tags = ["  Production ", "VPN", "Production", ""]
        try store.save(profile, password: nil)

        XCTAssertEqual(profile.normalizedTags, ["Production", "VPN"])
        XCTAssertEqual(try XCTUnwrap(ProfileStore(fileURL: file).profiles.first).normalizedTags, ["Production", "VPN"])
    }

    func testRecentProfilesAreOrderedByMostRecentConnection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(fileURL: directory.appendingPathComponent("profiles.json"))
        let older = ConnectionProfile(name: "Older", host: "older.local")
        let newer = ConnectionProfile(name: "Newer", host: "newer.local")
        try store.save(older, password: nil)
        try store.save(newer, password: nil)

        store.markUsed(older.id, now: Date(timeIntervalSince1970: 1))
        store.markUsed(newer.id, now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(store.recent.map(\.id), [newer.id, older.id])
    }

    func testEncryptedProfileTransferExcludesCredentialsAndImportsNewIdentities() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ProfileStore(fileURL: directory.appendingPathComponent("source.json"))
        let profile = ConnectionProfile(name: "Private desktop", transport: .rdp, host: "private.example", username: "admin")
        try source.save(profile, password: nil)
        let exported = try source.encryptedExport(passphrase: "fixture-export-passphrase")
        let document = String(decoding: exported, as: UTF8.self)
        XCTAssertFalse(document.contains("private.example"))
        XCTAssertFalse(document.contains("admin"))

        let destination = ProfileStore(fileURL: directory.appendingPathComponent("destination.json"))
        XCTAssertThrowsError(try destination.importEncryptedProfiles(exported, passphrase: "incorrect-passphrase"))
        XCTAssertEqual(try destination.importEncryptedProfiles(exported, passphrase: "fixture-export-passphrase"), 1)
        let imported = try XCTUnwrap(destination.profiles.first)
        XCTAssertEqual(imported.host, profile.host)
        XCTAssertEqual(imported.username, profile.username)
        XCTAssertNotEqual(imported.id, profile.id)
    }
}
