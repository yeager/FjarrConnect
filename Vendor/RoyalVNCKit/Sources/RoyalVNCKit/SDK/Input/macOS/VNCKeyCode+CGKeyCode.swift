#if os(macOS)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import CoreGraphics

public extension VNCKeyCode {
    static func keyCodesFrom(cgKeyCode: CGKeyCode,
                             characters: String?) -> [VNCKeyCode] {
		var keys: [VNCKeyCode]

        // Prefer a printable character resolved by macOS's active input
        // source. A physical-key mapping loses Option/Shift layout semantics
        // (for example Swedish Option+2 must arrive as @, not as Option+2).
        // Control keys such as Return, Tab, and Backspace have non-printable
        // characters, so they must fall back to their physical key mapping.
        if let chars = characters, !chars.isEmpty {
			let characterKeys = VNCKeyCode.keyCodesFrom(characters: chars)
			if !characterKeys.isEmpty {
				keys = characterKeys
			} else if let key = VNCKeyCode.from(cgKeyCode: cgKeyCode) {
				keys = [ key ]
			} else {
				keys = .init()
			}
		} else if let key = VNCKeyCode.from(cgKeyCode: cgKeyCode) {
			keys = [ key ]
		} else {
			keys = .init()
		}

        return keys
    }
}
#endif
