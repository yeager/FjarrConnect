import Foundation
import Darwin

struct SFTPEntry: Identifiable, Hashable {
    let name: String
    let size: UInt64
    let permissions: UInt32
    let modified: Date?
    var id: String { name }
    var isDirectory: Bool { permissions & 0o170000 == 0o040000 }
    var isSymbolicLink: Bool { permissions & 0o170000 == 0o120000 }
    var isRegularFile: Bool { permissions & 0o170000 == 0o100000 }
}

enum SFTPFailure: Error, LocalizedError {
    case invalidPacket, disconnected, cancelled, timeout, unsupported, exists, unsafeFile
    case server(UInt32, String)
    var isFatal: Bool {
        switch self {
        case .invalidPacket, .disconnected, .cancelled, .timeout: return true
        default: return false
        }
    }
    var errorDescription: String? {
        switch self {
        case .server(_, let message): return String(message.prefix(500))
        case .invalidPacket: return NSLocalizedString("files.error.protocol", comment: "")
        case .disconnected: return NSLocalizedString("files.error.connection", comment: "")
        case .cancelled: return NSLocalizedString("files.cancelled", comment: "")
        case .timeout: return NSLocalizedString("files.error.timeout", comment: "")
        case .unsupported: return NSLocalizedString("files.error.unsupported", comment: "")
        case .exists: return NSLocalizedString("files.error.exists", comment: "")
        case .unsafeFile: return NSLocalizedString("files.error.fileType", comment: "")
        }
    }
}

/// Binary SFTP v3 over an authenticated OpenSSH subsystem. Filenames are never
/// interpolated into shell commands or parsed from human-readable directory output.
final class SFTPClient {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let cancellation = NSLock()
    private var cancelled = false
    private var requestID: UInt32 = 0
    private(set) var extensions: [String: String] = [:]
    private(set) var isConnected = false
    var onProgress: ((UInt64) -> Void)?

    init(executable: URL, arguments: [String]) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment.filter {
            ["HOME", "USER", "LOGNAME", "PATH", "SSH_AUTH_SOCK", "LANG", "TMPDIR"].contains($0.key)
        }
        try process.run()
        try input.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
        for fd in [input.fileHandleForWriting.fileDescriptor, output.fileHandleForReading.fileDescriptor] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        // A broken pipe is an ordinary connection failure, never an app-wide SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            var initialize = SFTPPacket(type: 1)
            initialize.put(UInt32(3))
            try send(initialize.data)
            var reply = try receive()
            guard try reply.byte() == 2, try reply.uint32() == 3 else { throw SFTPFailure.unsupported }
            while reply.remaining > 0 {
                let name = try reply.string()
                let value = try reply.string()
                extensions[name] = value
            }
            isConnected = true
        } catch { close(); throw error }
    }

    deinit { close() }
    func cancel() { cancellation.lock(); cancelled = true; cancellation.unlock() }
    func close() {
        cancel()
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        isConnected = false
    }
    private func checkCancellation() throws {
        cancellation.lock(); let stopped = cancelled; cancellation.unlock()
        if stopped { throw SFTPFailure.cancelled }
    }

    func realPath(_ path: String) throws -> String {
        var reply = try request(16) { $0.put(path) }
        try expect(104, in: &reply)
        guard try reply.uint32() == 1 else { throw SFTPFailure.invalidPacket }
        let result = try reply.string()
        guard !result.contains("\0") else { throw SFTPFailure.invalidPacket }
        return result
    }

    func list(_ path: String) throws -> [SFTPEntry] {
        let handle = try openHandle(11) { $0.put(path) }
        defer { try? closeHandle(handle) }
        var entries: [SFTPEntry] = []
        while true {
            var reply = try request(12) { $0.put(handle) }
            let type = try reply.byte()
            if type == 101 {
                let status = try readStatus(&reply)
                if status.0 == 1 { break }
                throw SFTPFailure.server(status.0, status.1)
            }
            guard type == 104 else { throw SFTPFailure.invalidPacket }
            let count = try reply.uint32()
            guard count <= 50_000, entries.count + Int(count) <= 100_000 else { throw SFTPFailure.invalidPacket }
            for _ in 0..<count {
                let name = try reply.string()
                _ = try reply.string() // longname is display-only and is deliberately ignored.
                let entry = try attributes(&reply, name: name)
                if name == "." || name == ".." { continue }
                guard Self.safeName(name) else { throw SFTPFailure.invalidPacket }
                entries.append(entry)
            }
            guard reply.remaining == 0 else { throw SFTPFailure.invalidPacket }
        }
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func stat(_ path: String) throws -> SFTPEntry? {
        var reply = try request(7) { $0.put(path) } // LSTAT: never follow a symlink implicitly.
        if reply.data.first == 101 {
            _ = try reply.byte()
            let status = try readStatus(&reply)
            if status.0 == 2 { return nil }
            throw SFTPFailure.server(status.0, status.1)
        }
        try expect(105, in: &reply)
        return try attributes(&reply, name: (path as NSString).lastPathComponent)
    }

    func makeDirectory(_ path: String) throws {
        try statusRequest(14) { packet in
            packet.put(path); packet.put(UInt32(4)); packet.put(UInt32(0o700))
        }
    }

    func remove(_ path: String, directory: Bool) throws {
        try statusRequest(directory ? 15 : 13) { $0.put(path) }
    }

    func rename(_ old: String, to new: String, overwrite: Bool = false) throws {
        if overwrite {
            guard extensions["posix-rename@openssh.com"] != nil else { throw SFTPFailure.unsupported }
            try statusRequest(200) { $0.put("posix-rename@openssh.com"); $0.put(old); $0.put(new) }
        } else {
            try statusRequest(18) { $0.put(old); $0.put(new) }
        }
    }

    func upload(_ local: URL, to remote: String, overwrite: Bool = false) throws {
        let attributes = try local.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
        guard attributes.isSymbolicLink != true else { throw SFTPFailure.unsafeFile }
        let existing = try stat(remote)
        if let existing {
            guard overwrite, existing.isRegularFile, attributes.isRegularFile == true else { throw SFTPFailure.exists }
        }
        if attributes.isDirectory == true {
            let staging = remote + ".fjarrconnect-" + UUID().uuidString + ".partial"
            try makeDirectory(staging)
            try uploadDirectory(local, to: staging, depth: 0)
            try rename(staging, to: remote)
        } else {
            guard attributes.isRegularFile == true else { throw SFTPFailure.unsafeFile }
            let staging = Self.uploadStagingPath(remote)
            do {
                let offset = try resumableOffset(local: local, staging: staging)
                try uploadFile(local, to: staging, startingAt: offset)
                try rename(staging, to: remote, overwrite: existing != nil && overwrite)
            } catch {
                // Keep a verified partial file for retry after a cancelled or lost session.
                // Invalid local input must never leave an app-created remote artifact behind.
                let retainPartial = (error as? SFTPFailure)?.isFatal ?? false
                if !retainPartial { try? remove(staging, directory: false) }
                throw error
            }
        }
    }

    private func uploadDirectory(_ local: URL, to remote: String, depth: Int) throws {
        guard depth < 64 else { throw SFTPFailure.unsafeFile }
        for child in try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) {
            try checkCancellation()
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, Self.safeName(child.lastPathComponent) else { throw SFTPFailure.unsafeFile }
            let path = Self.join(remote, child.lastPathComponent)
            if values.isDirectory == true {
                try makeDirectory(path)
                try uploadDirectory(child, to: path, depth: depth + 1)
            } else if values.isRegularFile == true { try uploadFile(child, to: path) }
            else { throw SFTPFailure.unsafeFile }
        }
    }

    private func uploadFile(_ local: URL, to remote: String, startingAt: UInt64 = 0) throws {
        let fd = Darwin.open(local.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SFTPFailure.unsafeFile }
        let source = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { try? source.close(); throw SFTPFailure.unsafeFile }
        defer { try? source.close() }
        guard info.st_size >= 0, UInt64(info.st_size) >= startingAt else { throw SFTPFailure.unsafeFile }
        if startingAt > 0 { try source.seek(toOffset: startingAt) }
        let handle = try openHandle(3) {
            let flags: UInt32 = startingAt == 0 ? 2 | 8 | 32 : 2 | 8
            $0.put(remote); $0.put(flags); $0.put(UInt32(4)); $0.put(UInt32(0o600))
        }
        var closed = false
        defer { if !closed { try? closeHandle(handle) } }
        var offset = startingAt
        if offset > 0 { onProgress?(offset) }
        while let data = try source.read(upToCount: 32_768), !data.isEmpty {
            try statusRequest(6) { $0.put(handle); $0.put(offset); $0.put(data) }
            offset += UInt64(data.count)
            onProgress?(UInt64(data.count))
        }
        if extensions["fsync@openssh.com"] != nil {
            try statusRequest(200) { $0.put("fsync@openssh.com"); $0.put(handle) }
        }
        try closeHandle(handle)
        closed = true
    }

    private func resumableOffset(local: URL, staging: String) throws -> UInt64 {
        guard let partial = try stat(staging) else { return 0 }
        guard partial.isRegularFile else { throw SFTPFailure.exists }
        let attributes = try local.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = attributes.fileSize, fileSize >= 0 else { throw SFTPFailure.unsafeFile }
        let localSize = UInt64(fileSize)
        guard partial.size <= localSize, try stagingMatchesLocalPrefix(staging, local: local, length: partial.size) else {
            try remove(staging, directory: false)
            return 0
        }
        return partial.size
    }

    private func stagingMatchesLocalPrefix(_ remote: String, local: URL, length: UInt64) throws -> Bool {
        guard length > 0 else { return true }
        let fd = Darwin.open(local.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SFTPFailure.unsafeFile }
        let source = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? source.close() }
        let handle = try openHandle(3) { $0.put(remote); $0.put(UInt32(1)); $0.put(UInt32(0)) }
        defer { try? closeHandle(handle) }
        var offset: UInt64 = 0
        while offset < length {
            let requested = Int(min(32_768, length - offset))
            var reply = try request(5) { $0.put(handle); $0.put(offset); $0.put(UInt32(requested)) }
            guard try reply.byte() == 103 else { return false }
            let remoteData = try reply.bytes()
            guard remoteData.count == requested, reply.remaining == 0,
                  let localData = try source.read(upToCount: requested), localData == remoteData else { return false }
            offset += UInt64(requested)
        }
        return true
    }

    func download(_ remote: String, to local: URL, overwrite: Bool = false) throws {
        guard let entry = try stat(remote) else { throw SFTPFailure.server(2, NSLocalizedString("files.error.missing", comment: "")) }
        let exists = FileManager.default.fileExists(atPath: local.path)
        guard !exists || (overwrite && entry.isRegularFile) else { throw SFTPFailure.exists }
        if exists {
            let values = try local.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw SFTPFailure.unsafeFile }
        }
        let staging = local.deletingLastPathComponent().appendingPathComponent(".fjarrconnect-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        if entry.isDirectory {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try downloadDirectory(remote, to: staging, depth: 0)
        } else if entry.isRegularFile { try downloadFile(remote, to: staging) }
        else { throw SFTPFailure.unsafeFile }
        if exists { _ = try FileManager.default.replaceItemAt(local, withItemAt: staging) }
        else { try FileManager.default.moveItem(at: staging, to: local) }
    }

    private func downloadDirectory(_ remote: String, to local: URL, depth: Int) throws {
        guard depth < 64 else { throw SFTPFailure.unsafeFile }
        for entry in try list(remote) {
            try checkCancellation()
            let path = Self.join(remote, entry.name)
            let destination = local.appendingPathComponent(entry.name)
            if entry.isDirectory {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try downloadDirectory(path, to: destination, depth: depth + 1)
            } else if entry.isRegularFile { try downloadFile(path, to: destination) }
            else { throw SFTPFailure.unsafeFile }
        }
    }

    private func downloadFile(_ remote: String, to local: URL) throws {
        guard FileManager.default.createFile(atPath: local.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        let destination = try FileHandle(forWritingTo: local)
        defer { try? destination.close() }
        let handle = try openHandle(3) { $0.put(remote); $0.put(UInt32(1)); $0.put(UInt32(0)) }
        defer { try? closeHandle(handle) }
        var offset: UInt64 = 0
        while true {
            var reply = try request(5) { $0.put(handle); $0.put(offset); $0.put(UInt32(32_768)) }
            let kind = try reply.byte()
            if kind == 101 {
                let status = try readStatus(&reply)
                if status.0 == 1 { break }
                throw SFTPFailure.server(status.0, status.1)
            }
            guard kind == 103 else { throw SFTPFailure.invalidPacket }
            let data = try reply.bytes()
            guard !data.isEmpty, data.count <= 32_768, reply.remaining == 0 else { throw SFTPFailure.invalidPacket }
            try destination.write(contentsOf: data)
            offset += UInt64(data.count)
            onProgress?(UInt64(data.count))
        }
        try destination.synchronize()
    }

    static func safeName(_ name: String) -> Bool { !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0") }
    static func join(_ directory: String, _ name: String) -> String { (directory == "/" ? "" : directory) + "/" + name }
    static func uploadStagingPath(_ remote: String) -> String { remote + ".fjarrconnect.partial" }

    private func attributes(_ reply: inout SFTPPacket, name: String) throws -> SFTPEntry {
        let flags = try reply.uint32()
        guard flags & ~UInt32(0x8000000f) == 0 else { throw SFTPFailure.invalidPacket }
        let size = flags & 1 == 0 ? 0 : try reply.uint64()
        if flags & 2 != 0 { _ = try reply.uint32(); _ = try reply.uint32() }
        let permissions = flags & 4 == 0 ? 0 : try reply.uint32()
        var modified: Date?
        if flags & 8 != 0 { _ = try reply.uint32(); modified = Date(timeIntervalSince1970: TimeInterval(try reply.uint32())) }
        if flags & 0x80000000 != 0 {
            let count = try reply.uint32()
            guard count <= 1024 else { throw SFTPFailure.invalidPacket }
            for _ in 0..<count { _ = try reply.bytes(); _ = try reply.bytes() }
        }
        return SFTPEntry(name: name, size: size, permissions: permissions, modified: modified)
    }

    private func openHandle(_ type: UInt8, _ body: (inout SFTPPacket) -> Void) throws -> Data {
        var reply = try request(type, body)
        try expect(102, in: &reply)
        return try reply.bytes()
    }
    private func closeHandle(_ handle: Data) throws { try statusRequest(4) { $0.put(handle) } }
    private func statusRequest(_ type: UInt8, _ body: (inout SFTPPacket) -> Void) throws {
        var reply = try request(type, body)
        guard try reply.byte() == 101 else { throw SFTPFailure.invalidPacket }
        let status = try readStatus(&reply)
        guard status.0 == 0 else { throw SFTPFailure.server(status.0, status.1) }
    }
    private func expect(_ type: UInt8, in reply: inout SFTPPacket) throws {
        let actual = try reply.byte()
        if actual == 101 { let status = try readStatus(&reply); throw SFTPFailure.server(status.0, status.1) }
        guard actual == type else { throw SFTPFailure.invalidPacket }
    }
    private func readStatus(_ reply: inout SFTPPacket) throws -> (UInt32, String) {
        (try reply.uint32(), try reply.string())
    }
    private func request(_ type: UInt8, _ body: (inout SFTPPacket) -> Void) throws -> SFTPPacket {
        try checkCancellation()
        requestID &+= 1
        var packet = SFTPPacket(type: type)
        packet.put(requestID)
        body(&packet)
        try send(packet.data)
        var reply = try receive()
        let type = try reply.byte()
        guard try reply.uint32() == requestID else { throw SFTPFailure.invalidPacket }
        return SFTPPacket(data: Data([type]) + reply.data.dropFirst(reply.cursor))
    }
    private func send(_ payload: Data) throws {
        var framed = SFTPPacket(data: Data())
        framed.put(UInt32(payload.count))
        framed.data.append(payload)
        let fd = input.fileHandleForWriting.fileDescriptor
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        var offset = 0
        try framed.data.withUnsafeBytes { buffer in
            while offset < buffer.count {
                try ready(fd, events: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard count > 0 else { throw SFTPFailure.disconnected }
                offset += count
            }
        }
    }
    private func receive() throws -> SFTPPacket {
        var header = SFTPPacket(data: try read(4))
        let length = Int(try header.uint32())
        guard (1...2_097_152).contains(length) else { throw SFTPFailure.invalidPacket }
        return SFTPPacket(data: try read(length))
    }
    private func read(_ length: Int) throws -> Data {
        let fd = output.fileHandleForReading.fileDescriptor
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        var result = Data(count: length)
        var offset = 0
        try result.withUnsafeMutableBytes { buffer in
            while offset < length {
                try ready(fd, events: Int16(POLLIN), deadline: deadline)
                let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), length - offset)
                if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard count > 0 else { throw SFTPFailure.disconnected }
                offset += count
            }
        }
        return result
    }
    private func ready(_ fd: Int32, events: Int16, deadline: TimeInterval) throws {
        while true {
            try checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw SFTPFailure.timeout }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, 100)
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw SFTPFailure.disconnected }
            if result > 0 {
                guard descriptor.revents & (events | Int16(POLLHUP)) != 0 else { throw SFTPFailure.disconnected }
                return
            }
        }
    }
}

struct SFTPPacket {
    var data: Data
    var cursor = 0
    var remaining: Int { data.count - cursor }
    init(type: UInt8) { data = Data([type]) }
    init(data: Data) { self.data = data }
    mutating func put(_ value: UInt32) { var number = value.bigEndian; withUnsafeBytes(of: &number) { data.append(contentsOf: $0) } }
    mutating func put(_ value: UInt64) { var number = value.bigEndian; withUnsafeBytes(of: &number) { data.append(contentsOf: $0) } }
    mutating func put(_ value: Data) { put(UInt32(value.count)); data.append(value) }
    mutating func put(_ value: String) { put(Data(value.utf8)) }
    mutating func byte() throws -> UInt8 {
        guard remaining >= 1 else { throw SFTPFailure.invalidPacket }; defer { cursor += 1 }; return data[cursor]
    }
    mutating func uint32() throws -> UInt32 {
        guard remaining >= 4 else { throw SFTPFailure.invalidPacket }; defer { cursor += 4 }
        return data.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)) }
    }
    mutating func uint64() throws -> UInt64 {
        guard remaining >= 8 else { throw SFTPFailure.invalidPacket }; defer { cursor += 8 }
        return data.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: cursor, as: UInt64.self)) }
    }
    mutating func bytes() throws -> Data {
        let length = Int(try uint32()); guard length <= remaining else { throw SFTPFailure.invalidPacket }
        defer { cursor += length }; return data.subdata(in: cursor..<(cursor + length))
    }
    mutating func string() throws -> String {
        guard let value = String(data: try bytes(), encoding: .utf8) else { throw SFTPFailure.invalidPacket }; return value
    }
}
