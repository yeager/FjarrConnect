import XCTest
import CryptoKit
@testable import FjarrConnect

final class SSHCommandLogTests: XCTestCase {
    func testLoggingIsOptInAndPersistsPerProfile() throws {
        let json = #"{"id":"11111111-1111-1111-1111-111111111111","name":"Legacy","transport":"ssh","host":"host","port":22}"#
        XCTAssertFalse(try JSONDecoder().decode(ConnectionProfile.self, from: Data(json.utf8)).logsSSHCommands)
        var profile = ConnectionProfile(name: "SSH", transport: .ssh, host: "host", logsSSHCommands: true)
        XCTAssertTrue(try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(profile)).logsSSHCommands)
        profile.transport = .vnc
        XCTAssertFalse(profile.logsSSHCommands)
        XCTAssertFalse(ConnectionProfile(name: "Other", transport: .ssh, host: "other").logsSSHCommands)
    }

    func testOnlyFixedCommandLabelsCanReachStorage() throws {
        func event(_ value: String) -> SSHCommandLogging.Event? { SSHCommandLogging.event(Array(value.utf8)[...]) }
        XCTAssertEqual(event("fc1;command;ls"), .command("ls"))
        XCTAssertEqual(event("fc1;command;other"), .command("other"))
        for text in ["fixture-private-value", "fc1;command;echo fixture-private-value", "fc1;command;ls\npassword", "fc1;command;", String(repeating: "x", count: 1000)] {
            XCTAssertNil(event(text))
        }
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try store.append(command: "fixture-private-value", for: UUID()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testOptOutIgnoresEventsAndDisablingStopsActiveSessionLogging() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let offProfile = ConnectionProfile(name: "Off", transport: .ssh, host: "off")
        let off = SSHRemoteSession(profile: offProfile, password: nil, logStore: store)
        off.receiveLogEvent(.ready)
        off.receiveLogEvent(.command("ls"))
        off.updateLoggingPreference(true) // Requires a new connection with shell integration.
        off.receiveLogEvent(.ready)
        off.receiveLogEvent(.command("pwd"))
        off.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let profile = ConnectionProfile(name: "On", transport: .ssh, host: "on", logsSSHCommands: true)
        let on = SSHRemoteSession(profile: profile, password: nil, logStore: store)
        on.receiveLogEvent(.command("echo")) // Ignore commands before the shell announces readiness.
        on.receiveLogEvent(.ready)
        on.receiveLogEvent(.command("pwd"))
        on.updateLoggingPreference(false)
        on.receiveLogEvent(.command("printf"))
        on.stop()
        XCTAssertEqual(try store.entries(for: profile.id).map(\.command), ["pwd"])
        XCTAssertTrue(try store.entries(for: offProfile.id).isEmpty)
    }

    func testEncryptionTamperProtectionAndHostSeparation() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), other = UUID()
        try store.append(command: "systemctl", for: id)
        let file = directory.appendingPathComponent(id.uuidString + ".sealed")
        let data = try Data(contentsOf: file)
        XCTAssertFalse(data.range(of: Data("systemctl".utf8)) != nil)
        XCTAssertEqual(try store.entries(for: id).map(\.command), ["systemctl"])
        XCTAssertTrue(try store.entries(for: other).isEmpty)
        try data.write(to: directory.appendingPathComponent(other.uuidString + ".sealed"))
        XCTAssertThrowsError(try store.entries(for: other), "Authenticated data must bind ciphertext to its profile")
        var tampered = data
        tampered[tampered.count - 1] ^= 1
        try tampered.write(to: file)
        XCTAssertThrowsError(try store.entries(for: id))
        XCTAssertThrowsError(try store.append(command: "ls", for: id))
        XCTAssertEqual(try Data(contentsOf: file), tampered, "Corrupt history must not be silently overwritten")
    }

    func testPermissionsRetentionAndDeletion() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), now = Date()
        try store.append(command: "ls", for: id, now: now.addingTimeInterval(-SSHCommandLogStore.maximumAge - 1))
        try store.append(command: "pwd", for: id, now: now)
        XCTAssertEqual(try store.entries(for: id, now: now).map(\.command), ["pwd"])
        for _ in 0..<SSHCommandLogStore.maximumEntries { try store.append(command: "ls", for: id, now: now) }
        let entries = try store.entries(for: id, now: now)
        XCTAssertEqual(entries.count, SSHCommandLogStore.maximumEntries)
        XCTAssertFalse(entries.contains { $0.command == "pwd" })
        let file = directory.appendingPathComponent(id.uuidString + ".sealed")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertTrue(try store.entries(for: id, now: now.addingTimeInterval(SSHCommandLogStore.maximumAge + 1)).isEmpty)
        try store.clear(for: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testMissingKeyNeverCreatesPlaintextOrReplacesOldHistory() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        try store.append(command: "ls", for: id)
        let file = directory.appendingPathComponent(id.uuidString + ".sealed")
        let original = try Data(contentsOf: file)
        let locked = SSHCommandLogStore(directory: directory, key: { _, _ in nil }, deleteKey: { _ in })
        XCTAssertThrowsError(try locked.append(command: "pwd", for: id))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertThrowsError(try locked.append(command: "pwd", for: UUID()))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    func testKeychainRoundTripAndDeletion() throws {
        let id = UUID()
        defer { try? SSHLogKeychain.delete(id) }
        XCTAssertNil(try SSHLogKeychain.key(id, create: false))
        let first = try XCTUnwrap(SSHLogKeychain.key(id, create: true))
        XCTAssertEqual(first.bitCount, 256)
        let sealed = try AES.GCM.seal(Data("fixture".utf8), using: first)
        let reloaded = try XCTUnwrap(SSHLogKeychain.key(id, create: false))
        XCTAssertEqual(try AES.GCM.open(sealed, using: reloaded), Data("fixture".utf8))
        try SSHLogKeychain.delete(id)
        XCTAssertNil(try SSHLogKeychain.key(id, create: false))
        let replacement = try XCTUnwrap(SSHLogKeychain.key(id, create: true))
        XCTAssertThrowsError(try AES.GCM.open(sealed, using: replacement))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SSHCommandLogStore(directory: directory)
        try store.append(command: "systemctl", for: id)
        XCTAssertEqual(try store.entries(for: id).map(\.command), ["systemctl"])
        try store.clear(for: id)
        XCTAssertNil(try SSHLogKeychain.key(id, create: false))
    }

    private func temporaryStore() -> (SSHCommandLogStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let key = SymmetricKey(size: .bits256)
        return (SSHCommandLogStore(directory: directory, key: { _, _ in key }, deleteKey: { _ in }), directory)
    }
}
