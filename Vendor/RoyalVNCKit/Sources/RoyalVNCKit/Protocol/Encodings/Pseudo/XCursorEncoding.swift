#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCProtocol {
	struct XCursorEncoding: VNCReceivablePseudoEncoding {
		let encodingType = VNCPseudoEncodingType.xCursor.rawValue
	}
}

extension VNCProtocol.XCursorEncoding {
	func receive(_ rectangle: VNCProtocol.Rectangle,
				 framebuffer: VNCFramebuffer,
				 connection: NetworkConnectionReading,
				 logger: VNCLogger) async throws {
		let width = Int(rectangle.region.size.width)
		let height = Int(rectangle.region.size.height)
		guard width <= 4096, height <= 4096,
			  width * height <= 1_048_576 else {
			throw VNCError.protocol(.invalidData)
		}

		guard width > 0, height > 0 else {
			framebuffer.updateCursor(.empty)
			return
		}

		let bytesPerRow = (width + 7) / 8
		let bitmapLength = bytesPerRow * height
		let data = try await connection.readBuffered(length: 6 + bitmapLength * 2)
		let bytes = [UInt8](data)
		guard bytes.count == 6 + bitmapLength * 2 else {
			throw VNCError.protocol(.invalidData)
		}

		let foreground = (red: bytes[0], green: bytes[1], blue: bytes[2])
		let background = (red: bytes[3], green: bytes[4], blue: bytes[5])
		let bitmapStart = 6
		let maskStart = bitmapStart + bitmapLength
		var rgba = Data(repeating: 0, count: width * height * 4)

		rgba.withUnsafeMutableBytes { destination in
			guard let pixels = destination.bindMemory(to: UInt8.self).baseAddress else { return }
			for y in 0..<height {
				for x in 0..<width {
					let bit = UInt8(0x80 >> (x % 8))
					let rowOffset = y * bytesPerRow
					let isVisible = bytes[maskStart + rowOffset + x / 8] & bit != 0
					let isForeground = bytes[bitmapStart + rowOffset + x / 8] & bit != 0
					let color = isForeground ? foreground : background
					let offset = (y * width + x) * 4
					pixels[offset] = color.red
					pixels[offset + 1] = color.green
					pixels[offset + 2] = color.blue
					pixels[offset + 3] = isVisible ? 0xFF : 0
				}
			}
		}

		let size = rectangle.region.size
		let hotspot = rectangle.region.location
		framebuffer.updateCursor(VNCCursor(imageData: rgba,
										  size: size,
									  hotspot: hotspot,
									  bitsPerComponent: 8,
									  bitsPerPixel: 32,
									  bytesPerPixel: 4))
	}
}
