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
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var captureTimer: Timer?
    private var startedAt: CFTimeInterval = 0
    private var frameIndex: Int64 = 0
    private let frameRate: Int32 = 10
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let destination: (String) -> URL

    init(destination: @escaping (String) -> URL = { SessionRecordingController.recordingDestination(for: $0) }) {
        self.destination = destination
    }

    deinit { captureTimer?.invalidate() }

    func start(capturing view: NSView, profileName: String) {
        guard !isRecording else { return }
        sourceView = view
        errorMessage = nil
        outputURL = nil
        startedAt = CACurrentMediaTime()
        frameIndex = 0
        isRecording = true
        outputURL = destination(profileName)
        captureFrame()
        captureTimer = Timer.scheduledTimer(withTimeInterval: 1 / Double(frameRate), repeats: true) { [weak self] _ in
            self?.captureFrame()
        }
        RunLoop.main.add(captureTimer!, forMode: .common)
    }

    func stop() {
        guard isRecording else { return }
        captureTimer?.invalidate()
        captureTimer = nil
        isRecording = false
        sourceView = nil
        writerInput?.markAsFinished()
        writer?.finishWriting { }
        writer = nil
        writerInput = nil
        pixelBufferAdaptor = nil
    }

    private func captureFrame() {
        guard isRecording, let view = sourceView, let image = snapshot(of: view) else { return }
        guard prepareWriter(for: image) else { stop(); return }
        guard let writerInput, let adaptor = pixelBufferAdaptor,
              writerInput.isReadyForMoreMediaData,
              let buffer = makePixelBuffer(from: image, adaptor: adaptor) else { return }

        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                            imageBuffer: buffer,
                                                            formatDescriptionOut: &format) == noErr,
              let format else { return }
        let timestamp = CMTime(value: frameIndex, timescale: frameRate)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: frameRate),
                                        presentationTimeStamp: timestamp,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                        imageBuffer: buffer,
                                                        formatDescription: format,
                                                        sampleTiming: &timing,
                                                        sampleBufferOut: &sample) == noErr,
              let sample else { return }
        writerInput.append(sample)
        frameIndex += 1
    }

    private func prepareWriter(for image: CGImage) -> Bool {
        if writer != nil { return true }
        guard let outputURL else { return false }
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
            guard writer.canAdd(input) else { return false }
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            writerInput = input
            pixelBufferAdaptor = adaptor
            return true
        } catch {
            errorMessage = NSLocalizedString("record.error", comment: "")
            return false
        }
    }

    private func snapshot(of view: NSView) -> CGImage? {
        let bounds = view.bounds.integral
        guard bounds.width > 0, bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: bitmap)
        return bitmap.cgImage
    }

    private func makePixelBuffer(from image: CGImage,
                                 adaptor: AVAssetWriterInputPixelBufferAdaptor) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        ciContext.render(CIImage(cgImage: image), to: buffer)
        return buffer
    }

    static func recordingDestination(for profileName: String, now: Date = .now) -> URL {
        let safeName = profileName.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let directory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FjarrConnect", isDirectory: true)
        return directory.appendingPathComponent("\(safeName.isEmpty ? "session" : safeName)-\(formatter.string(from: now)).mov")
    }
}

protocol SessionRecordingSource: AnyObject {
    var recordingView: NSView? { get }
}
