import XCTest
import CryptoKit
@testable import FjarrConnect

final class ConnectionTests: XCTestCase {
    func testWakeOnLANValidatesMACAndBuildsMagicPacket() throws {
        let packet = try XCTUnwrap(WakeOnLAN.magicPacket(mac: "01:23:45:67:89:ab"))
        XCTAssertEqual(packet.count, 102)
        XCTAssertEqual(Array(packet.prefix(6)), Array(repeating: 0xFF, count: 6))
        XCTAssertEqual(Array(packet.suffix(6)), [1, 35, 69, 103, 137, 171])
        XCTAssertNotNil(WakeOnLAN.magicPacket(mac: "01-23-45-67-89-ab"))
        XCTAssertNil(WakeOnLAN.magicPacket(mac: "not-a-mac"))
    }
    func testLegacyProfileDefaultsToNotFavorite() throws {
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111","name":"Studio","transport":"vnc","host":"studio.local","port":5900}
        """
        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: Data(json.utf8))
        XCTAssertFalse(profile.isFavorite)
        XCTAssertFalse(profile.reconnectsAutomatically)
    }

    func testAutomaticReconnectPreferencePersistsWithoutCredentials() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(fileURL: directory.appendingPathComponent("profiles.json"))
        var profile = ConnectionProfile(name: "Studio", host: "studio.local")
        profile.reconnectsAutomatically = true
        try store.save(profile, password: nil)
        XCTAssertTrue(try XCTUnwrap(ProfileStore(fileURL: directory.appendingPathComponent("profiles.json")).profiles.first).reconnectsAutomatically)
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
        let defaultVNC = ConnectionURI.profile(from: " studio.local ")
        XCTAssertEqual(defaultVNC?.port, 5900)
        XCTAssertTrue(defaultVNC?.usesMacScreenSharingAuthentication == true)
        XCTAssertFalse(defaultVNC?.isValid ?? true, "Mac Screen Sharing needs a username")
        XCTAssertEqual(ConnectionURI.profile(from: "ssh://user@host")?.port, 22)
        XCTAssertEqual(ConnectionURI.profile(from: "RDP://host:3390")?.transport, .rdp)
        let explicitVNC = ConnectionURI.profile(from: "vnc://host:65535")
        XCTAssertEqual(explicitVNC?.port, 65535)
        XCTAssertTrue(explicitVNC?.usesMacScreenSharingAuthentication == true)
        XCTAssertEqual(ConnectionURI.profile(from: "vnc://account@host")?.username, "account")
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
        var profile = ConnectionProfile(name: "test", transport: .ssh, host: "host", username: "name;echo example")
        profile.ssh = SSHOptions(startCommand: "uptime && whoami")
        let args = SSHArguments.make(profile)
        XCTAssertEqual(Array(args.suffix(3)), ["--", "host", "uptime && whoami"])
        XCTAssertTrue(args.contains("name;echo example"))
        XCTAssertTrue(args.contains("StrictHostKeyChecking=ask"))
        profile.ssh?.startCommand = "line one\nline two"
        XCTAssertFalse(profile.isValid)
        profile.ssh?.startCommand = "uptime"
        profile.logsSSHCommands = true
        XCTAssertFalse(profile.isValid)
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

    func testBiometricProfileLockPersistsAndDefaultsOff() throws {
        let legacy = try JSONDecoder().decode(ConnectionProfile.self, from: Data("""
        {"id":"11111111-1111-1111-1111-111111111111","name":"Studio","transport":"rdp","host":"studio.local","port":3389}
        """.utf8))
        XCTAssertFalse(legacy.requiresBiometricUnlock)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(fileURL: directory.appendingPathComponent("profiles.json"))
        var protected = ConnectionProfile(name: "Locked", transport: .rdp, host: "locked.local")
        protected.requiresBiometricUnlock = true
        try store.save(protected, password: nil)
        XCTAssertTrue(try XCTUnwrap(ProfileStore(fileURL: directory.appendingPathComponent("profiles.json")).profiles.first).requiresBiometricUnlock)
    }

    func testEncryptedProfileTransferExcludesCredentialsAndImportsNewIdentities() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ProfileStore(fileURL: directory.appendingPathComponent("source.json"))
        let profile = ConnectionProfile(name: "Private desktop", transport: .rdp, host: "private.example", username: "admin")
        try source.save(profile, password: nil)
        let exported = try source.encryptedExport(passphrase: "fixture-export-passphrase")
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        XCTAssertEqual(envelope["version"] as? Int, 2)
        XCTAssertEqual(envelope["iterations"] as? Int, 600_000)
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

    func testProfileTransferPBKDF2MatchesKnownSHA256Vector() throws {
        let key = try ProfileStore.pbkdf2Key(passphrase: "password", salt: Data("salt".utf8), iterations: 1)
        let expected: [UInt8] = [
            0x12, 0x0f, 0xb6, 0xcf, 0xfc, 0xf8, 0xb3, 0x2c,
            0x43, 0xe7, 0x22, 0x52, 0x56, 0xc4, 0xf8, 0x37,
            0xa8, 0x65, 0x48, 0xc9, 0x2c, 0xcc, 0x35, 0x48,
            0x08, 0x05, 0x98, 0x7c, 0xb7, 0x0b, 0xe1, 0x7b
        ]
        XCTAssertEqual(key.withUnsafeBytes { Array($0) }, expected)
    }

    func testBoundedProfileFileReaderAllowsLimitAndRejectsExcess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("transfer.bin")
        try Data(repeating: 0x5a, count: 4).write(to: file)
        XCTAssertEqual(try ProfileStore.readBoundedFile(at: file, maximumBytes: 4), Data(repeating: 0x5a, count: 4))
        try Data(repeating: 0x5a, count: 5).write(to: file)
        XCTAssertThrowsError(try ProfileStore.readBoundedFile(at: file, maximumBytes: 4)) { error in
            guard case ProfileTransferError.unsupportedFormat = error else {
                return XCTFail("Expected over-limit file to be rejected")
            }
        }
        for invalidLimit in [-1, Int.max] {
            XCTAssertThrowsError(try ProfileStore.readBoundedFile(at: file, maximumBytes: invalidLimit))
        }
    }

    func testLegacyEncryptedProfileTransferStillImportsAndOversizedInputIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = ConnectionProfile(name: "Legacy desktop", host: "legacy.local")
        let passphrase = "legacy-transfer-test"
        let plaintext = try JSONEncoder().encode([profile])
        let salt = Data((0..<16).map(UInt8.init))
        var material = salt
        material.append(Data(passphrase.utf8))
        var digest = Data(SHA256.hash(data: material))
        let iterations = 120_000
        for _ in 1..<iterations {
            var round = digest
            round.append(material)
            digest = Data(SHA256.hash(data: round))
        }
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: digest))
        let legacy = try JSONEncoder().encode(LegacyEncryptedProfileTransfer(
            version: 1, iterations: iterations, salt: salt, ciphertext: try XCTUnwrap(sealed.combined)))
        let destination = ProfileStore(fileURL: directory.appendingPathComponent("profiles.json"))
        XCTAssertEqual(try destination.importEncryptedProfiles(legacy, passphrase: passphrase), 1)
        XCTAssertEqual(destination.profiles.first?.host, profile.host)
        XCTAssertNotEqual(destination.profiles.first?.id, profile.id)

        let tooLarge = Data(repeating: 0, count: ProfileStore.maximumProfileTransferBytes + 1)
        XCTAssertThrowsError(try destination.importEncryptedProfiles(tooLarge, passphrase: passphrase)) { error in
            guard case ProfileTransferError.unsupportedFormat = error else {
                return XCTFail("Expected oversized transfer to be rejected before decoding")
            }
        }
        XCTAssertEqual(destination.profiles.count, 1)
    }

    func testCommonRDPAndVNCFilesImportOnlyConnectionFields() throws {
        XCTAssertNotNil(ConnectionURI.profile(from: "rdp://desktop.local:3390"))
        let rdp = Data("""
        full address:s:desktop.local:3390
        username:s:DOMAIN\\admin
        password 51:b:secret
        """.utf8)
        let importedRDP = try XCTUnwrap(ExternalProfileImporter.profile(data: rdp, fileExtension: "rdp"))
        XCTAssertEqual(importedRDP.transport, .rdp)
        XCTAssertEqual(importedRDP.host, "desktop.local")
        XCTAssertEqual(importedRDP.port, 3390)
        XCTAssertEqual(importedRDP.username, "DOMAIN\\admin")

        let vnc = Data("""
        [Connection]
        Host=screen.local
        Port=5901
        Username=operator
        Password=secret
        """.utf8)
        let importedVNC = try XCTUnwrap(ExternalProfileImporter.profile(data: vnc, fileExtension: "vnc"))
        XCTAssertEqual(importedVNC.transport, .vnc)
        XCTAssertEqual(importedVNC.host, "screen.local")
        XCTAssertEqual(importedVNC.port, 5901)
        XCTAssertEqual(importedVNC.username, "operator")
        XCTAssertNil(ExternalProfileImporter.profile(data: Data("Password=secret".utf8), fileExtension: "vnc"))
    }
}

private struct LegacyEncryptedProfileTransfer: Encodable {
    let version: Int
    let iterations: Int
    let salt: Data
    let ciphertext: Data
}
