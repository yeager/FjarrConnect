import Foundation

final class Queue<T>: @unchecked Sendable {
	private var list = [T]()
	private let lock = NSLock()

	func enqueue(_ element: T) {
		lock.lock(); defer { lock.unlock() }
		list.append(element)
	}

	func enqueueKeyRepeat(_ event: VNCProtocol.KeyEvent) {
		lock.lock(); defer { lock.unlock() }
		for queued in list.reversed() {
			guard let keyEvent = queued as? VNCProtocol.KeyEvent,
				  keyEvent.key == event.key else {
				continue
			}
			if keyEvent.isDown { return }
			break
		}
		if let typedEvent = event as? T {
			list.append(typedEvent)
		}
	}

	func dequeue() -> T? {
		lock.lock(); defer { lock.unlock() }
		guard !list.isEmpty else { return nil }

		return list.removeFirst()
	}

	func clear() {
		lock.lock(); defer { lock.unlock() }
		list.removeAll()
	}

	func peek() -> T? {
		lock.lock(); defer { lock.unlock() }
		guard !list.isEmpty else { return nil }

		return list[0]
	}

	var isEmpty: Bool {
		lock.lock(); defer { lock.unlock() }
		return list.isEmpty
	}
}
