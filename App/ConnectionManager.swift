import SwiftUI
import Combine

/// Each tab owns its connection material for its lifetime. Saved credentials are
/// never copied to a profile or log; keeping them here permits an opted-in retry.
final class SessionTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var backend: any RemoteSession
    let recorder = SessionRecordingController()
    private var subscriptions = Set<AnyCancellable>()
    private var backendSubscription: AnyCancellable?
    private let credentials: SessionCredentials
    private let makeSession: (ConnectionProfile, SessionCredentials) -> any RemoteSession
    private var reconnectWork: DispatchWorkItem?
    private var reconnectAttempts = 0
    private var manuallyStopped = false
    private var active = false
    @Published private(set) var reconnectAttempt: Int?

    init(backend: any RemoteSession, credentials: SessionCredentials,
         makeSession: @escaping (ConnectionProfile, SessionCredentials) -> any RemoteSession) {
        self.backend = backend
        self.credentials = credentials
        self.makeSession = makeSession
        bind(backend)
        recorder.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
    }

    private func bind(_ backend: any RemoteSession) {
        backendSubscription?.cancel()
        backendSubscription = backend.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.backend.status.isFinished {
                    self.recorder.stop()
                    self.scheduleReconnectIfNeeded()
                } else if self.backend.status.isEstablished {
                    self.reconnectAttempts = 0
                    self.reconnectAttempt = nil
                }
            }
        }
    }

    var canRecord: Bool { backend is any SessionRecordingSource }

    func startRecording() {
        guard let source = backend as? any SessionRecordingSource,
              let view = source.recordingView else { return }
        recorder.start(capturing: view, profileName: backend.profile.name)
    }

    func stopRecording() { recorder.stop() }

    func start() { backend.start() }

    func setActive(_ active: Bool) {
        self.active = active
        backend.setActive(active)
    }

    func stop() {
        manuallyStopped = true
        reconnectWork?.cancel()
        reconnectWork = nil
        reconnectAttempt = nil
        backend.stop()
    }

    private func scheduleReconnectIfNeeded() {
        guard !manuallyStopped, backend.profile.reconnectsAutomatically,
              reconnectWork == nil, reconnectAttempts < 3 else { return }
        reconnectAttempts += 1
        reconnectAttempt = reconnectAttempts
        let delay = Double(1 << (reconnectAttempts - 1))
        let work = DispatchWorkItem { [weak self] in self?.restart() }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func restart() {
        guard !manuallyStopped, reconnectAttempt != nil else { return }
        reconnectWork = nil
        let next = makeSession(backend.profile, credentials)
        backend = next
        bind(next)
        next.setActive(active)
        next.start()
    }
}

final class ConnectionManager: ObservableObject {
    @Published private(set) var tabs: [SessionTab] = []
    @Published var selectedID: UUID? {
        didSet { tabs.forEach { $0.setActive($0.id == selectedID) } }
    }
    private let makeSession: (ConnectionProfile, SessionCredentials) -> any RemoteSession
    private var tabSubscriptions: [UUID: AnyCancellable] = [:]

    init(makeSession: @escaping (ConnectionProfile, SessionCredentials) -> any RemoteSession = ProtocolRegistry.makeSession) {
        self.makeSession = makeSession
    }

    var selected: SessionTab? { tabs.first { $0.id == selectedID } }
    var activeSessions: [SessionTab] { tabs.filter { $0.backend.status.isActive } }
    var hasActiveSessions: Bool { !activeSessions.isEmpty }

    func requestClose(_ id: UUID, confirm: (String) -> Bool = CloseConfirmation.session) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if tab.backend.status.isActive && AppSettings.shouldConfirmClosingSessions && !confirm(tab.backend.profile.name) { return }
        close(id)
    }

    func confirmClosingAll() -> Bool {
        let names = activeSessions.map { $0.backend.profile.name }
        return names.isEmpty || !AppSettings.shouldConfirmClosingSessions || CloseConfirmation.application(names)
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
        let credentials = SessionCredentials(password: password, gatewayPassword: gatewayPassword)
        let tab = SessionTab(backend: makeSession(profile, credentials), credentials: credentials, makeSession: makeSession)
        tabSubscriptions[tab.id] = tab.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        tabs.append(tab)
        selectedID = tab.id
        tab.start()
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].stopRecording()
        tabs[index].stop()
        tabSubscriptions[id] = nil
        tabs.remove(at: index)
        if selectedID == id { selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
    }

    func disconnectAll() {
        tabs.forEach { $0.stopRecording(); $0.stop() }
        tabs.removeAll()
        tabSubscriptions.removeAll()
        selectedID = nil
    }
}
