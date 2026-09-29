#if canImport(CFNetwork)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import CFNetwork
import CoreFoundation
import Dispatch

/// Apple socket streams can enable TLS on an open stream, preserving the TCP
/// connection required by VeNCrypt. This transport is intentionally separate
/// from `NWConnection`, whose parameters cannot be changed after it starts.
final class CFStreamNetworkConnection: TLSUpgradableNetworkConnection {
	let settings: NetworkConnectionSettings

	private let state = CFStreamNetworkState()
	private let readQueue = DispatchQueue(label: "com.royalapps.royalvnc.cfstream.read")
	private let writeQueue = DispatchQueue(label: "com.royalapps.royalvnc.cfstream.write")

	init(settings: NetworkConnectionSettings) {
		self.settings = settings
	}

	var status: NetworkConnectionStatus { state.status }

	var isReady: Bool {
		if case .ready = state.status { return true }
		return false
	}

	func setStatusUpdateHandler(_ statusUpdateHandler: NetworkConnectionStatusUpdateHandler?) {
		state.setStatusUpdateHandler(statusUpdateHandler)
	}

	func start(queue: DispatchQueue) {
		let state = self.state
		let host = settings.host
		let port = UInt32(settings.port)
		state.lifecycleQueue = queue
		state.updateStatus(.preparing)

		queue.async {
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
				  let write = writeStream?.takeRetainedValue(),
			  CFReadStreamOpen(read),
			  CFWriteStreamOpen(write) else {
				state.updateStatus(.failed(VNCError.connection(.failed(nil))))
				return
			}

			guard state.install(readStream: read, writeStream: write) else {
				CFReadStreamClose(read)
				CFWriteStreamClose(write)
				return
			}
			state.updateStatus(.ready)
		}
	}

	func cancel() {
		let state = self.state
		state.markCancelled()
		let group = DispatchGroup()
		group.enter()
		readQueue.async {
			if let readStream = state.takeReadStream() { CFReadStreamClose(readStream) }
			group.leave()
		}
		group.enter()
		writeQueue.async {
			if let writeStream = state.takeWriteStream() { CFWriteStreamClose(writeStream) }
			group.leave()
		}
		group.notify(queue: state.lifecycleQueue) {
			state.updateStatus(.cancelled)
		}
	}

	func upgradeToTLS(serverName: String) async throws {
		let state = self.state
		let readQueue = self.readQueue
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			readQueue.async {
				guard let readStream = state.readStream, state.canUpgradeToTLS else {
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
			}
		}
	}

	func read(minimumLength: Int, maximumLength: Int) async throws -> Data {
		let state = self.state
		let readQueue = self.readQueue
		return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
			readQueue.async {
				guard let readStream = state.readStream else {
					continuation.resume(throwing: VNCError.connection(.closed))
					return
				}

				var buffer = [UInt8](repeating: 0, count: maximumLength)
				var received = 0

				repeat {
					let count = buffer.withUnsafeMutableBufferPointer {
						CFReadStreamRead(readStream, $0.baseAddress?.advanced(by: received), maximumLength - received)
					}
					guard count > 0 else {
						continuation.resume(throwing: VNCError.protocol(.noData))
						return
					}
					received += count
				} while received < minimumLength

				continuation.resume(returning: Data(buffer.prefix(received)))
			}
		}
	}

	func write(data: Data) async throws {
		let state = self.state
		let writeQueue = self.writeQueue
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			writeQueue.async {
				guard let writeStream = state.writeStream else {
					continuation.resume(throwing: VNCError.connection(.closed))
					return
				}

				let bytes = [UInt8](data)
				var offset = 0
				while offset < bytes.count {
					let count = bytes.withUnsafeBufferPointer {
						CFWriteStreamWrite(writeStream, $0.baseAddress?.advanced(by: offset), bytes.count - offset)
					}
					guard count > 0 else {
						continuation.resume(throwing: VNCError.connection(.failed(nil)))
						return
					}
					offset += count
				}

				continuation.resume()
			}
		}
	}
}

/// Synchronizes state shared by the lifecycle, read and write queues. The
/// streams themselves are only read or written on their respective queues;
/// the lock is never held while performing stream I/O or invoking callbacks.
private final class CFStreamNetworkState: @unchecked Sendable {
	private let lock = NSLock()
	private var storedReadStream: CFReadStream?
	private var storedWriteStream: CFWriteStream?
	private var storedStatus: NetworkConnectionStatus = .setup
	private var storedStatusUpdateHandler: NetworkConnectionStatusUpdateHandler?
	private var storedLifecycleQueue = DispatchQueue(label: "com.royalapps.royalvnc.cfstream.lifecycle")
	private var didUpgradeToTLS = false
	private var wasCancelled = false

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

	var readStream: CFReadStream? {
		lock.lock()
		defer { lock.unlock() }
		return storedReadStream
	}

	var writeStream: CFWriteStream? {
		lock.lock()
		defer { lock.unlock() }
		return storedWriteStream
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

	func install(readStream: CFReadStream, writeStream: CFWriteStream) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		guard !wasCancelled else { return false }
		storedReadStream = readStream
		storedWriteStream = writeStream
		return true
	}

	func takeReadStream() -> CFReadStream? {
		lock.lock()
		defer { lock.unlock() }
		defer { storedReadStream = nil }
		return storedReadStream
	}

	func takeWriteStream() -> CFWriteStream? {
		lock.lock()
		defer { lock.unlock() }
		defer { storedWriteStream = nil }
		return storedWriteStream
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
