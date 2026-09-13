import SwiftUI
import Combine

/// Owns the currently active session and bridges its `objectWillChange` up to the
/// UI, so `ContentView` can observe status/screen without knowing the concrete
/// backend type (VNC/RDP/SSH all arrive as `any RemoteSession`).
final class ConnectionManager: ObservableObject {
    @Published private(set) var session: (any RemoteSession)?

    private var cancellable: AnyCancellable?

    func connect(_ profile: ConnectionProfile) {
        let password = KeychainStore.password(for: profile.id)
        guard let session = ProtocolRegistry.makeSession(for: profile, password: password) else { return }

        self.session = session
        cancellable = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        session.start()
    }

    func disconnect() {
        session?.stop()
        session = nil
        cancellable = nil
    }
}
