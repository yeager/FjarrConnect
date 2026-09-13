import SwiftUI
import Combine

/// Each tab owns a backend and a subscription. Selecting a tab never restarts it.
final class SessionTab: ObservableObject, Identifiable {
    let id = UUID()
    let backend: any RemoteSession
    private var subscription: AnyCancellable?
    init(backend: any RemoteSession) {
        self.backend = backend
        subscription = backend.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

final class ConnectionManager: ObservableObject {
    @Published private(set) var tabs: [SessionTab] = []
    @Published var selectedID: UUID?
    private let makeSession: (ConnectionProfile, String?) -> any RemoteSession

    init(makeSession: @escaping (ConnectionProfile, String?) -> any RemoteSession = ProtocolRegistry.makeSession) {
        self.makeSession = makeSession
    }

    var selected: SessionTab? { tabs.first { $0.id == selectedID } }

    func connect(_ profile: ConnectionProfile, password: String? = nil) {
        guard profile.isValid else { return }
        if let tab = tabs.first(where: { $0.backend.profile.id == profile.id &&
            $0.backend.profile.host == profile.host && $0.backend.profile.port == profile.port &&
            $0.backend.profile.transport == profile.transport && $0.backend.profile.username == profile.username &&
            !$0.backend.status.isFinished }) {
            selectedID = tab.id
            return
        }
        let tab = SessionTab(backend: makeSession(profile, password))
        tabs.append(tab)
        selectedID = tab.id
        tab.backend.start()
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].backend.stop()
        tabs.remove(at: index)
        if selectedID == id { selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
    }

    func disconnectAll() {
        tabs.forEach { $0.backend.stop() }
        tabs.removeAll()
        selectedID = nil
    }
}
