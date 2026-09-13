import Foundation
import Combine

/// Holds and persists saved connection profiles.
///
/// Remmina keeps one `.remmina` file per connection under its config dir; here we
/// keep a single JSON document under Application Support for simplicity. Swapping to
/// one-file-per-profile later is a drop-in change behind this type.
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [ConnectionProfile] = []

    private let fileURL: URL

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FjarrConnect", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("profiles.json")
        load()
    }

    // MARK: CRUD

    func add(_ profile: ConnectionProfile, password: String?) {
        profiles.append(profile)
        KeychainStore.setPassword(password, for: profile.id)
        save()
    }

    func update(_ profile: ConnectionProfile, password: String?) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx] = profile
        if let password { KeychainStore.setPassword(password, for: profile.id) }
        save()
    }

    func remove(_ profile: ConnectionProfile) {
        profiles.removeAll { $0.id == profile.id }
        KeychainStore.deletePassword(for: profile.id)
        save()
    }

    /// Profiles bucketed by their optional group, for a Remmina-style sidebar.
    var grouped: [(group: String, profiles: [ConnectionProfile])] {
        Dictionary(grouping: profiles) { $0.group ?? "Ungrouped" }
            .map { (group: $0.key, profiles: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.group < $1.group }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ConnectionProfile].self, from: data)
        else { return }
        profiles = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
