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
    func testClosingAnActiveSessionCanBeCancelledWithoutStoppingIt() throws {
        let manager = ConnectionManager { profile, _ in TestSession(profile: profile) }
        manager.connect(ConnectionProfile(name: "Connected", host: "host.local"))
        let tab = try XCTUnwrap(manager.selected)
        let backend = try XCTUnwrap(tab.backend as? TestSession)
        var confirmations = 0
        manager.requestClose(tab.id) { name in confirmations += 1; XCTAssertEqual(name, "Connected"); return false }
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(backend.stopCount, 0)
        XCTAssertEqual(manager.selectedID, tab.id)
        manager.requestClose(tab.id) { _ in true }
        XCTAssertEqual(backend.stopCount, 1)
        XCTAssertTrue(manager.tabs.isEmpty)
    }

    func testSwitchingTabsActivatesOnlyTheSelectedBackend() throws {
        let manager = ConnectionManager { profile, _ in TestSession(profile: profile) }
        manager.connect(ConnectionProfile(name: "One", host: "one.local"))
        let first = try XCTUnwrap(manager.selected)
        manager.connect(ConnectionProfile(name: "Two", host: "two.local"))
        let second = try XCTUnwrap(manager.selected)
        XCTAssertFalse((first.backend as! TestSession).active)
        XCTAssertTrue((second.backend as! TestSession).active)
        manager.selectedID = first.id
        XCTAssertTrue((first.backend as! TestSession).active)
        XCTAssertFalse((second.backend as! TestSession).active)
        manager.disconnectAll()
    }

    func testActiveSessionStateClearsWhenTheBackendDisconnects() throws {
        var sessions: [TestSession] = []
        let manager = ConnectionManager { profile, _ in
            let session = TestSession(profile: profile)
            sessions.append(session)
            return session
        }

        manager.connect(ConnectionProfile(name: "Office", host: "office.local"))
        XCTAssertTrue(manager.hasActiveSessions)

        sessions[0].status = .disconnected(reason: nil)
        XCTAssertFalse(manager.hasActiveSessions)
    }

    func testOptedInReconnectRestartsTheSameTabWithBoundedRetry() throws {
        var sessions: [TestSession] = []
        let manager = ConnectionManager { profile, _ in
            let session = TestSession(profile: profile)
            sessions.append(session)
            return session
        }
        var profile = ConnectionProfile(name: "Office", host: "office.local")
        profile.reconnectsAutomatically = true
        manager.connect(profile)
        let tab = try XCTUnwrap(manager.selected)

        sessions[0].status = .disconnected(reason: "network")
        let reconnected = expectation(description: "session restarted")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            XCTAssertEqual(sessions.count, 2)
            XCTAssertEqual(manager.tabs.count, 1)
            XCTAssertTrue(manager.selected === tab)
            XCTAssertEqual(sessions[1].startCount, 1)
            reconnected.fulfill()
        }
        wait(for: [reconnected], timeout: 2)
        manager.disconnectAll()
    }

    func testManualCloseCancelsAnOptedInReconnect() throws {
        var sessions: [TestSession] = []
        let manager = ConnectionManager { profile, _ in
            let session = TestSession(profile: profile)
            sessions.append(session)
            return session
        }
        var profile = ConnectionProfile(name: "Office", host: "office.local")
        profile.reconnectsAutomatically = true
        manager.connect(profile)
        let id = try XCTUnwrap(manager.selectedID)
        sessions[0].status = .disconnected(reason: "network")
        manager.close(id)

        let settled = expectation(description: "retry cancelled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            XCTAssertEqual(sessions.count, 1)
            XCTAssertTrue(manager.tabs.isEmpty)
            settled.fulfill()
        }
        wait(for: [settled], timeout: 2)
    }

    func testSupersededBackendCannotScheduleAnotherReconnect() throws {
        var sessions: [TestSession] = []
        let manager = ConnectionManager { profile, _ in
            let session = TestSession(profile: profile)
            sessions.append(session)
            return session
        }
        var profile = ConnectionProfile(name: "Office", host: "office.local")
        profile.reconnectsAutomatically = true
        manager.connect(profile)
        sessions[0].status = .disconnected(reason: "network")

        let restarted = expectation(description: "replacement session starts")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            XCTAssertEqual(sessions.count, 2)
            // The old backend may still emit a final notification after it has
            // been replaced. It must not create a third session.
            sessions[0].status = .disconnected(reason: "late notification")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                XCTAssertEqual(sessions.count, 2)
                manager.disconnectAll()
                restarted.fulfill()
            }
        }
        wait(for: [restarted], timeout: 3)
    }

}

private final class TestSession: RemoteSession {
    let profile: ConnectionProfile
    @Published var status: SessionStatus = .idle
    var active = false
    func setActive(_ active: Bool) { self.active = active }
    var startCount = 0
    var stopCount = 0
    init(profile: ConnectionProfile) { self.profile = profile }
    func start() { startCount += 1; status = .connected }
    func stop() { stopCount += 1; status = .disconnected(reason: nil) }
    func makeScreenView() -> AnyView { AnyView(EmptyView()) }
}
