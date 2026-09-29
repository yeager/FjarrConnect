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
		let factor = scaleFactor.isFinite && scaleFactor > 0 ? scaleFactor : 1
		guard !isEmpty else {
			return Self.emptyNSCursor(scaleFactor: factor)
		}

		guard let nsImage else {
			return Self.emptyNSCursor(scaleFactor: factor)
		}

		nsImage.size = NSSize(width: nsImage.size.width * factor,
						  height: nsImage.size.height * factor)

		let cursor = NSCursor(image: nsImage,
							  hotSpot: CGPoint(x: CGFloat(hotspot.x) * factor,
										   y: CGFloat(hotspot.y) * factor))

		return cursor
	}
}

private extension VNCCursor {
	static func emptyNSCursor(scaleFactor: CGFloat) -> NSCursor {
		let pixelSize = 9
		let size = NSSize(width: pixelSize, height: pixelSize)
		let bytesPerPixel = 4
		let bytesPerRow = pixelSize * bytesPerPixel
		var pixels = [UInt8](repeating: 0, count: pixelSize * bytesPerRow)
		for y in 0..<pixelSize {
			for x in 0..<pixelSize {
				let dx = x - pixelSize / 2
				let dy = y - pixelSize / 2
				let distanceSquared = dx * dx + dy * dy
				guard distanceSquared <= 16 else { continue }
				let offset = y * bytesPerRow + x * bytesPerPixel
				let color: UInt8 = distanceSquared <= 4 ? 0 : 255
				pixels[offset] = color
				pixels[offset + 1] = color
				pixels[offset + 2] = color
				pixels[offset + 3] = 255
			}
		}
		let data = Data(pixels) as CFData
		guard let provider = CGDataProvider(data: data),
			  let cgImage = CGImage(width: pixelSize,
								 height: pixelSize,
								 bitsPerComponent: 8,
								 bitsPerPixel: 32,
								 bytesPerRow: bytesPerRow,
								 space: CGColorSpaceCreateDeviceRGB(),
								 bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.last.rawValue),
								 provider: provider,
								 decode: nil,
								 shouldInterpolate: false,
								 intent: .defaultIntent) else {
			return .arrow
		}
		let image = NSImage(cgImage: cgImage, size: size)
		image.size = NSSize(width: size.width * scaleFactor, height: size.height * scaleFactor)
		return NSCursor(image: image,
						hotSpot: NSPoint(x: size.width / 2 * scaleFactor,
										 y: size.height / 2 * scaleFactor))
	}

	var nsImage: NSImage? {
		guard let cgImage else { return nil }

		let nsImage = NSImage(cgImage: cgImage, size: size.cgSize)

		return nsImage
	}
}
#endif
