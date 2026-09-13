import XCTest
import SwiftUI
import Combine
@testable import FjarrConnect

final class SessionTests: XCTestCase {
    func testTabsReuseConnectionsWhenOnlyFavoriteOrNameChanges() throws {
        var sessions: [TestSession] = []
        let manager = ConnectionManager { profile, _ in
            let session = TestSession(profile: profile)
            sessions.append(session)
            return session
        }
        var profile = ConnectionProfile(name: "Studio", host: "studio.local")
        manager.connect(profile)
        let id = try XCTUnwrap(manager.selectedID)
        profile.isFavorite = true
        profile.name = "Favorite studio"
        manager.connect(profile)
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.selectedID, id)
        XCTAssertEqual(sessions[0].startCount, 1)
        manager.close(id)
        XCTAssertEqual(sessions[0].stopCount, 1)
        XCTAssertNil(manager.selectedID)
    }

    func testClosingTabsStopsOnlyTheirBackendAndSelectsNeighbor() throws {
        var sessions: [TestSession] = []
        let manager = ConnectionManager { profile, _ in
            let session = TestSession(profile: profile)
            sessions.append(session)
            return session
        }
        manager.connect(ConnectionProfile(name: "One", host: "one.local"))
        let first = try XCTUnwrap(manager.selectedID)
        manager.connect(ConnectionProfile(name: "Two", host: "two.local"))
        let second = try XCTUnwrap(manager.selectedID)
        manager.close(second)
        XCTAssertEqual(manager.selectedID, first)
        XCTAssertEqual(sessions[0].stopCount, 0)
        XCTAssertEqual(sessions[1].stopCount, 1)
        manager.disconnectAll()
        XCTAssertTrue(manager.tabs.isEmpty)
        XCTAssertNil(manager.selectedID)
        XCTAssertEqual(sessions[0].stopCount, 1)
        manager.close(first)
        XCTAssertEqual(sessions[0].stopCount, 1)
    }
}

private final class TestSession: RemoteSession {
    let profile: ConnectionProfile
    @Published var status: SessionStatus = .idle
    var startCount = 0
    var stopCount = 0
    init(profile: ConnectionProfile) { self.profile = profile }
    func start() { startCount += 1; status = .connected }
    func stop() { stopCount += 1; status = .disconnected(reason: nil) }
    func makeScreenView() -> AnyView { AnyView(EmptyView()) }
}
