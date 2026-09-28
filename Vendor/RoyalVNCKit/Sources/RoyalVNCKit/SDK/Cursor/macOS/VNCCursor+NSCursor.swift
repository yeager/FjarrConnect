#if os(macOS)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import AppKit

public extension VNCCursor {
	var nsCursor: NSCursor {
		nsCursor(scaleFactor: 1)
	}

	/// Converts framebuffer-pixel dimensions into the points used by AppKit.
	/// Use the same factor for the hotspot so the click location stays aligned.
	func nsCursor(scaleFactor: CGFloat) -> NSCursor {
		guard !isEmpty else {
			return Self.emptyNSCursor
		}

		guard let nsImage else {
			return Self.emptyNSCursor
		}

		let factor = scaleFactor.isFinite && scaleFactor > 0 ? scaleFactor : 1
		nsImage.size = NSSize(width: nsImage.size.width * factor,
						  height: nsImage.size.height * factor)

		let cursor = NSCursor(image: nsImage,
							  hotSpot: CGPoint(x: CGFloat(hotspot.x) * factor,
										   y: CGFloat(hotspot.y) * factor))

		return cursor
	}
}

private extension VNCCursor {
	static var emptyNSCursor: NSCursor {
		// TODO: Should use a "dot" cursor like in other VNC clients

		.arrow
	}

	var nsImage: NSImage? {
		guard let cgImage else { return nil }

		let nsImage = NSImage(cgImage: cgImage, size: size.cgSize)

		return nsImage
	}
}
#endif
