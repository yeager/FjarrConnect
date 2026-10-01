import Foundation

final class Queue<T>: @unchecked Sendable {
	private struct Entry {
		let value: T
		let autorepeatKey: UInt32?
	}

	private var list = [Entry]()
	private var pressedKeys = Set<UInt32>()
	private var remotePressedKeys = Set<UInt32>()
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
			let hasQueuedPress = list.contains { entry in
				guard let keyEvent = entry.value as? VNCProtocol.KeyEvent else { return false }
				return keyEvent.key == event.key && keyEvent.isDown
			}
			list.removeAll { $0.autorepeatKey == event.key }
			guard remotePressedKeys.contains(event.key) || hasQueuedPress else { return }
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

		// Send each autorepeat as a complete tap. If AppKit loses the physical
		// key-up during a focus transition, the remote key is still released at
		// the end of the last repeat instead of continuing to type indefinitely.
		let repeatEvents = [event, VNCProtocol.KeyEvent(isDown: false, key: event.key)]
		for repeatEvent in repeatEvents {
			if let typedEvent = repeatEvent as? T {
				list.append(Entry(value: typedEvent, autorepeatKey: event.key))
			}
		}
	}

	/// Releases the remote key after its initial press without clearing the
	/// physical-key state. AppKit's later key-up can be lost during tab/focus
	/// changes, so ordinary presses must not depend on it to stop remote repeat.
	func enqueueKeyTapRelease(_ event: VNCProtocol.KeyEvent) {
		lock.lock(); defer { lock.unlock() }
		guard !event.isDown, pressedKeys.contains(event.key) else { return }
		guard !list.contains(where: { entry in
			guard entry.autorepeatKey == event.key,
			      let keyEvent = entry.value as? VNCProtocol.KeyEvent else { return false }
			return !keyEvent.isDown
		}) else { return }

		if let typedEvent = event as? T {
			list.append(Entry(value: typedEvent, autorepeatKey: event.key))
		}
	}

	func dequeue() -> T? {
		lock.lock(); defer { lock.unlock() }
		guard !list.isEmpty else { return nil }

		let entry = list.removeFirst()
		if let keyEvent = entry.value as? VNCProtocol.KeyEvent {
			if keyEvent.isDown {
				remotePressedKeys.insert(keyEvent.key)
			} else {
				remotePressedKeys.remove(keyEvent.key)
			}
		}
		return entry.value
	}

	func clear() {
		lock.lock(); defer { lock.unlock() }
		list.removeAll()
		pressedKeys.removeAll()
		remotePressedKeys.removeAll()
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
