#if os(macOS)
import AppKit
import XCTest
@testable import RoyalVNCKit

final class VNCCursorMacOSTests: XCTestCase {
	func testEmptyRemoteCursorUsesCenteredDotFallback() {
		let cursor = VNCCursor.empty.nsCursor(scaleFactor: 1)

		XCTAssertEqual(cursor.image.size, NSSize(width: 9, height: 9))
		XCTAssertEqual(cursor.hotSpot, NSPoint(x: 4.5, y: 4.5))
		let image = cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
		let bitmap = image.map(NSBitmapImageRep.init(cgImage:))
		let center = bitmap?.colorAt(x: 4, y: 4)?.usingColorSpace(.deviceRGB)
		let outline = bitmap?.colorAt(x: 1, y: 4)?.usingColorSpace(.deviceRGB)

		XCTAssertNotNil(image)
		XCTAssertLessThan(center?.redComponent ?? 1, 0.05, "The fallback should have a dark center")
		XCTAssertGreaterThan(outline?.redComponent ?? 0, 0.95, "The fallback should have a light outline")
	}

	func testEmptyRemoteCursorFallbackScalesWithFramebuffer() {
		let cursor = VNCCursor.empty.nsCursor(scaleFactor: 0.5)

		XCTAssertEqual(cursor.image.size, NSSize(width: 4.5, height: 4.5))
		XCTAssertEqual(cursor.hotSpot, NSPoint(x: 2.25, y: 2.25))
	}
}
#endif
