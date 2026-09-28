#if os(macOS)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import CoreGraphics

/// Keeps each VNC key-up paired with the key symbol emitted for its key-down.
struct VNCKeyEventTracker {
    private var pressedKeys: [CGKeyCode: [VNCKeyCode]] = [:]

    mutating func keyDown(for keyCode: CGKeyCode, characters: String?, isRepeat: Bool = false) -> [VNCKeyCode] {
        if let pressed = pressedKeys[keyCode] {
            return pressed
        }

        // AppKit can deliver a repeat after the physical key-up, especially
        // while events are delayed by a busy remote session. It is not a new
        // press and must not leave a remote key held without a matching key-up.
        guard !isRepeat else { return [] }

        let keys = VNCKeyCode.keyCodesFrom(cgKeyCode: keyCode, characters: characters)
        if !keys.isEmpty {
            pressedKeys[keyCode] = keys
        }
        return keys
    }

    mutating func keyUp(for keyCode: CGKeyCode) -> [VNCKeyCode] {
        pressedKeys.removeValue(forKey: keyCode) ?? []
    }

    mutating func releaseAll() -> [VNCKeyCode] {
        let keys = pressedKeys.keys.sorted().flatMap { pressedKeys[$0] ?? [] }
        pressedKeys.removeAll()
        return keys
    }
}
#endif
