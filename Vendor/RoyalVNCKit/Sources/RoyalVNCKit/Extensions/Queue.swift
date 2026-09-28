import Foundation

final class Queue<T>: @unchecked Sendable {
	private struct Entry {
		let value: T
		let autorepeatKey: UInt32?
	}

	private var list = [Entry]()
	private var pressedKeys = Set<UInt32>()
	private let lock = NSLock()

	func enqueue(_ element: T) {
		lock.lock(); defer { lock.unlock() }
		list.append(Entry(value: element, autorepeatKey: nil))
	}

	func enqueueKeyEvent(_ event: VNCProtocol.KeyEvent) {
		lock.lock(); defer { lock.unlock() }

		if event.isDown {
			pressedKeys.insert(event.key)
		} else {
			pressedKeys.remove(event.key)
			list.removeAll { $0.autorepeatKey == event.key }
		}

		if let typedEvent = event as? T {
			list.append(Entry(value: typedEvent, autorepeatKey: nil))
		}
	}

	func enqueueKeyRepeat(_ event: VNCProtocol.KeyEvent) {
		lock.lock(); defer { lock.unlock() }
		guard pressedKeys.contains(event.key) else { return }
		guard !list.contains(where: { entry in
			if entry.autorepeatKey == event.key { return true }
			guard let keyEvent = entry.value as? VNCProtocol.KeyEvent else { return false }
			return keyEvent.key == event.key
		}) else { return }

		if let typedEvent = event as? T {
			list.append(Entry(value: typedEvent, autorepeatKey: event.key))
		}
	}

	func dequeue() -> T? {
		lock.lock(); defer { lock.unlock() }
		guard !list.isEmpty else { return nil }

		return list.removeFirst().value
	}

	func clear() {
		lock.lock(); defer { lock.unlock() }
		list.removeAll()
		pressedKeys.removeAll()
	}

	func peek() -> T? {
		lock.lock(); defer { lock.unlock() }
		guard !list.isEmpty else { return nil }

		return list[0].value
	}

	var isEmpty: Bool {
		lock.lock(); defer { lock.unlock() }
		return list.isEmpty
	}
}
