import XCTest
import SwiftTerm
import Combine
import Darwin
@testable import FjarrConnect

final class SFTPIntegrationTests: XCTestCase {
    func testAuthenticatedSessionsTransferIndependentlyAcrossTabChanges() throws {
        let server = try SFTPServerFixture()
        defer { server.close() }
        var sessions: [SFTPRemoteSession] = []
        let manager = ConnectionManager { profile, _ in
            let session = SFTPRemoteSession(profile: profile, sshConfiguration: server.clientConfiguration)
            sessions.append(session)
            return session
        }
        defer { manager.disconnectAll() }
        manager.connect(server.profile(name: "First files"))
        manager.connect(server.profile(name: "Second files"))
        XCTAssertEqual(manager.tabs.count, 2)
        try waitUntil { sessions.count == 2 && sessions.allSatisfy { $0.status == .connected } }
        XCTAssertEqual(URL(fileURLWithPath: sessions[0].directory).resolvingSymlinksInPath().path, server.remote.resolvingSymlinksInPath().path)
        manager.selectedID = manager.tabs[0].id
        let bytes = Data((0..<160_000).map { UInt8($0 % 251) })
        let source = server.directory.appendingPathComponent("日本語 å ; $ ' upload.bin")
        try bytes.write(to: source)
        sessions[0].upload([(source, false)])
        XCTAssertTrue(sessions[0].busy)
        manager.selectedID = manager.tabs[1].id
        try waitUntil { !sessions[0].busy }
        XCTAssertNil(sessions[0].errorMessage)
        XCTAssertEqual(sessions[0].transferred, UInt64(bytes.count))
        XCTAssertEqual(try Data(contentsOf: server.remote.appendingPathComponent(source.lastPathComponent)), bytes)
        sessions[1].browse(server.remote.path)
        try waitUntil { !sessions[1].busy }
        let entry = try XCTUnwrap(sessions[1].entries.first { $0.name == source.lastPathComponent })
        let copy = server.directory.appendingPathComponent("download.bin")
        sessions[1].download(entry, to: copy, overwrite: false)
        try waitUntil { !sessions[1].busy }
        XCTAssertNil(sessions[1].errorMessage)
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
        manager.close(manager.tabs[0].id)
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(sessions[1].status, .connected)
        sessions[1].rename(entry, to: "renamed.bin")
        try waitUntil { !sessions[1].busy }
        let renamed = try XCTUnwrap(sessions[1].entries.first { $0.name == "renamed.bin" })
        sessions[1].remove(renamed)
        try waitUntil { !sessions[1].busy }
        XCTAssertTrue(sessions[1].entries.isEmpty)
        XCTAssertNil(sessions[1].errorMessage)
    }

    func testEncryptedIdentityAuthenticatesInTerminalWithoutEchoingPassphrase() throws {
        let passphrase = UUID().uuidString
        let server = try SFTPServerFixture(passphrase: passphrase)
        defer { server.close() }
        let session = SFTPRemoteSession(profile: server.profile(name: "Encrypted identity"), sshConfiguration: server.clientConfiguration)
        defer { session.stop() }
        session.start()
        let terminal = try XCTUnwrap(session.terminal)
        try waitUntil { String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("Enter passphrase for key") }
        terminal.process.send(data: Array((passphrase + "\r").utf8)[...])
        try waitUntil { session.status == .connected }
        XCTAssertFalse(String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains(passphrase))
        session.makeDirectory("test folder 日本語")
        try waitUntil { !session.busy }
        let folder = try XCTUnwrap(session.entries.first { $0.name == "test folder 日本語" })
        XCTAssertTrue(folder.isDirectory)
        session.remove(folder)
        try waitUntil { !session.busy }
        XCTAssertNil(session.errorMessage)
    }

    func testClosingTransferPreservesDestinationAndOtherSession() throws {
        try interruptTransfer(closeSession: true)
    }
    func testCancellingTransferKeepsAuthenticationAndOtherSession() throws {
        try interruptTransfer(closeSession: false)
    }

    func testCancelledUploadResumesAfterTheSFTPChannelRecovers() throws {
        let server = try SFTPServerFixture()
        defer { server.close() }
        let session = SFTPRemoteSession(profile: server.profile(name: "Resume files"), sshConfiguration: server.clientConfiguration)
        defer { session.stop() }
        session.start()
        try waitUntil { session.status == .connected }
        let authenticatedTerminal = session.terminal
        let source = server.directory.appendingPathComponent("resume.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 256 * 1024 * 1024)
        try handle.close()
        var cancelled = false
        let observation = session.$transferred.sink { count in
            if count > 0 && !cancelled {
                cancelled = true
                session.cancelTransfer()
            }
        }
        session.upload([(source, false)])
        try waitUntil { cancelled && !session.busy }
        withExtendedLifetime(observation) {}
        XCTAssertEqual(session.status, .connected)
        XCTAssertTrue(session.terminal === authenticatedTerminal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: SFTPClient.uploadStagingPath(server.remote.appendingPathComponent(source.lastPathComponent).path)))

        session.upload([(source, false)])
        // A resumed upload can finish between two main-queue observations on an
        // Intel runner. Wait for its observable result instead of requiring that
        // transient busy state to be sampled.
        let staging = SFTPClient.uploadStagingPath(server.remote.appendingPathComponent(source.lastPathComponent).path)
        try waitUntil { !session.busy && session.transferred == 256 * 1024 * 1024 && !FileManager.default.fileExists(atPath: staging) }
        XCTAssertNil(session.errorMessage)
        XCTAssertEqual(session.transferred, 256 * 1024 * 1024)
        let final = server.remote.appendingPathComponent(source.lastPathComponent)
        let attributes = try FileManager.default.attributesOfItem(atPath: final.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.uint64Value, 256 * 1024 * 1024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging))
    }

    private func interruptTransfer(closeSession: Bool) throws {
        let passphrase = closeSession ? "" : UUID().uuidString
        let server = try SFTPServerFixture(passphrase: passphrase)
        defer { server.close() }
        let first = SFTPRemoteSession(profile: server.profile(name: "Transfer"), sshConfiguration: server.clientConfiguration)
        let second = SFTPRemoteSession(profile: server.profile(name: "Other files"), sshConfiguration: server.clientConfiguration)
        defer { first.stop(); second.stop() }
        first.start(); second.start()
        if !passphrase.isEmpty {
            for session in [first, second] {
                let terminal = try XCTUnwrap(session.terminal)
                try waitUntil { String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("Enter passphrase for key") }
                terminal.process.send(data: Array((passphrase + "\r").utf8)[...])
            }
        }
        try waitUntil { first.status == .connected && second.status == .connected }
        let authenticatedTerminal = first.terminal
        let source = server.directory.appendingPathComponent("large.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        // Sparse input avoids allocating a large test buffer. Stop on the first
        // reported transfer progress, well before the destination can be replaced.
        try handle.truncate(atOffset: 256 * 1024 * 1024); try handle.close()
        let original = server.remote.appendingPathComponent("large.bin")
        let bytes = Data("keep the existing destination".utf8)
        try bytes.write(to: original)
        var cancelled = false
        let observation = first.$transferred.sink { count in
            if count > 0 && !cancelled {
                cancelled = true
                if closeSession { first.stop() } else { first.cancelTransfer() }
            }
        }
        first.upload([(source, true)])
        try waitUntil { cancelled && !first.busy }
        withExtendedLifetime(observation) {}
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        if closeSession { XCTAssertTrue(first.status.isFinished) }
        else {
            XCTAssertEqual(first.status, .connected)
            XCTAssertTrue(first.terminal === authenticatedTerminal)
            XCTAssertFalse(first.recoveringTransfer)
            first.makeDirectory("after cancellation")
            try waitUntil { !first.busy }
            XCTAssertTrue(first.entries.contains { $0.name == "after cancellation" && $0.isDirectory })
            XCTAssertNil(first.errorMessage)
        }
        XCTAssertEqual(second.status, .connected)
        second.makeDirectory("still connected")
        try waitUntil { !second.busy }
        XCTAssertTrue(second.entries.contains { $0.name == "still connected" && $0.isDirectory })
        XCTAssertNil(second.errorMessage)
    }

    func testRejectingUnknownHostDoesNotAuthenticateOrSaveItsKey() throws {
        let server = try SFTPServerFixture()
        defer { server.close() }
        let knownHosts = server.directory.appendingPathComponent("known_hosts")
        try Data().write(to: knownHosts)
        let session = SFTPRemoteSession(profile: server.profile(name: "Unknown host"), sshConfiguration: server.clientConfiguration)
        defer { session.stop() }
        session.start()
        let terminal = try XCTUnwrap(session.terminal)
        try waitUntil { String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("Are you sure you want to continue connecting") }
        terminal.process.send(data: Array("no\r".utf8)[...])
        try waitUntil { session.status.isFinished }
        XCTAssertTrue(try Data(contentsOf: knownHosts).isEmpty)
        XCTAssertTrue(session.entries.isEmpty)
        XCTAssertNotNil(session.status.error)
    }

    func testCancelledDownloadResumesWithoutReplacingTheLocalFileEarly() throws {
        let server = try SFTPServerFixture()
        defer { server.close() }
        let source = server.remote.appendingPathComponent("large download.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 256 * 1024 * 1024); try handle.close()
        let destination = server.directory.appendingPathComponent("keep.bin")
        let original = Data("keep the local destination".utf8)
        try original.write(to: destination)
        let session = SFTPRemoteSession(profile: server.profile(name: "Download"), sshConfiguration: server.clientConfiguration)
        defer { session.stop() }
        session.start()
        try waitUntil { session.status == .connected }
        let entry = try XCTUnwrap(session.entries.first { $0.name == source.lastPathComponent })
        var cancelled = false
        let observation = session.$transferred.sink { count in
            if count > 0 && !cancelled { cancelled = true; session.cancelTransfer() }
        }
        session.download(entry, to: destination, overwrite: true)
        try waitUntil { cancelled && !session.busy }
        withExtendedLifetime(observation) {}
        XCTAssertEqual(session.status, .connected)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        let staging = SFTPClient.downloadStagingPath(destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertGreaterThan(try staging.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 0)
        session.download(entry, to: destination, overwrite: true)
        try waitUntil { session.busy }
        try waitUntil { !session.busy }
        XCTAssertEqual(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize, 256 * 1024 * 1024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertNil(session.errorMessage)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) throws {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        guard XCTWaiter.wait(for: [done], timeout: 12) == .completed else {
            XCTFail("SFTP operation did not reach the expected state")
            throw SFTPFailure.timeout
        }
    }
}

/// A real, unprivileged OpenSSH server restricted to loopback and a disposable
/// generated key. No user SSH settings, authorized_keys or known_hosts are changed.
private final class SFTPServerFixture {
    let directory: URL
    let remote: URL
    let clientConfiguration: URL
    private let process = Process()
    private let port: UInt16

    init(passphrase: String = "") throws {
        directory = URL(fileURLWithPath: "/tmp/fjarr-sftp-test-" + UUID().uuidString)
        remote = directory.appendingPathComponent("remote")
        clientConfiguration = directory.appendingPathComponent("ssh.conf")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        port = try Self.unusedPort()
        do {
            for (name, phrase) in [("host", ""), ("client", passphrase)] {
                try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", phrase, "-f", directory.appendingPathComponent(name).path])
            }
            let key = try String(contentsOf: directory.appendingPathComponent("host.pub"), encoding: .utf8)
            try "[127.0.0.1]:\(port) \(key)".write(to: directory.appendingPathComponent("known_hosts"), atomically: true, encoding: .utf8)
            let serverConfiguration = directory.appendingPathComponent("sshd.conf")
            try """
            Port \(port)
            ListenAddress 127.0.0.1
            HostKey \(directory.path)/host
            PidFile \(directory.path)/pid
            AuthorizedKeysFile \(directory.path)/client.pub
            StrictModes no
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            UsePAM no
            PermitRootLogin no
            AllowUsers \(NSUserName())
            Subsystem sftp internal-sftp
            LogLevel ERROR
            """.appending("\n").write(to: serverConfiguration, atomically: true, encoding: .utf8)
            try """
            Host *
                UserKnownHostsFile \(directory.path)/known_hosts
                GlobalKnownHostsFile /dev/null
                IdentityAgent none
                IdentitiesOnly yes
                AddKeysToAgent no
                IdentityFile \(directory.path)/client
                PreferredAuthentications publickey
            """.appending("\n").write(to: clientConfiguration, atomically: true, encoding: .utf8)
            try Self.run("/usr/sbin/sshd", ["-t", "-f", serverConfiguration.path])
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
            process.arguments = ["-D", "-e", "-f", serverConfiguration.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while true {
                guard process.isRunning else { throw SFTPFailure.disconnected }
                do { try Self.run("/usr/bin/nc", ["-z", "-w", "1", "127.0.0.1", String(port)]); break }
                catch {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw error }
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
        } catch {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: directory); throw error
        }
    }
    func profile(name: String) -> ConnectionProfile {
        var profile = ConnectionProfile(name: name, transport: .sftp, host: "127.0.0.1", port: port, username: NSUserName())
        profile.ssh = SSHOptions(startDirectory: remote.path)
        return profile
    }
    func close() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: directory)
    }
    deinit { close() }
    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SFTPFailure.disconnected }
    }
    private static func unusedPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SFTPFailure.disconnected }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { throw SFTPFailure.disconnected }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard status == 0 else { throw SFTPFailure.disconnected }
        return UInt16(bigEndian: address.sin_port)
    }
}
