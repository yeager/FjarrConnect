#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Queue Management
extension VNCConnection {
	func enqueueKeyEvent(key: VNCKeyCode,
						 isDown: Bool) {
		guard settings.inputMode != .none else { return }

		let isARD = state.isAppleRemoteDesktop
		let keyCode = key.rawValue(forAppleRemoteDesktop: isARD)

		let keyEvent = VNCProtocol.KeyEvent(isDown: isDown,
											key: keyCode)

		logger.logDebug("Enqueuing Key \(keyEvent.description)")

		clientToServerMessageQueue.enqueueKeyEvent(keyEvent)
	}

	/// Keeps at most one unsent autorepeat per key. If the network send loop
	/// stalls, queued repeats must not grow without bound ahead of the key-up.
	func enqueueKeyRepeat(_ key: VNCKeyCode) {
		guard settings.inputMode != .none else { return }

		let keyCode = key.rawValue(forAppleRemoteDesktop: state.isAppleRemoteDesktop)
		let keyEvent = VNCProtocol.KeyEvent(isDown: true, key: keyCode)
		clientToServerMessageQueue.enqueueKeyRepeat(keyEvent)
	}

	/// Sends the initial key-up while preserving the physical key state so
	/// autorepeat events may still be forwarded until AppKit reports key-up.
	func enqueueKeyTapRelease(_ key: VNCKeyCode) {
		// Modifiers must remain down across the following key event for shortcuts
		// such as Control+C and Shift+Arrow to keep their intended meaning.
		guard settings.inputMode != .none, !key.isModifier else { return }

		let keyCode = key.rawValue(forAppleRemoteDesktop: state.isAppleRemoteDesktop)
		clientToServerMessageQueue.enqueueKeyTapRelease(
			VNCProtocol.KeyEvent(isDown: false, key: keyCode)
		)
	}

    func enqueueMouseEvent(nonNormalizedX: UInt16,
                           nonNormalizedY: UInt16) {
        guard settings.inputMode != .none else { return }

        let normalizedPosition = normalizedMousePosition(x: nonNormalizedX,
                                                         y: nonNormalizedY)

        enqueueMouseEvent(buttons: mouseButtonState,
                          position: normalizedPosition)
    }

    func enqueueMouseEvent(buttons: VNCProtocol.MousePointerButton,
                           nonNormalizedX: UInt16,
                           nonNormalizedY: UInt16) {
        guard settings.inputMode != .none else { return }

        let normalizedPosition = normalizedMousePosition(x: nonNormalizedX,
                                                         y: nonNormalizedY)

        enqueueMouseEvent(buttons: buttons,
                          position: normalizedPosition)
    }

	func enqueueMouseEvent(buttons: VNCProtocol.MousePointerButton,
						   position: VNCProtocol.MousePosition) {
		guard settings.inputMode != .none else { return }

		let pointerEvent = VNCProtocol.PointerEvent(buttons: buttons,
													position: position)

		enqueueClientToServerMessage(pointerEvent)
	}

	func enqueueClientCutTextMessage(_ text: String) {
		let clientCutTextMessage = VNCProtocol.ClientCutText(text: text)

		enqueueClientToServerMessage(clientCutTextMessage)
	}

	func enqueueExtendedClipboardCapabilities() {
		enqueueClientToServerMessage(VNCProtocol.ClientCutText.Extended.capabilities)
	}

	func enqueueClientToServerMessage(_ message: VNCSendableMessage) {
		clientToServerMessageQueue.enqueue(message)
	}

    func normalizedMousePosition(x: UInt16,
                                 y: UInt16) -> VNCProtocol.MousePosition {
        var normalizedX = x
        var normalizedY = y

        let framebufferWidth = framebuffer?.size.width ?? 0
        let framebufferHeight = framebuffer?.size.height ?? 0

        if normalizedY > framebufferHeight {
            normalizedY = framebufferHeight
        }

        if normalizedX > framebufferWidth {
            normalizedX = framebufferWidth
        }

        let normalizedPosition = VNCProtocol.MousePosition(x: normalizedX,
                                                           y: normalizedY)

        return normalizedPosition
    }
}
