import AppKit
import Darwin

/// The decoder is packaged separately for each Mac architecture. Its C ABI
/// returns an NSView owned by the session; it never launches another app.
final class RDPRuntime {
    enum LoadFailure: Error, Equatable {
        case missingFile
        case architectureMismatch
        case signatureRejected
        case dependencyUnavailable
        case incompatibleABI
        case loadFailed

        var localizationKey: String {
            switch self {
            case .missingFile: "rdp.install.reason.missing"
            case .architectureMismatch: "rdp.install.reason.architecture"
            case .signatureRejected: "rdp.install.reason.signature"
            case .dependencyUnavailable: "rdp.install.reason.dependency"
            case .incompatibleABI: "rdp.install.reason.abi"
            case .loadFailed: "rdp.install.reason.other"
            }
        }

        static func classifyDyldError(_ message: String) -> LoadFailure {
            let message = message.lowercased()
            if message.contains("wrong architecture") || message.contains("incompatible architecture") ||
                message.contains("no suitable image") {
                return .architectureMismatch
            }
            if message.contains("code signature") || message.contains("signature is invalid") {
                return .signatureRejected
            }
            if message.contains("library not loaded") || message.contains("image not found") {
                return .dependencyUnavailable
            }
            return .loadFailed
        }
    }

    private enum LoadState {
        case available(RDPRuntime)
        case failed(LoadFailure)
    }

    typealias Create = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
    typealias Action = @convention(c) (UnsafeMutableRawPointer) -> Void
    typealias Activate = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    typealias Status = @convention(c) (UnsafeMutableRawPointer) -> Int32
    typealias FrameStatus = @convention(c) (UnsafeMutableRawPointer) -> Int32
    typealias ErrorCode = @convention(c) (UnsafeMutableRawPointer) -> UInt32
    typealias Codec = @convention(c) (UnsafeMutableRawPointer) -> UnsafePointer<CChar>?
    typealias Phase = @convention(c) (UnsafeMutableRawPointer) -> UnsafePointer<CChar>?
    typealias ProtocolFlags = @convention(c) (UnsafeMutableRawPointer) -> UInt32
    typealias InputState = @convention(c) (UnsafeMutableRawPointer) -> UInt32
    typealias Measurement = @convention(c) (UnsafeMutableRawPointer) -> UInt32
    let create: Create
    let start: Action
    let stop: Action
    let activate: Activate
    let secureAttention: Action
    let status: Status
    let hasFrame: FrameStatus
    let error: ErrorCode
    let failure: Status
    let codec: Codec
    let phase: Phase
    let requestedProtocols: ProtocolFlags
    let selectedProtocol: ProtocolFlags
    let inputState: InputState
    let roundTripMilliseconds: Measurement
    private let library: UnsafeMutableRawPointer

    private static let loadState: LoadState = {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libFjarrRDP.dylib").path
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["FJARRCONNECT_RDP_LIBRARY"], path.hasPrefix("/") {
            return resolve(path: path)
        }
        #endif
        return resolve(path: bundled)
    }()

    static var shared: RDPRuntime? {
        guard case .available(let runtime) = loadState else { return nil }
        return runtime
    }

    private static func resolve(path: String) -> LoadState {
        guard FileManager.default.fileExists(atPath: path) else { return .failed(.missingFile) }
        var failure = LoadFailure.loadFailed
        guard let runtime = RDPRuntime(path: path, onFailure: { failure = $0 }) else {
            return .failed(failure)
        }
        return .available(runtime)
    }

    /// Resolve the embedded runtime away from AppKit's main thread. Loading the
    /// FreeRDP dylib can trigger dyld path and code-signature work that stalls
    /// the UI when a profile is selected for the first time.
    static func load(completion: @escaping (Result<Void, LoadFailure>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            #if DEBUG
            if let delay = ProcessInfo.processInfo.environment["FJARRCONNECT_TEST_RDP_LOAD_DELAY"]
                .flatMap(Double.init), delay > 0 {
                Thread.sleep(forTimeInterval: min(delay, 30))
            }
            #endif
            let result: Result<Void, LoadFailure>
            switch loadState {
            case .available: result = .success(())
            case .failed(let failure): result = .failure(failure)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    init?(path: String, onFailure: ((LoadFailure) -> Void)? = nil) {
        guard FileManager.default.fileExists(atPath: path) else {
            onFailure?(.missingFile)
            return nil
        }
        _ = dlerror()
        guard let library = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            let message = dlerror().map { String(cString: $0) } ?? ""
            onFailure?(LoadFailure.classifyDyldError(message))
            return nil
        }
        func function<T>(_ name: String, _: T.Type) -> T? {
            guard let symbol = dlsym(library, name) else { return nil }
            return unsafeBitCast(symbol, to: T.self)
        }
        guard let abi = function("fc_rdp_abi", (@convention(c) () -> UInt32).self), abi() == 8,
              let create = function("fc_rdp_create", Create.self),
              let start = function("fc_rdp_start", Action.self),
              let stop = function("fc_rdp_stop", Action.self),
              let activate = function("fc_rdp_set_active", Activate.self),
              let secureAttention = function("fc_rdp_secure_attention", Action.self),
              let status = function("fc_rdp_status", Status.self),
              let hasFrame = function("fc_rdp_has_frame", FrameStatus.self),
              let error = function("fc_rdp_error", ErrorCode.self),
              let failure = function("fc_rdp_failure", Status.self),
              let codec = function("fc_rdp_codec", Codec.self),
              let phase = function("fc_rdp_connection_phase", Phase.self),
              let requestedProtocols = function("fc_rdp_requested_protocols", ProtocolFlags.self),
              let selectedProtocol = function("fc_rdp_selected_protocol", ProtocolFlags.self),
              let inputState = function("fc_rdp_input_state", InputState.self),
              let roundTripMilliseconds = function("fc_rdp_round_trip_milliseconds", Measurement.self) else {
            dlclose(library)
            onFailure?(.incompatibleABI)
            return nil
        }
        self.library = library
        self.create = create; self.start = start; self.stop = stop
        self.activate = activate; self.secureAttention = secureAttention
        self.status = status; self.hasFrame = hasFrame
        self.error = error; self.failure = failure; self.codec = codec; self.phase = phase
        self.requestedProtocols = requestedProtocols; self.selectedProtocol = selectedProtocol
        self.inputState = inputState
        self.roundTripMilliseconds = roundTripMilliseconds
        // Objective-C classes remain registered for the lifetime of the process.
        // Do not dlclose a library that has registered view classes.
    }

    static let localizationKeys = [
        "action.cancel", "action.connect", "field.host", "rdp.cert.title", "rdp.cert.message",
        "rdp.cert.changed.title", "rdp.cert.changed.message", "rdp.cert.mismatch", "rdp.cert.name",
        "rdp.cert.subject", "rdp.cert.issuer", "rdp.cert.fingerprint", "rdp.cert.previous",
        "rdp.cert.once", "rdp.cert.trust", "rdp.gateway.message"
    ]
    static var translations: String {
        let strings = Dictionary(uniqueKeysWithValues: localizationKeys.map { ($0, NSLocalizedString($0, comment: "")) })
        return String(decoding: (try? JSONEncoder().encode(strings)) ?? Data("{}".utf8), as: UTF8.self)
    }
}
