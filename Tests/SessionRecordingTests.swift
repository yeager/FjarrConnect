import XCTest
import AppKit
import AVFoundation
@testable import FjarrConnect

final class SessionRecordingTests: XCTestCase {
    func testRecorderWritesMovieForEmbeddedView() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("capture.mov")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 48))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.systemBlue.cgColor
        let recorder = SessionRecordingController(destination: { _ in destination })

        recorder.start(capturing: view, profileName: "Test / session")
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        recorder.stop()

        let complete = expectation(description: "movie is finalized")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { complete.fulfill() }
        wait(for: [complete], timeout: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0, 0)
        XCTAssertFalse(recorder.isRecording)
    }

    func testDestinationUsesSafeMovieName() {
        let url = SessionRecordingController.recordingDestination(for: "Office / Mac", now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(url.pathExtension, "mov")
        XCTAssertTrue(url.path.contains("FjarrConnect"))
        XCTAssertFalse(url.lastPathComponent.contains("/"))
    }

    func testRecordingLibrarySearchesMoviesAndCleansByAge() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("old.mov")
        let current = directory.appendingPathComponent("current.mov")
        try Data([1]).write(to: old)
        try Data([1, 2]).write(to: current)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: old.path)

        XCTAssertEqual(RecordingLibrary.files(in: directory).map(\.url).count, 2)
        XCTAssertEqual(RecordingLibrary.cleanup(olderThan: 30, in: directory, now: Date(timeIntervalSince1970: 60 * 60 * 24 * 31)), 1)
        XCTAssertEqual(RecordingLibrary.files(in: directory).map { $0.url.standardizedFileURL.path }, [current.standardizedFileURL.path])
    }
}
