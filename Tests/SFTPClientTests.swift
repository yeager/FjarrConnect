import XCTest
@testable import FjarrConnect

final class SFTPClientTests: XCTestCase {
    func testQueuedFileUploadsAcceptOnlyExistingLocalFilesAndDrainOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("report.txt")
        try Data("contents".utf8).write(to: file)
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/report.txt"))
        let session = SFTPRemoteSession(profile: ConnectionProfile(name: "Files", transport: .sftp, host: "files.local"))

        session.enqueueUploads([file, remote, directory.appendingPathComponent("missing.txt")])

        XCTAssertEqual(session.takeQueuedUploads(), [file])
        XCTAssertTrue(session.takeQueuedUploads().isEmpty)
    }

    func testRealSubsystemTransfersUnicodeFilesAndDirectoriesWithoutShellParsing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: false)
        let client = try SFTPClient(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: ["-d", remote.path])
        defer { client.close() }
        XCTAssertEqual(URL(fileURLWithPath: try client.realPath(".")).resolvingSymlinksInPath(), remote.resolvingSymlinksInPath())
        let source = root.appendingPathComponent("日本語 å ; $ ' file.bin")
        let bytes = Data((0..<200_000).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        let target = SFTPClient.join(remote.path, source.lastPathComponent)
        try client.upload(source, to: target)
        let listed = try XCTUnwrap(client.list(remote.path).first)
        XCTAssertEqual(listed.name, source.lastPathComponent)
        XCTAssertEqual(listed.size, UInt64(bytes.count))
        XCTAssertTrue(listed.isRegularFile)
        let downloaded = root.appendingPathComponent("downloaded.bin")
        try client.download(target, to: downloaded)
        XCTAssertEqual(try Data(contentsOf: downloaded), bytes)
        XCTAssertThrowsError(try client.upload(source, to: target))
        try Data("replacement".utf8).write(to: source)
        try client.upload(source, to: target, overwrite: true)
        try client.download(target, to: downloaded, overwrite: true)
        XCTAssertEqual(try Data(contentsOf: downloaded), Data("replacement".utf8))
        try client.rename(target, to: remote.appendingPathComponent("renamed").path)
        XCTAssertNil(try client.stat(target))
        try client.remove(remote.appendingPathComponent("renamed").path, directory: false)
        XCTAssertTrue(try client.list(remote.path).isEmpty)
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try bytes.write(to: folder.appendingPathComponent("nested/å.txt"))
        try client.upload(folder, to: remote.appendingPathComponent("folder").path)
        let copy = root.appendingPathComponent("copy")
        try client.download(remote.appendingPathComponent("folder").path, to: copy)
        XCTAssertEqual(try Data(contentsOf: copy.appendingPathComponent("nested/å.txt")), bytes)
    }

    func testSymbolicLinksAreRejectedAndFailedDownloadsKeepOriginalFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        try Data("preserve".utf8).write(to: original)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let client = try SFTPClient(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: ["-d", root.path])
        defer { client.close() }
        XCTAssertThrowsError(try client.upload(link, to: root.appendingPathComponent("upload").path))
        XCTAssertThrowsError(try client.download(link.path, to: original, overwrite: true))
        XCTAssertEqual(try Data(contentsOf: original), Data("preserve".utf8))
        for name in ["", ".", "..", "../escape", "nul\0name"] { XCTAssertFalse(SFTPClient.safeName(name)) }
        var truncated = SFTPPacket(data: Data([0, 0, 0, 10, 65]))
        XCTAssertThrowsError(try truncated.bytes())
    }

    func testCancelledFileUploadResumesOnlyAfterMatchingTheRemotePartial() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("resumable.bin")
        let bytes = Data((0..<100_000).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        let target = remote.appendingPathComponent(source.lastPathComponent).path
        let staging = SFTPClient.uploadStagingPath(target)

        let first = try SFTPClient(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: ["-d", remote.path])
        first.onProgress = { _ in first.cancel() }
        XCTAssertThrowsError(try first.upload(source, to: target)) { error in
            guard case SFTPFailure.cancelled = error else { return XCTFail("Expected cancellation, got \(error)") }
        }
        first.close()

        let retry = try SFTPClient(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: ["-d", remote.path])
        defer { retry.close() }
        XCTAssertEqual(try retry.stat(staging)?.size, 32_768)
        var reported = UInt64(0)
        retry.onProgress = { reported += $0 }
        try retry.upload(source, to: target)
        XCTAssertEqual(reported, UInt64(bytes.count))
        XCTAssertEqual(try retry.stat(staging), nil)
        let copy = root.appendingPathComponent("copy.bin")
        try retry.download(target, to: copy)
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
    }

    func testCancelledDirectoryUploadResumesValidatedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let firstBytes = Data((0..<100_000).map { UInt8($0 % 251) })
        let secondBytes = Data((0..<40_000).map { UInt8(($0 + 17) % 251) })
        try firstBytes.write(to: source.appendingPathComponent("nested/first.bin"))
        try secondBytes.write(to: source.appendingPathComponent("second.bin"))
        let target = remote.appendingPathComponent(source.lastPathComponent).path
        let staging = SFTPClient.uploadStagingPath(target)

        let first = try SFTPClient(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: ["-d", remote.path])
        first.onProgress = { _ in first.cancel() }
        XCTAssertThrowsError(try first.upload(source, to: target)) { error in
            guard case SFTPFailure.cancelled = error else { return XCTFail("Expected cancellation, got \(error)") }
        }
        first.close()
        let inspector = try SFTPClient(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: ["-d", remote.path])
        XCTAssertEqual(try inspector.stat(staging)?.isDirectory, true)
        inspector.close()

        let retry = try SFTPClient(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: ["-d", remote.path])
        defer { retry.close() }
        var reported = UInt64(0)
        retry.onProgress = { reported += $0 }
        try retry.upload(source, to: target)
        XCTAssertEqual(reported, UInt64(firstBytes.count + secondBytes.count))
        XCTAssertNil(try retry.stat(staging))
        let copy = root.appendingPathComponent("copy")
        try retry.download(target, to: copy)
        XCTAssertEqual(try Data(contentsOf: copy.appendingPathComponent("nested/first.bin")), firstBytes)
        XCTAssertEqual(try Data(contentsOf: copy.appendingPathComponent("second.bin")), secondBytes)
    }

    func testMismatchedStagingFileIsDiscardedBeforeUpload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("source.bin")
        let bytes = Data((0..<65_000).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        let target = remote.appendingPathComponent(source.lastPathComponent).path
        let staging = SFTPClient.uploadStagingPath(target)
        try Data("not the source prefix".utf8).write(to: URL(fileURLWithPath: staging))

        let client = try SFTPClient(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: ["-d", remote.path])
        defer { client.close() }
        var reported = UInt64(0)
        client.onProgress = { reported += $0 }
        try client.upload(source, to: target)
        XCTAssertEqual(reported, UInt64(bytes.count))
        let copy = root.appendingPathComponent("copy.bin")
        try client.download(target, to: copy)
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
    }

    func testCancelledFileDownloadResumesOnlyAfterMatchingTheRemotePartial() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: false)
        let source = remote.appendingPathComponent("download.bin")
        let bytes = Data((0..<100_000).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        let destination = root.appendingPathComponent("download.bin")
        let staging = SFTPClient.downloadStagingPath(destination)

        let first = try SFTPClient(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: ["-d", remote.path])
        first.onProgress = { _ in first.cancel() }
        XCTAssertThrowsError(try first.download(source.path, to: destination)) { error in
            guard case SFTPFailure.cancelled = error else { return XCTFail("Expected cancellation, got \(error)") }
        }
        first.close()
        XCTAssertEqual((try staging.resourceValues(forKeys: [.fileSizeKey])).fileSize, 32_768)

        let retry = try SFTPClient(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: ["-d", remote.path])
        defer { retry.close() }
        var reported = UInt64(0)
        retry.onProgress = { reported += $0 }
        try retry.download(source.path, to: destination)
        XCTAssertEqual(reported, UInt64(bytes.count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testMismatchedDownloadStagingFileIsDiscardedBeforeDownload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: false)
        let source = remote.appendingPathComponent("download.bin")
        let bytes = Data((0..<65_000).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        let destination = root.appendingPathComponent("download.bin")
        let staging = SFTPClient.downloadStagingPath(destination)
        try Data("not the remote prefix".utf8).write(to: staging)

        let client = try SFTPClient(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: ["-d", remote.path])
        defer { client.close() }
        var reported = UInt64(0)
        client.onProgress = { reported += $0 }
        try client.download(source.path, to: destination)
        XCTAssertEqual(reported, UInt64(bytes.count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testCancelledDirectoryDownloadResumesValidatedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote.appendingPathComponent("folder/nested"), withIntermediateDirectories: true)
        let firstBytes = Data((0..<100_000).map { UInt8($0 % 251) })
        let secondBytes = Data((0..<40_000).map { UInt8(($0 + 17) % 251) })
        try firstBytes.write(to: remote.appendingPathComponent("folder/nested/first.bin"))
        try secondBytes.write(to: remote.appendingPathComponent("folder/second.bin"))
        let source = remote.appendingPathComponent("folder")
        let destination = root.appendingPathComponent("copy")
        let staging = SFTPClient.downloadStagingPath(destination)

        let first = try SFTPClient(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: ["-d", remote.path])
        first.onProgress = { _ in first.cancel() }
        XCTAssertThrowsError(try first.download(source.path, to: destination)) { error in
            guard case SFTPFailure.cancelled = error else { return XCTFail("Expected cancellation, got \(error)") }
        }
        first.close()
        XCTAssertEqual((try staging.resourceValues(forKeys: [.isDirectoryKey])).isDirectory, true)

        let retry = try SFTPClient(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: ["-d", remote.path])
        defer { retry.close() }
        var reported = UInt64(0)
        retry.onProgress = { reported += $0 }
        try retry.download(source.path, to: destination)
        XCTAssertEqual(reported, UInt64(firstBytes.count + secondBytes.count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("nested/first.bin")), firstBytes)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("second.bin")), secondBytes)
    }

    func testUnexpectedDirectoryDownloadStagingTreeIsDiscarded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote.appendingPathComponent("folder"), withIntermediateDirectories: true)
        let bytes = Data((0..<40_000).map { UInt8($0 % 251) })
        try bytes.write(to: remote.appendingPathComponent("folder/expected.bin"))
        let destination = root.appendingPathComponent("copy")
        let staging = SFTPClient.downloadStagingPath(destination)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try Data("stale".utf8).write(to: staging.appendingPathComponent("unexpected.bin"))

        let client = try SFTPClient(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: ["-d", remote.path])
        defer { client.close() }
        try client.download(remote.appendingPathComponent("folder").path, to: destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("unexpected.bin").path))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("expected.bin")), bytes)
    }
}
