#if canImport(CFNetwork)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import CFNetwork
import CoreFoundation
import Dispatch
import Security

/// Apple socket streams can enable TLS on an open stream, preserving the TCP
/// connection required by VeNCrypt. This transport is intentionally separate
/// from `NWConnection`, whose parameters cannot be changed after it starts.
/// Immutable settings, locked lifecycle state, and per-stream serial queues make
/// cross-task operations safe; the class itself does not expose mutable state.
final class CFStreamNetworkConnection: TLSUpgradableNetworkConnection, @unchecked Sendable {
	let settings: NetworkConnectionSettings

	private let state = CFStreamNetworkState()
	private let ioLoop = CFStreamRunLoop()
	// These fields are only accessed on ioLoop.
	private var readStream: CFReadStream?
	private var writeStream: CFWriteStream?
	private var pendingReads: [PendingRead] = []
	private var pendingWrites: [PendingWrite] = []
	private var isCancelled = false
	private var readFailure: Error?
	private var writeFailure: Error?

	private struct PendingRead {
		let minimumLength: Int
		let maximumLength: Int
		var bytes: [UInt8] = []
		let continuation: CheckedContinuation<Data, Error>
	}

	private struct PendingWrite {
		let bytes: [UInt8]
		var offset = 0
		let continuation: CheckedContinuation<Void, Error>
	}

	init(settings: NetworkConnectionSettings) {
		self.settings = settings
	}

	deinit {
		let readStream = self.readStream
		let writeStream = self.writeStream
		let runLoop = ioLoop.runLoop
		_ = ioLoop.performAndStop {
			if let readStream {
				CFReadStreamSetClient(readStream, 0, nil, nil)
				CFReadStreamUnscheduleFromRunLoop(readStream, runLoop, CFRunLoopMode.defaultMode!)
				CFReadStreamClose(readStream)
			}
			if let writeStream {
				CFWriteStreamSetClient(writeStream, 0, nil, nil)
				CFWriteStreamUnscheduleFromRunLoop(writeStream, runLoop, CFRunLoopMode.defaultMode!)
				CFWriteStreamClose(writeStream)
			}
		}
	}

    static func safeTLSFailureCode(domain: Int, code: Int32) -> Int32? {
        domain == Int(kCFStreamErrorDomainSSL) ? code : nil
    }

	var status: NetworkConnectionStatus { state.status }

	var isReady: Bool {
		if case .ready = state.status { return true }
		return false
	}

    var verifiedTLSCertificate: VNCTLSCertificateInfo? { state.verifiedTLSCertificate }
    var tlsFailureCode: Int32? { state.tlsFailureCode }

	func setStatusUpdateHandler(_ statusUpdateHandler: NetworkConnectionStatusUpdateHandler?) {
		state.setStatusUpdateHandler(statusUpdateHandler)
	}

	func start(queue: DispatchQueue) {
		let state = self.state
		let host = settings.host
		let port = UInt32(settings.port)
		state.lifecycleQueue = queue
		state.updateStatus(.preparing)
		_ = ioLoop.perform { [self] in
			guard !isCancelled else { return }
			var readStream: Unmanaged<CFReadStream>?
			var writeStream: Unmanaged<CFWriteStream>?
			CFStreamCreatePairWithSocketToHost(
				kCFAllocatorDefault,
				host as CFString,
				port,
				&readStream,
				&writeStream
			)

			guard let read = readStream?.takeRetainedValue(),
				  let write = writeStream?.takeRetainedValue() else {
				queue.async { state.updateStatus(.failed(VNCError.connection(.failed(nil)))) }
				return
			}
			self.readStream = read
			self.writeStream = write
			let callbackContext = CFStreamCallbackContext(self)
			var context = CFStreamClientContext(
				version: 0,
				info: Unmanaged.passUnretained(callbackContext).toOpaque(),
				retain: { info in
					guard let info else { return nil }
					return Unmanaged<CFStreamCallbackContext>.fromOpaque(info).retain().toOpaque()
				},
				release: { info in
					guard let info else { return }
					Unmanaged<CFStreamCallbackContext>.fromOpaque(info).release()
				},
				copyDescription: nil
			)
			let readEvents: CFOptionFlags = CFStreamEventType([.hasBytesAvailable, .errorOccurred, .endEncountered]).rawValue
			let writeEvents: CFOptionFlags = CFStreamEventType([.canAcceptBytes, .errorOccurred, .endEncountered]).rawValue
			guard CFReadStreamSetClient(read, readEvents, { stream, event, info in
				guard let stream, let info,
					  let connection = Unmanaged<CFStreamCallbackContext>.fromOpaque(info).takeUnretainedValue().connection else { return }
				connection.handleReadEvent(stream, event: event)
			}, &context),
			CFWriteStreamSetClient(write, writeEvents, { stream, event, info in
				guard let stream, let info,
					  let connection = Unmanaged<CFStreamCallbackContext>.fromOpaque(info).takeUnretainedValue().connection else { return }
				connection.handleWriteEvent(stream, event: event)
			}, &context) else {
				CFReadStreamClose(read)
				CFWriteStreamClose(write)
				self.readStream = nil
				self.writeStream = nil
				queue.async { state.updateStatus(.failed(VNCError.connection(.failed(nil)))) }
				return
			}
			CFReadStreamScheduleWithRunLoop(read, self.ioLoop.runLoop, CFRunLoopMode.defaultMode!)
			CFWriteStreamScheduleWithRunLoop(write, self.ioLoop.runLoop, CFRunLoopMode.defaultMode!)
			guard CFReadStreamOpen(read), CFWriteStreamOpen(write) else {
				self.closeStreams()
				queue.async { state.updateStatus(.failed(VNCError.connection(.failed(nil)))) }
				return
			}
			queue.async { state.updateStatus(.ready) }
		}
	}

	func cancel() {
		let state = self.state
		state.markCancelled()
		guard ioLoop.performAndStop({ [self] in
			guard !isCancelled else { return }
			isCancelled = true
			for operation in pendingReads {
				operation.continuation.resume(throwing: VNCError.connection(.closed))
			}
			pendingReads.removeAll()
			for operation in pendingWrites {
				operation.continuation.resume(throwing: VNCError.connection(.closed))
			}
			pendingWrites.removeAll()
			closeStreams()
			state.lifecycleQueue.async { state.updateStatus(.cancelled) }
		}) else {
			state.lifecycleQueue.async { state.updateStatus(.cancelled) }
			return
		}
	}

	func upgradeToTLS(serverName: String) async throws {
		let state = self.state
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			guard ioLoop.perform({ [self] in
				guard let readStream = self.readStream, state.canUpgradeToTLS,
					  pendingReads.isEmpty, pendingWrites.isEmpty else {
					continuation.resume(throwing: VNCError.protocol(.invalidData))
					return
				}

				let settings: [CFString: Any] = [
					kCFStreamSSLPeerName: serverName,
					kCFStreamSSLValidatesCertificateChain: true,
					kCFStreamSSLLevel: kCFStreamSocketSecurityLevelNegotiatedSSL
				]

				guard CFReadStreamSetProperty(readStream, CFStreamPropertyKey(kCFStreamPropertySSLSettings), settings as CFDictionary) else {
					continuation.resume(throwing: VNCError.connection(.failed(nil)))
					return
				}

				state.markTLSUpgradeComplete()
				continuation.resume()
			}) else {
				continuation.resume(throwing: VNCError.connection(.closed))
				return
			}
		}
	}

	func read(minimumLength: Int, maximumLength: Int) async throws -> Data {
		return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
			guard ioLoop.perform({ [self] in
				guard !isCancelled else {
					continuation.resume(throwing: VNCError.connection(.closed))
					return
				}
				if let readFailure {
					continuation.resume(throwing: readFailure)
					return
				}
				guard let readStream = self.readStream else {
					continuation.resume(throwing: VNCError.connection(.closed))
					return
				}
				guard maximumLength > 0, minimumLength >= 0, minimumLength <= maximumLength else {
					continuation.resume(throwing: VNCError.protocol(.noData))
					return
				}
				pendingReads.append(PendingRead(
					minimumLength: max(1, minimumLength),
					maximumLength: maximumLength,
					continuation: continuation
				))
				readAvailableBytes(from: readStream)
			}) else {
				continuation.resume(throwing: VNCError.connection(.closed))
				return
			}
		}
	}

    private func captureVerifiedCertificate(from readStream: CFReadStream) {
        guard state.tlsUpgradeWasConfigured, state.verifiedTLSCertificate == nil,
              let trustValue = CFReadStreamCopyProperty(
                readStream, CFStreamPropertyKey(kCFStreamPropertySSLPeerTrust)
              ),
              CFGetTypeID(trustValue) == SecTrustGetTypeID() else { return }
        let trust = unsafeBitCast(trustValue, to: SecTrust.self)
        guard let certificate = leafCertificate(from: trust) else { return }

        let subject = SecCertificateCopySubjectSummary(certificate) as String?
        let der = SecCertificateCopyData(certificate) as Data
        state.saveVerifiedTLSCertificate(VNCTLSCertificateInfo(
            subjectSummary: subject,
            derEncodedCertificate: der
        ))
    }

    private func captureTLSFailure(from readStream: CFReadStream) {
        guard state.tlsUpgradeWasConfigured else { return }
        let streamError = CFReadStreamGetError(readStream)
        guard let code = Self.safeTLSFailureCode(domain: streamError.domain, code: streamError.error) else { return }
        state.saveTLSFailureCode(code)
    }

    private func leafCertificate(from trust: SecTrust) -> SecCertificate? {
        guard #available(macOS 12.0, *) else { return nil }
        return (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
    }

	func write(data: Data) async throws {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			guard ioLoop.perform({ [self] in
				guard !isCancelled else {
					continuation.resume(throwing: VNCError.connection(.closed))
					return
				}
				if let writeFailure {
					continuation.resume(throwing: writeFailure)
					return
				}
				guard let writeStream = self.writeStream else {
					continuation.resume(throwing: VNCError.connection(.closed))
					return
				}
				pendingWrites.append(PendingWrite(bytes: Array(data), continuation: continuation))
				writeAvailableBytes(to: writeStream)
			}) else {
				continuation.resume(throwing: VNCError.connection(.closed))
				return
			}
		}
	}

	private func handleReadEvent(_ stream: CFReadStream, event: CFStreamEventType) {
		guard stream == readStream else { return }
		switch event {
		case .hasBytesAvailable:
			readAvailableBytes(from: stream)
		case .errorOccurred, .endEncountered:
			captureTLSFailure(from: stream)
			let error = VNCError.connection(.closed)
			readFailure = error
			finishPendingReads(with: .failure(error))
		default:
			break
		}
	}

	private func readAvailableBytes(from stream: CFReadStream) {
		while !pendingReads.isEmpty, CFReadStreamHasBytesAvailable(stream) {
			let remaining = pendingReads[0].maximumLength - pendingReads[0].bytes.count
			var buffer = [UInt8](repeating: 0, count: remaining)
			let count = buffer.withUnsafeMutableBufferPointer {
				CFReadStreamRead(stream, $0.baseAddress, remaining)
			}
			guard count > 0 else {
				if count < 0 {
					captureTLSFailure(from: stream)
					readFailure = VNCError.protocol(.noData)
				} else {
					readFailure = VNCError.connection(.closed)
				}
				finishPendingReads(with: .failure(readFailure!))
				return
			}
			pendingReads[0].bytes.append(contentsOf: buffer.prefix(count))
			captureVerifiedCertificate(from: stream)
			if pendingReads[0].bytes.count >= pendingReads[0].minimumLength {
				let operation = pendingReads.removeFirst()
				operation.continuation.resume(returning: Data(operation.bytes))
			}
		}
	}

	private func writeAvailableBytes(to stream: CFWriteStream) {
		while !pendingWrites.isEmpty {
			let remaining = pendingWrites[0].bytes.count - pendingWrites[0].offset
			if remaining == 0 {
				let operation = pendingWrites.removeFirst()
				operation.continuation.resume()
				continue
			}
			guard CFWriteStreamCanAcceptBytes(stream) else { return }
			let count = pendingWrites[0].bytes.withUnsafeBufferPointer {
				CFWriteStreamWrite(stream, $0.baseAddress!.advanced(by: pendingWrites[0].offset), remaining)
			}
			if count < 0 {
				captureTLSFailure(from: stream)
				writeFailure = VNCError.connection(.failed(nil))
				finishPendingWrites(with: .failure(writeFailure!))
				return
			}
			guard count > 0 else { return }
			pendingWrites[0].offset += count
		}
	}

	private func handleWriteEvent(_ stream: CFWriteStream, event: CFStreamEventType) {
		guard stream == writeStream else { return }
		switch event {
		case .canAcceptBytes:
			writeAvailableBytes(to: stream)
		case .errorOccurred, .endEncountered:
			captureTLSFailure(from: stream)
			writeFailure = VNCError.connection(.closed)
			finishPendingWrites(with: .failure(writeFailure!))
		default:
			break
		}
	}

	private func finishPendingReads(with result: Result<Data, Error>) {
		let operations = pendingReads
		pendingReads.removeAll()
		for operation in operations {
			if case .success = result {
				operation.continuation.resume(returning: Data(operation.bytes))
			} else if case let .failure(error) = result {
				operation.continuation.resume(throwing: error)
			}
		}
	}

	private func finishPendingWrites(with result: Result<Void, Error>) {
		let operations = pendingWrites
		pendingWrites.removeAll()
		for operation in operations {
			if case .success = result {
				operation.continuation.resume()
			} else if case let .failure(error) = result {
				operation.continuation.resume(throwing: error)
			}
		}
	}

	private func closeStreams() {
		if let readStream {
			CFReadStreamSetClient(readStream, 0, nil, nil)
			CFReadStreamUnscheduleFromRunLoop(readStream, ioLoop.runLoop, CFRunLoopMode.defaultMode!)
			CFReadStreamClose(readStream)
			self.readStream = nil
		}
		if let writeStream {
			CFWriteStreamSetClient(writeStream, 0, nil, nil)
			CFWriteStreamUnscheduleFromRunLoop(writeStream, ioLoop.runLoop, CFRunLoopMode.defaultMode!)
			CFWriteStreamClose(writeStream)
			self.writeStream = nil
		}
	}

    private func captureTLSFailure(from writeStream: CFWriteStream) {
        guard state.tlsUpgradeWasConfigured else { return }
        let streamError = CFWriteStreamGetError(writeStream)
        guard let code = Self.safeTLSFailureCode(domain: streamError.domain, code: streamError.error) else { return }
        state.saveTLSFailureCode(code)
    }
}

private final class CFStreamCallbackContext {
	weak var connection: CFStreamNetworkConnection?
	init(_ connection: CFStreamNetworkConnection) { self.connection = connection }
}

/// Owns the run loop used for all CFStream scheduling and I/O callbacks.
private final class CFStreamRunLoop {
	private let lock = NSLock()
	private let ready = DispatchSemaphore(value: 0)
	private var storedRunLoop: CFRunLoop?
	private var stopped = false
	private var thread: Thread?

	init() {
		let thread = Thread { [weak self] in
			guard let self else { return }
			let runLoop = CFRunLoopGetCurrent()
			var context = CFRunLoopSourceContext(
				version: 0, info: nil, retain: nil, release: nil, copyDescription: nil,
				equal: nil, hash: nil, schedule: nil, cancel: nil, perform: { _ in }
			)
			guard let keepAlive = CFRunLoopSourceCreate(nil, 0, &context) else {
				ready.signal()
				return
			}
			CFRunLoopAddSource(runLoop, keepAlive, CFRunLoopMode.defaultMode!)
			lock.lock()
			storedRunLoop = runLoop
			lock.unlock()
			ready.signal()
			CFRunLoopRun()
			CFRunLoopRemoveSource(runLoop, keepAlive, CFRunLoopMode.defaultMode!)
		}
		self.thread = thread
		thread.name = "com.royalapps.royalvnc.cfstream"
		thread.start()
		ready.wait()
	}

	var runLoop: CFRunLoop {
		lock.lock()
		defer { lock.unlock() }
		return storedRunLoop!
	}

	func perform(_ action: @escaping () -> Void) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		guard !stopped, let runLoop = storedRunLoop else { return false }
		CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode!.rawValue, action)
		CFRunLoopWakeUp(runLoop)
		return true
	}

	func performAndStop(_ action: @escaping () -> Void) -> Bool {
		lock.lock()
		guard !stopped, let runLoop = storedRunLoop else {
			lock.unlock()
			return false
		}
		stopped = true
		CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode!.rawValue) {
			action()
			CFRunLoopStop(runLoop)
		}
		CFRunLoopWakeUp(runLoop)
		lock.unlock()
		return true
	}
}

/// Synchronizes state shared by the lifecycle, read and write queues. The
/// lock is never held while performing stream I/O or invoking callbacks.
private final class CFStreamNetworkState: @unchecked Sendable {
	private let lock = NSLock()
	private var storedStatus: NetworkConnectionStatus = .setup
	private var storedStatusUpdateHandler: NetworkConnectionStatusUpdateHandler?
	private var storedLifecycleQueue = DispatchQueue(label: "com.royalapps.royalvnc.cfstream.lifecycle")
	private var didUpgradeToTLS = false
	private var wasCancelled = false
    private var storedVerifiedTLSCertificate: VNCTLSCertificateInfo?
    private var storedTLSFailureCode: Int32?

    var verifiedTLSCertificate: VNCTLSCertificateInfo? {
        lock.lock()
        defer { lock.unlock() }
        return storedVerifiedTLSCertificate
    }

    var tlsUpgradeWasConfigured: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didUpgradeToTLS
    }

    var tlsFailureCode: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return storedTLSFailureCode
    }

    func saveVerifiedTLSCertificate(_ certificate: VNCTLSCertificateInfo) {
        lock.lock()
        if storedVerifiedTLSCertificate == nil { storedVerifiedTLSCertificate = certificate }
        lock.unlock()
    }

    func saveTLSFailureCode(_ code: Int32) {
        lock.lock()
        if storedTLSFailureCode == nil { storedTLSFailureCode = code }
        lock.unlock()
    }

	var status: NetworkConnectionStatus {
		lock.lock()
		defer { lock.unlock() }
		return storedStatus
	}

	var lifecycleQueue: DispatchQueue {
		get {
			lock.lock()
			defer { lock.unlock() }
			return storedLifecycleQueue
		}
		set {
			lock.lock()
			storedLifecycleQueue = newValue
			lock.unlock()
		}
	}

	var canUpgradeToTLS: Bool {
		lock.lock()
		defer { lock.unlock() }
		return !didUpgradeToTLS && !wasCancelled
	}

	func setStatusUpdateHandler(_ handler: NetworkConnectionStatusUpdateHandler?) {
		lock.lock()
		storedStatusUpdateHandler = handler
		lock.unlock()
	}

	func updateStatus(_ status: NetworkConnectionStatus) {
		lock.lock()
		storedStatus = status
		let handler = storedStatusUpdateHandler
		lock.unlock()
		handler?(status)
	}

	func markTLSUpgradeComplete() {
		lock.lock()
		didUpgradeToTLS = true
		lock.unlock()
	}

	func markCancelled() {
		lock.lock()
		wasCancelled = true
		lock.unlock()
	}
}
#endif
