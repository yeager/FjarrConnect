import Foundation
import Combine

final class ProfileStore: ObservableObject {
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
}
