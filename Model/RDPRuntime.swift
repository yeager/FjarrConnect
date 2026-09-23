import AppKit
import Darwin

/// The decoder is packaged separately for each Mac architecture. Its C ABI
/// returns an NSView owned by the session; it never launches another app.
final class RDPRuntime {
    typealias Create = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
    typealias Action = @convention(c) (UnsafeMutableRawPointer) -> Void
    typealias Activate = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    typealias Status = @convention(c) (UnsafeMutableRawPointer) -> Int32
    typealias ErrorCode = @convention(c) (UnsafeMutableRawPointer) -> UInt32
    typealias Codec = @convention(c) (UnsafeMutableRawPointer) -> UnsafePointer<CChar>?
    let create: Create
    let start: Action
    let stop: Action
    let activate: Activate
    let status: Status
    let error: ErrorCode
    let failure: Status
    let codec: Codec
    private let library: UnsafeMutableRawPointer

    static let shared: RDPRuntime? = {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libFjarrRDP.dylib").path
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["FJARRCONNECT_RDP_LIBRARY"], path.hasPrefix("/") {
            return RDPRuntime(path: path)
        }
        #endif
        return RDPRuntime(path: bundled)
    }()

    init?(path: String) {
        guard let library = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { return nil }
        func function<T>(_ name: String, _: T.Type) -> T? {
            guard let symbol = dlsym(library, name) else { return nil }
            return unsafeBitCast(symbol, to: T.self)
        }
        guard let abi = function("fc_rdp_abi", (@convention(c) () -> UInt32).self), abi() == 2,
              let create = function("fc_rdp_create", Create.self),
              let start = function("fc_rdp_start", Action.self),
              let stop = function("fc_rdp_stop", Action.self),
              let activate = function("fc_rdp_set_active", Activate.self),
              let status = function("fc_rdp_status", Status.self),
              let error = function("fc_rdp_error", ErrorCode.self),
              let failure = function("fc_rdp_failure", Status.self),
              let codec = function("fc_rdp_codec", Codec.self) else { dlclose(library); return nil }
        self.library = library
        self.create = create; self.start = start; self.stop = stop
        self.activate = activate; self.status = status; self.error = error; self.failure = failure; self.codec = codec
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
