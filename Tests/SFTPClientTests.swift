import XCTest
@testable import FjarrConnect

final class SFTPClientTests: XCTestCase {
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
        XCTAssertEqual(try first.stat(staging)?.size, 32_768)
        first.close()

        let retry = try SFTPClient(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: ["-d", remote.path])
        defer { retry.close() }
        var reported = UInt64(0)
        retry.onProgress = { reported += $0 }
        try retry.upload(source, to: target)
        XCTAssertEqual(reported, UInt64(bytes.count))
        XCTAssertEqual(try retry.stat(staging), nil)
        let copy = root.appendingPathComponent("copy.bin")
        try retry.download(target, to: copy)
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
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
}
