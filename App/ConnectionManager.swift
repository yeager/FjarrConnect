import SwiftUI
import Combine

/// Each tab owns a backend and a subscription. Selecting a tab never restarts it.
final class SessionTab: ObservableObject, Identifiable {
    let id = UUID()
    let backend: any RemoteSession
    let recorder = SessionRecordingController()
    private var subscriptions = Set<AnyCancellable>()
    init(backend: any RemoteSession) {
        self.backend = backend
        backend.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.backend.status.isFinished else { return }
                self.recorder.stop()
            }
        }
            .store(in: &subscriptions)
        recorder.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
    }

    var canRecord: Bool { backend is any SessionRecordingSource }

    func startRecording() {
        guard let source = backend as? any SessionRecordingSource,
              let view = source.recordingView else { return }
        recorder.start(capturing: view, profileName: backend.profile.name)
    }

    func stopRecording() { recorder.stop() }
}

final class ConnectionManager: ObservableObject {
    @Published private(set) var tabs: [SessionTab] = []
    @Published var selectedID: UUID? {
        didSet { tabs.forEach { $0.backend.setActive($0.id == selectedID) } }
    }
    private let makeSession: (ConnectionProfile, SessionCredentials) -> any RemoteSession

    init(makeSession: @escaping (ConnectionProfile, SessionCredentials) -> any RemoteSession = ProtocolRegistry.makeSession) {
        self.makeSession = makeSession
    }

    var selected: SessionTab? { tabs.first { $0.id == selectedID } }
    var activeSessions: [SessionTab] { tabs.filter { $0.backend.status.isActive } }

    func requestClose(_ id: UUID, confirm: (String) -> Bool = CloseConfirmation.session) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if tab.backend.status.isActive && !confirm(tab.backend.profile.name) { return }
        close(id)
    }

    func confirmClosingAll() -> Bool {
        let names = activeSessions.map { $0.backend.profile.name }
        return names.isEmpty || CloseConfirmation.application(names)
    }

    func connect(_ profile: ConnectionProfile, password: String? = nil, gatewayPassword: String? = nil) {
        guard profile.isValid else { return }
        if let tab = tabs.first(where: { $0.backend.profile.id == profile.id &&
            $0.backend.profile.host == profile.host && $0.backend.profile.port == profile.port &&
            $0.backend.profile.transport == profile.transport && $0.backend.profile.username == profile.username &&
            !$0.backend.status.isFinished }) {
            selectedID = tab.id
            return
        }
        let tab = SessionTab(backend: makeSession(profile, SessionCredentials(password: password, gatewayPassword: gatewayPassword)))
        tabs.append(tab)
        selectedID = tab.id
        tab.backend.start()
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].stopRecording()
        tabs[index].backend.stop()
        tabs.remove(at: index)
        if selectedID == id { selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
    }

    func disconnectAll() {
        tabs.forEach { $0.stopRecording(); $0.backend.stop() }
        tabs.removeAll()
        selectedID = nil
    }
}
