import Foundation
import Combine
import CryptoKit
import CommonCrypto
import Security

private struct EncryptedProfileExport: Codable {
    static let legacyVersion = 1
    static let currentVersion = 2
    let version: Int
    let iterations: Int
    let salt: Data
    let ciphertext: Data
}

enum ProfileTransferError: Error {
    case emptyPassphrase, unsupportedFormat, invalidProfiles
}

enum ExternalProfileImporter {
    static func profile(data: Data, fileExtension: String) -> ConnectionProfile? {
        guard data.count <= 1_048_576,
              let text = String(data: data, encoding: .utf8) else { return nil }
        switch fileExtension.lowercased() {
        case "rdp": return rdp(text)
        case "vnc": return vnc(text)
        default: return nil
        }
    }

    private static func rdp(_ text: String) -> ConnectionProfile? {
        let values = typedValues(text)
        guard let endpoint = values["full address"],
              var profile = ConnectionURI.profile(from: "rdp://" + endpoint) else { return nil }
        profile.transport = .rdp
        if let username = values["username"], ConnectionOptions.validValue(username), !username.isEmpty {
            profile.username = username
        }
        return profile
    }

    private static func vnc(_ text: String) -> ConnectionProfile? {
        let values = iniValues(text)
        guard let host = values["host"], !host.isEmpty else { return nil }
        let endpoint = values["port"].flatMap(UInt16.init).map { host + ":" + String($0) } ?? host
        guard var profile = ConnectionURI.profile(from: "vnc://" + endpoint) else { return nil }
        if let username = values["username"], ConnectionOptions.validValue(username), !username.isEmpty {
            profile.username = username
        }
        return profile
    }

    /// Microsoft .rdp uses `name:type:value`; only string-valued connection
    /// fields are read. Password fields and every unrecognised key are ignored.
    private static func typedValues(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let pieces = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard pieces.count == 3, pieces[1].lowercased() == "s" else { continue }
            let key = pieces[0].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "full address" || key == "username", values[key] == nil else { continue }
            values[key] = pieces[2].trimmingCharacters(in: .whitespaces)
        }
        return values
    }

    /// RealVNC/TigerVNC style files are INI-like. Only endpoint and username
    /// values are accepted; `Password` and all secret extensions are ignored.
    private static func iniValues(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let pieces = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            let key = pieces[0].trimmingCharacters(in: .whitespaces).lowercased()
            guard ["host", "port", "username"].contains(key), values[key] == nil else { continue }
            values[key] = pieces[1].trimmingCharacters(in: .whitespaces)
        }
        return values
    }
}

final class ProfileStore: ObservableObject {
    static let maximumProfileTransferBytes = 8 * 1024 * 1024
    static let maximumExternalProfileBytes = 1_048_576
    private static let profileTransferIterations = 600_000

    @Published private(set) var profiles: [ConnectionProfile] = []
    @Published var errorMessage: String?
    private let fileURL: URL
    private var loadFailed = false

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FjarrConnect/profiles.json")
        do {
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                let decoded = try JSONDecoder().decode([ConnectionProfile].self, from: Data(contentsOf: self.fileURL))
                guard decoded.allSatisfy(\.isValid), Set(decoded.map(\.id)).count == decoded.count else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                profiles = decoded
            }
        } catch {
            loadFailed = true // Preserve the original file; never overwrite corrupt data with an empty list.
            errorMessage = error.localizedDescription
        }
    }

    func save(_ profile: ConnectionProfile, password: String?, gatewayPassword: String? = nil) throws {
        guard profile.isValid else { throw CocoaError(.validationMissingMandatoryProperty) }
        var next = profiles
        if let index = next.firstIndex(where: { $0.id == profile.id }) { next[index] = profile }
        else { next.append(profile) }
        try persist(next, credentialID: profile.id, password: password, gatewayPassword: gatewayPassword)
    }

    func remove(_ profile: ConnectionProfile) throws {
        try SSHCommandLogStore.shared.clear(for: profile.id)
        try persist(profiles.filter { $0.id != profile.id }, credentialID: profile.id, password: "", gatewayPassword: "")
    }

    func toggleFavorite(_ id: UUID) throws {
        guard var profile = profiles.first(where: { $0.id == id }) else { return }
        profile.isFavorite.toggle()
        try save(profile, password: nil)
    }

    var favorites: [ConnectionProfile] {
        profiles.filter(\.isFavorite).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var recent: [ConnectionProfile] {
        profiles.compactMap { profile in profile.lastConnected.map { ($0, profile) } }
            .sorted { $0.0 > $1.0 }.prefix(8).map(\.1)
    }

    func markUsed(_ id: UUID, now: Date = .now) {
        guard var profile = profiles.first(where: { $0.id == id }) else { return }
        profile.lastConnected = now
        try? save(profile, password: nil)
    }

    /// Produces an encrypted transfer document. Connection passwords are kept in
    /// the Keychain and are not present in `ConnectionProfile`, so they cannot be
    /// exported by this method.
    func encryptedExport(passphrase: String) throws -> Data {
        guard !passphrase.isEmpty else { throw ProfileTransferError.emptyPassphrase }
        let salt = try Self.randomBytes(count: 16)
        let plaintext = try JSONEncoder().encode(profiles)
        guard plaintext.count <= Self.maximumProfileTransferBytes else {
            throw ProfileTransferError.unsupportedFormat
        }
        let key = try Self.pbkdf2Key(passphrase: passphrase, salt: salt,
                                     iterations: Self.profileTransferIterations)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let ciphertext = sealed.combined else { throw ProfileTransferError.unsupportedFormat }
        let document = try JSONEncoder().encode(EncryptedProfileExport(
            version: EncryptedProfileExport.currentVersion,
            iterations: Self.profileTransferIterations,
            salt: salt,
            ciphertext: ciphertext))
        guard document.count <= Self.maximumProfileTransferBytes else {
            throw ProfileTransferError.unsupportedFormat
        }
        return document
    }

    /// Imports profiles as new identities. The export contains no credentials,
    /// so importing never reads or writes Keychain items for the source profiles.
    @discardableResult
    func importEncryptedProfiles(_ data: Data, passphrase: String) throws -> Int {
        guard !passphrase.isEmpty else { throw ProfileTransferError.emptyPassphrase }
        guard data.count <= Self.maximumProfileTransferBytes else {
            throw ProfileTransferError.unsupportedFormat
        }
        let document = try JSONDecoder().decode(EncryptedProfileExport.self, from: data)
        guard document.salt.count == 16,
              let sealed = try? AES.GCM.SealedBox(combined: document.ciphertext) else {
            throw ProfileTransferError.unsupportedFormat
        }
        let key: SymmetricKey
        switch document.version {
        case EncryptedProfileExport.legacyVersion:
            guard (10_000...500_000).contains(document.iterations) else {
                throw ProfileTransferError.unsupportedFormat
            }
            key = Self.legacyKey(passphrase: passphrase, salt: document.salt,
                                 iterations: document.iterations)
        case EncryptedProfileExport.currentVersion:
            guard (Self.profileTransferIterations...1_000_000).contains(document.iterations) else {
                throw ProfileTransferError.unsupportedFormat
            }
            key = try Self.pbkdf2Key(passphrase: passphrase, salt: document.salt,
                                     iterations: document.iterations)
        default:
            throw ProfileTransferError.unsupportedFormat
        }
        let plaintext = try AES.GCM.open(sealed, using: key)
        guard plaintext.count <= Self.maximumProfileTransferBytes else {
            throw ProfileTransferError.unsupportedFormat
        }
        var imported = try JSONDecoder().decode([ConnectionProfile].self, from: plaintext)
        guard imported.allSatisfy(\.isValid) else { throw ProfileTransferError.invalidProfiles }
        for index in imported.indices {
            // Imported profiles never inherit an identity that may have an
            // unrelated Keychain item on this Mac.
            imported[index].id = UUID()
        }
        guard !imported.isEmpty else { return 0 }
        try persist(profiles + imported, credentialID: UUID(), password: nil, gatewayPassword: nil)
        return imported.count
    }

    static func readBoundedFile(at url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0, maximumBytes < Int.max else {
            throw ProfileTransferError.unsupportedFormat
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            guard remaining > 0 else { break }
            let chunk = try handle.read(upToCount: min(64 * 1024, remaining)) ?? Data()
            guard !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else { throw ProfileTransferError.unsupportedFormat }
        return data
    }

    func importExternalProfile(data: Data, fileExtension: String) throws {
        guard var profile = ExternalProfileImporter.profile(data: data, fileExtension: fileExtension) else {
            throw ProfileTransferError.unsupportedFormat
        }
        profile.id = UUID()
        try save(profile, password: nil)
    }

    var grouped: [(group: String, profiles: [ConnectionProfile])] {
        Dictionary(grouping: profiles.filter { !$0.isFavorite }) { $0.group ?? NSLocalizedString("group.ungrouped", comment: "") }
            .map { (group: $0.key, profiles: $0.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
            .sorted { $0.group.localizedStandardCompare($1.group) == .orderedAscending }
    }

    private func persist(_ next: [ConnectionProfile], credentialID: UUID, password: String?, gatewayPassword: String?) throws {
        guard !loadFailed else { throw CocoaError(.fileReadCorruptFile) }
        let data = try JSONEncoder().encode(next)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Stage the file before touching credentials; failures remain visible to the caller.
        let staged = fileURL.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: staged) }
        try data.write(to: staged, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        let previous = password == nil ? nil : try KeychainStore.password(for: credentialID)
        let previousGateway = gatewayPassword == nil ? nil : try KeychainStore.password(for: credentialID, purpose: .gateway)
        do {
            try KeychainStore.setPassword(password, for: credentialID)
            try KeychainStore.setPassword(gatewayPassword, for: credentialID, purpose: .gateway)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: staged)
            } else { try FileManager.default.moveItem(at: staged, to: fileURL) }
        } catch {
            if password != nil { try? KeychainStore.setPassword(previous ?? "", for: credentialID) }
            if gatewayPassword != nil { try? KeychainStore.setPassword(previousGateway ?? "", for: credentialID, purpose: .gateway) }
            throw error
        }
        profiles = next
    }

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw KeychainStore.Failure(status: status) }
        return bytes
    }

    static func pbkdf2Key(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let password = Data(passphrase.utf8)
        guard !password.isEmpty, let rounds = UInt32(exactly: iterations) else {
            throw ProfileTransferError.unsupportedFormat
        }
        var derived = Data(count: 32)
        let derivedCount = derived.count
        let status = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                derived.withUnsafeMutableBytes { derivedBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         passwordBytes.bindMemory(to: Int8.self).baseAddress,
                                         password.count,
                                         saltBytes.bindMemory(to: UInt8.self).baseAddress,
                                         salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                         rounds,
                                         derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                                         derivedCount)
                }
            }
        }
        guard status == kCCSuccess else { throw ProfileTransferError.unsupportedFormat }
        return SymmetricKey(data: derived)
    }

    private static func legacyKey(passphrase: String, salt: Data, iterations: Int) -> SymmetricKey {
        let password = Data(passphrase.utf8)
        var material = salt
        material.append(password)
        var digest = Data(SHA256.hash(data: material))
        for _ in 1..<iterations {
            var round = digest
            round.append(material)
            digest = Data(SHA256.hash(data: round))
        }
        return SymmetricKey(data: digest)
    }
}
