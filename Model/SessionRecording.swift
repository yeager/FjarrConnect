import AppKit
import AVFoundation
import CoreImage

/// Captures one embedded graphical session as a local H.264 movie. The recorder
/// deliberately receives an NSView rather than a window so it never records the
/// sidebar, credentials dialogs, or a different session tab.
final class SessionRecordingController: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var outputURL: URL?
    @Published private(set) var errorMessage: String?

    private weak var sourceView: NSView?
    private var movieWriter: SessionMovieWriter?
    private var movieWriterOutputURL: URL?
    private var recordingGeneration = UUID()
    private var captureTimer: Timer?
    private var frameWritePending = false
    private var finalizingGenerations: [UUID] = []
    private var finalizationCompletions: [() -> Void] = []
    private let frameRate: Int32 = 10
    private let writerQueue = DispatchQueue(label: "se.fjarrconnect.recording", qos: .utility)
    private let destination: (String) -> URL

    init(destination: @escaping (String) -> URL = { SessionRecordingController.recordingDestination(for: $0) }) {
        self.destination = destination
    }

    deinit { captureTimer?.invalidate() }

    func start(capturing view: NSView, profileName: String) {
        guard !isRecording else { return }
        sourceView = view
        recordingGeneration = UUID()
        errorMessage = nil
        outputURL = nil
        isRecording = true
        frameWritePending = false
        let destination = destination(profileName)
        outputURL = destination
        movieWriterOutputURL = destination
        RecordingLibrary.beginWriting(destination)
        movieWriter = SessionMovieWriter(outputURL: destination, frameRate: frameRate)
        captureFrame()
        let timer = Timer(timeInterval: 1 / Double(frameRate), repeats: true) { [weak self] _ in
            self?.captureFrame()
        }
        captureTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop(completion: (() -> Void)? = nil) {
        guard isRecording else {
            if !finalizingGenerations.isEmpty {
                if let completion { finalizationCompletions.append(completion) }
            } else {
                completion?()
            }
            return
        }
        captureTimer?.invalidate()
        captureTimer = nil
        isRecording = false
        sourceView = nil
        frameWritePending = false
        let movieWriter = self.movieWriter
        let finishingGeneration = recordingGeneration
        let finishingURL = movieWriterOutputURL
        finalizingGenerations.append(finishingGeneration)
        if let completion { finalizationCompletions.append(completion) }
        self.movieWriter = nil
        movieWriterOutputURL = nil
        let queue = writerQueue
        queue.async { [self, movieWriter] in
            let didFinish: (Error?) -> Void = { [self, movieWriter] error in
                DispatchQueue.main.async {
                    if let finishingURL { RecordingLibrary.finishWriting(finishingURL) }
                    if self.recordingGeneration == finishingGeneration, error != nil {
                        self.errorMessage = NSLocalizedString("record.error", comment: "")
                    }
                    self.finalizingGenerations.removeAll { $0 == finishingGeneration }
                    let completions = self.finalizingGenerations.isEmpty
                        ? self.takeFinalizationCompletions()
                        : []
                    withExtendedLifetime(movieWriter) { completions.forEach { $0() } }
                }
            }
            if let movieWriter {
                movieWriter.finish(completion: didFinish)
            } else {
                didFinish(CocoaError(.fileWriteUnknown))
            }
        }
    }

    private func takeFinalizationCompletions() -> [() -> Void] {
        defer { finalizationCompletions.removeAll() }
        return finalizationCompletions
    }

    private func captureFrame() {
        guard isRecording, !frameWritePending, let view = sourceView, let movieWriter,
              let image = snapshot(of: view) else { return }
        frameWritePending = true
        writerQueue.async { [weak self, movieWriter] in
            let failed = movieWriter.append(image) != nil
            DispatchQueue.main.async {
                guard let self, self.movieWriter === movieWriter else { return }
                self.frameWritePending = false
                guard failed else { return }
                self.errorMessage = NSLocalizedString("record.error", comment: "")
                self.stop()
            }
        }
    }

    private func snapshot(of view: NSView) -> CGImage? {
        let bounds = view.bounds.integral
        guard bounds.width > 0, bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: bitmap)
        return bitmap.cgImage
    }

    static var recordingDirectory: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FjarrConnect", isDirectory: true)
    }

    static func recordingDestination(for profileName: String, now: Date = .now) -> URL {
        let safeName = profileName.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let uniqueID = UUID().uuidString.lowercased()
        return recordingDirectory.appendingPathComponent("\(safeName.isEmpty ? "session" : safeName)-\(formatter.string(from: now))-\(uniqueID).mov")
    }
}

/// All Core Image and AVAssetWriter work is serialized away from the main
/// thread. AppKit view snapshots remain in the controller on the main thread.
private final class SessionMovieWriter {
    private let outputURL: URL
    private let frameRate: Int32
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var frameIndex: Int64 = 0

    init(outputURL: URL, frameRate: Int32) {
        self.outputURL = outputURL
        self.frameRate = frameRate
    }

    func append(_ image: CGImage) -> Error? {
        if writer == nil, let error = prepareWriter(for: image) { return error }
        guard let writer, let writerInput, let adaptor = pixelBufferAdaptor else { return nil }
        guard writerInput.isReadyForMoreMediaData else { return nil }
        let buffer: CVPixelBuffer
        do {
            buffer = try makePixelBuffer(from: image, adaptor: adaptor)
        } catch {
            return error
        }

        var format: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                                         imageBuffer: buffer,
                                                                         formatDescriptionOut: &format)
        guard formatStatus == noErr, let format else {
            return NSError(domain: NSOSStatusErrorDomain, code: Int(formatStatus))
        }
        let timestamp = CMTime(value: frameIndex, timescale: frameRate)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: frameRate),
                                        presentationTimeStamp: timestamp,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                                     imageBuffer: buffer,
                                                                     formatDescription: format,
                                                                     sampleTiming: &timing,
                                                                     sampleBufferOut: &sample)
        guard sampleStatus == noErr, let sample else {
            return NSError(domain: NSOSStatusErrorDomain, code: Int(sampleStatus))
        }
        guard writerInput.append(sample) else { return writer.error ?? CocoaError(.fileWriteUnknown) }
        frameIndex += 1
        return nil
    }

    func finish(completion: @escaping (Error?) -> Void) {
        guard let writer else {
            // A session that never produced a capturable frame has no movie to
            // finalize; report that to the controller instead of silent success.
            completion(CocoaError(.fileWriteUnknown))
            return
        }
        guard writer.status == .writing else {
            completion(writer.status == .completed ? nil : writer.error ?? CocoaError(.fileWriteUnknown))
            return
        }
        writerInput?.markAsFinished()
        writer.finishWriting {
            completion(writer.status == .completed ? nil : writer.error ?? CocoaError(.fileWriteUnknown))
        }
    }

    private func prepareWriter(for image: CGImage) -> Error? {
        let width = image.width + (image.width % 2)
        let height = image.height + (image.height % 2)
        do {
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ])
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                                 sourcePixelBufferAttributes: [
                                                                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                                                    kCVPixelBufferWidthKey as String: width,
                                                                    kCVPixelBufferHeightKey as String: height,
                                                                 ])
            guard writer.canAdd(input) else { return CocoaError(.fileWriteUnknown) }
            writer.add(input)
            guard writer.startWriting() else { return writer.error ?? CocoaError(.fileWriteUnknown) }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            writerInput = input
            pixelBufferAdaptor = adaptor
            return nil
        } catch {
            return error
        }
    }

    private func makePixelBuffer(from image: CGImage,
                                 adaptor: AVAssetWriterInputPixelBufferAdaptor) throws -> CVPixelBuffer {
        guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        ciContext.render(CIImage(cgImage: image), to: buffer)
        return buffer
    }

}

struct RecordingFile: Identifiable, Equatable {
    let url: URL
    let createdAt: Date
    let size: Int64
    var id: URL { url }
}

enum RecordingLibraryError: Error {
    case recordingInProgress
}

private final class RecordingOutputRegistry: @unchecked Sendable {
    let lock = NSLock()
    var activeURLs = Set<URL>()
    var idleWaiters: [() -> Void] = []
}

enum RecordingLibrary {
    private static let registry = RecordingOutputRegistry()

    static func beginWriting(_ url: URL) {
        registry.lock.lock()
        registry.activeURLs.insert(url.standardizedFileURL)
        registry.lock.unlock()
    }

    static func finishWriting(_ url: URL) {
        registry.lock.lock()
        registry.activeURLs.remove(url.standardizedFileURL)
        let waiters = registry.activeURLs.isEmpty ? registry.idleWaiters : []
        if registry.activeURLs.isEmpty { registry.idleWaiters.removeAll() }
        registry.lock.unlock()
        deliverWhenIdle(waiters)
    }

    /// Runs after every recording, including one whose tab has already closed,
    /// has finished writing its container metadata.
    static func whenNoActiveRecordings(_ completion: @escaping () -> Void) {
        registry.lock.lock()
        guard registry.activeURLs.isEmpty else {
            registry.idleWaiters.append(completion)
            registry.lock.unlock()
            return
        }
        registry.lock.unlock()
        deliverWhenIdle([completion])
    }

    private static func deliverWhenIdle(_ completions: [() -> Void]) {
        guard !completions.isEmpty else { return }
        DispatchQueue.main.async {
            registry.lock.lock()
            guard registry.activeURLs.isEmpty else {
                registry.idleWaiters.append(contentsOf: completions)
                registry.lock.unlock()
                return
            }
            registry.lock.unlock()
            completions.forEach { $0() }
        }
    }

    static func files(in directory: URL = SessionRecordingController.recordingDirectory,
                      fileManager: FileManager = .default) -> [RecordingFile] {
        // Keep registration and enumeration ordered: a new output cannot be
        // created between the active-file snapshot and the directory scan.
        registry.lock.lock()
        defer { registry.lock.unlock() }
        guard let urls = try? fileManager.contentsOfDirectory(at: directory,
                                                               includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                                                               options: [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap { url in
            guard !registry.activeURLs.contains(url.standardizedFileURL),
                  url.pathExtension.lowercased() == "mov",
                  let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey]),
                  let createdAt = values.creationDate else { return nil }
            return RecordingFile(url: url, createdAt: createdAt, size: Int64(values.fileSize ?? 0))
        }.sorted { $0.createdAt > $1.createdAt }
    }

    static func delete(_ url: URL, fileManager: FileManager = .default) throws {
        registry.lock.lock()
        defer { registry.lock.unlock() }
        guard !registry.activeURLs.contains(url.standardizedFileURL) else {
            throw RecordingLibraryError.recordingInProgress
        }
        try fileManager.removeItem(at: url)
    }

    @discardableResult
    static func cleanup(olderThan days: Int, in directory: URL = SessionRecordingController.recordingDirectory,
                        now: Date = .now, fileManager: FileManager = .default) -> Int {
        guard days > 0, let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else { return 0 }
        var removed = 0
        for file in files(in: directory, fileManager: fileManager) where file.createdAt < cutoff {
            if (try? delete(file.url, fileManager: fileManager)) != nil { removed += 1 }
        }
        return removed
    }
}

protocol SessionRecordingSource: AnyObject {
    var recordingView: NSView? { get }
}
