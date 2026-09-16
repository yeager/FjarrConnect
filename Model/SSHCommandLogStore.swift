import Foundation
import CryptoKit
import Security

struct SSHCommandLogEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let command: String
}

/// Encrypted at rest, bounded, and serialized across all sessions for a profile.
/// Plaintext consists only of a timestamp, random ID and fixed command label.
final class SSHCommandLogStore {
    static let shared = SSHCommandLogStore()
    static let maximumEntries = 1000
    static let maximumAge: TimeInterval = 30 * 24 * 60 * 60
    private let directory: URL
    private let key: (UUID, Bool) throws -> SymmetricKey?
    private let deleteKey: (UUID) throws -> Void
    private let lock = NSLock()
    private let header = Data("FJSSH1".utf8)

    init(directory: URL? = nil,
         key: @escaping (UUID, Bool) throws -> SymmetricKey? = SSHLogKeychain.key,
         deleteKey: @escaping (UUID) throws -> Void = SSHLogKeychain.delete) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FjarrConnect/SSHCommandLogs", isDirectory: true)
        self.key = key
        self.deleteKey = deleteKey
    }

    func entries(for id: UUID, now: Date = Date()) throws -> [SSHCommandLogEntry] {
        lock.lock(); defer { lock.unlock() }
        let entries = try read(id)
        let retained = retain(entries, now: now)
        // Expired entries are removed from ciphertext when the log is opened.
        if retained != entries { try write(retained, id: id) }
        return retained
    }

    func append(command: String, for id: UUID, now: Date = Date()) throws {
        guard SSHCommandLogging.names.contains(command) || command == "other" else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        lock.lock(); defer { lock.unlock() }
        var entries = retain(try read(id), now: now)
        entries.append(SSHCommandLogEntry(id: UUID(), date: now, command: command))
        try write(Array(entries.suffix(Self.maximumEntries)), id: id)
    }

    func clear(for id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        let url = file(id)
        try rejectLink(directory)
        try rejectLink(url)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try deleteKey(id)
    }

    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".sealed") }
    private func retain(_ entries: [SSHCommandLogEntry], now: Date) -> [SSHCommandLogEntry] {
        Array(entries.filter { now.timeIntervalSince($0.date) <= Self.maximumAge }.suffix(Self.maximumEntries))
    }
    private func rejectLink(_ url: URL) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
    private func read(_ id: UUID) throws -> [SSHCommandLogEntry] {
        try rejectLink(directory)
        let url = file(id)
        try rejectLink(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 512_000,
              let key = try key(id, false) else { throw CocoaError(.fileReadCorruptFile) }
        let data = try Data(contentsOf: url)
        guard data.starts(with: header) else { throw CocoaError(.fileReadCorruptFile) }
        let box = try AES.GCM.SealedBox(combined: data.dropFirst(header.count))
        let plaintext = try AES.GCM.open(box, using: key, authenticating: associatedData(id))
        let entries = try JSONDecoder().decode([SSHCommandLogEntry].self, from: plaintext)
        guard entries.count <= Self.maximumEntries,
              entries.allSatisfy({ SSHCommandLogging.names.contains($0.command) || $0.command == "other" }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return entries
    }
    private func write(_ entries: [SSHCommandLogEntry], id: UUID) throws {
        try rejectLink(directory)
        try rejectLink(file(id))
        guard let key = try key(id, true) else { throw CocoaError(.fileWriteNoPermission) }
        let plaintext = try JSONEncoder().encode(entries)
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData(id))
        guard let combined = box.combined else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // Even temporary files contain only authenticated ciphertext.
        try (header + combined).write(to: file(id), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(id).path)
    }
    private func associatedData(_ id: UUID) -> Data { header + Data(id.uuidString.utf8) }
}

enum SSHLogKeychain {
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "se.fjarrconnect.app.ssh-command-log",
         kSecAttrAccount as String: id.uuidString,
         kSecAttrSynchronizable as String: false]
    }
    static func key(_ id: UUID, create: Bool) throws -> SymmetricKey? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound {
            guard create else { return nil }
            let key = SymmetricKey(size: .bits256)
            var add = query(id)
            add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(add as CFDictionary, nil)
            if added == errSecDuplicateItem { return try self.key(id, create: false) }
            guard added == errSecSuccess else { throw KeychainStore.Failure(status: added) }
            return key
        }
        guard status == errSecSuccess else { throw KeychainStore.Failure(status: status) }
        guard let data = result as? Data, data.count == 32 else { throw KeychainStore.Failure(status: errSecDecode) }
        return SymmetricKey(data: data)
    }
    static func delete(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound { throw KeychainStore.Failure(status: status) }
    }
}
