import XCTest
import AppKit
import AVFoundation
@testable import FjarrConnect

final class SessionRecordingTests: XCTestCase {
    @MainActor
    func testRecorderWritesMovieForEmbeddedView() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("capture.mov")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 48))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.systemBlue.cgColor
        let recorder = SessionRecordingController(destination: { _ in destination })

        recorder.start(capturing: view, profileName: "Test / session")
        try await Task.sleep(nanoseconds: 350_000_000)
        let complete = expectation(description: "movie is finalized")
        recorder.stop { complete.fulfill() }
        await fulfillment(of: [complete], timeout: 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0, 0)
        XCTAssertFalse(recorder.isRecording)
        let asset = AVURLAsset(url: destination)
        let isPlayable = try await asset.load(.isPlayable)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertTrue(isPlayable)
        XCTAssertFalse(videoTracks.isEmpty)
    }

    @MainActor
    func testRepeatedStopWaitsUntilMovieFinalizationCompletes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("repeated-stop.mov")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 48))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.systemBlue.cgColor
        let recorder = SessionRecordingController(destination: { _ in destination })
        recorder.start(capturing: view, profileName: "Test")
        try await Task.sleep(for: .milliseconds(150))

        let firstStop = expectation(description: "first stop waits for the movie")
        let secondStop = expectation(description: "repeated stop waits for the movie")
        var secondStopCompleted = false
        recorder.stop { firstStop.fulfill() }
        recorder.stop {
            secondStopCompleted = true
            secondStop.fulfill()
        }
        XCTAssertFalse(secondStopCompleted,
                       "A repeated stop must not report completion while the writer is still finalizing")
        await fulfillment(of: [firstStop, secondStop], timeout: 10)
        let asset = AVURLAsset(url: destination)
        let isPlayable = try await asset.load(.isPlayable)
        XCTAssertTrue(isPlayable)
    }

    @MainActor
    func testStopReportsFailureWhenNoFrameCouldBeCaptured() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("empty.mov")
        let recorder = SessionRecordingController(destination: { _ in destination })
        recorder.start(capturing: NSView(frame: .zero), profileName: "Empty")

        let stopped = expectation(description: "empty recording reports its failure")
        recorder.stop { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertNotNil(recorder.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    func testImmediateRestartFinalizesEachRecordingIndependently() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var destinations: [URL] = []
        let recordingTime = Date(timeIntervalSince1970: 1_700_000_000)
        let recorder = SessionRecordingController { profileName in
            let productionName = SessionRecordingController.recordingDestination(for: profileName,
                                                                                   now: recordingTime).lastPathComponent
            let destination = directory.appendingPathComponent(productionName)
            destinations.append(destination)
            return destination
        }
        let finished = expectation(description: "both recordings finalize")
        finished.expectedFulfillmentCount = 2

        let firstView = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 48))
        firstView.wantsLayer = true
        firstView.layer?.backgroundColor = NSColor.systemBlue.cgColor
        recorder.start(capturing: firstView, profileName: "Same profile")
        recorder.stop { finished.fulfill() }

        let secondView = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 48))
        secondView.wantsLayer = true
        secondView.layer?.backgroundColor = NSColor.systemRed.cgColor
        recorder.start(capturing: secondView, profileName: "Same profile")
        recorder.stop { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 10)

        XCTAssertEqual(destinations.count, 2)
        XCTAssertNotEqual(destinations[0], destinations[1],
                          "Rapid recordings of the same profile must not reuse the same destination")
        for destination in destinations {
            let asset = AVURLAsset(url: destination)
            let isPlayable = try await asset.load(.isPlayable)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            XCTAssertTrue(isPlayable)
            XCTAssertFalse(videoTracks.isEmpty)
        }
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

    func testRecordingLibraryHidesAndProtectsActiveOutputUntilFinalized() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("active.mov")
        try Data([1, 2, 3]).write(to: output)
        RecordingLibrary.beginWriting(output)
        var isRegistered = true
        defer { if isRegistered { RecordingLibrary.finishWriting(output) } }

        XCTAssertTrue(RecordingLibrary.files(in: directory).isEmpty)
        XCTAssertThrowsError(try RecordingLibrary.delete(output)) { error in
            guard case RecordingLibraryError.recordingInProgress = error else {
                return XCTFail("Expected active recording to be protected")
            }
        }
        XCTAssertEqual(RecordingLibrary.cleanup(olderThan: 1, in: directory,
                                                now: Date(timeIntervalSinceNow: 86400)), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

        let idle = expectation(description: "recording registry becomes idle")
        RecordingLibrary.whenNoActiveRecordings { idle.fulfill() }
        RecordingLibrary.finishWriting(output)
        isRegistered = false
        await fulfillment(of: [idle], timeout: 2)
        XCTAssertEqual(RecordingLibrary.files(in: directory).map { $0.url.standardizedFileURL },
                       [output.standardizedFileURL])
        try RecordingLibrary.delete(output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    @MainActor
    func testIdleWaiterRechecksWhenRecordingStartsBeforeCallbackRuns() async throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        let idle = expectation(description: "idle callback waits for the new recording")
        var callbackRan = false

        RecordingLibrary.whenNoActiveRecordings {
            callbackRan = true
            idle.fulfill()
        }
        RecordingLibrary.beginWriting(output)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(callbackRan,
                       "A recording that starts before main-thread delivery must keep termination waiting")

        RecordingLibrary.finishWriting(output)
        await fulfillment(of: [idle], timeout: 2)
        XCTAssertTrue(callbackRan)
    }

    @MainActor
    func testApplicationTerminationWaitsForRecordingFinalization() async {
        let delegate = FjarrConnectAppDelegate()
        var finishPreparation: (() -> Void)?
        var replies: [Bool] = []
        delegate.shouldTerminate = { true }
        delegate.prepareForTermination = { finishPreparation = $0 }
        delegate.replyToTermination = { _, shouldTerminate in replies.append(shouldTerminate) }

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertTrue(replies.isEmpty)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertNotNil(finishPreparation)

        let replied = expectation(description: "termination reply follows recording finalization")
        delegate.replyToTermination = { _, shouldTerminate in
            replies.append(shouldTerminate)
            replied.fulfill()
        }
        finishPreparation?()
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertEqual(replies, [true])
    }
}
