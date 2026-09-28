#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCProtocol {
	/// Handles Apple's cached cursor rectangles (encoding 0x450): cache ID,
	/// compressed length, then a Z_SYNC_FLUSH BGRA plane and a separate alpha plane.
	final class AppleCursorImageEncoding: VNCFrameEncoding {
		let encodingType = VNCPseudoEncodingType.appleCursorImage.rawValue

		private struct CachedCursor {
			let cursor: VNCCursor
			let byteCount: Int
		}

		private var cursorCache: [UInt32: CachedCursor] = [:]
		private var cacheOrder: [UInt32] = []
		private var cachedByteCount = 0
		private let maximumCacheBytes = 16 * 1024 * 1024
		private let maximumCompressedBytes = 8 * 1024 * 1024
		private let maximumCursorPixels = 1_048_576

		func decodeRectangle(_ rectangle: Rectangle,
							 framebuffer: VNCFramebuffer,
							 connection: NetworkConnectionReading,
							 logger: VNCLogger) async throws {
			let cacheID = try await connection.readUInt32()
			let compressedLength = Int(try await connection.readUInt32())

			if compressedLength == 0 {
				if let cachedCursor = cursorCache[cacheID] {
					framebuffer.updateCursor(cachedCursor.cursor)
				} else {
					logger.logDebug("Ignoring Apple cursor selection for an uncached shape")
				}
				return
			}

			let width = Int(rectangle.width)
			let height = Int(rectangle.height)
			guard width > 0, height > 0,
				  width <= 4096, height <= 4096,
				  width <= maximumCursorPixels / height else {
				throw VNCError.protocol(.invalidData)
			}

			let pixelCount = width * height
			let (uncompressedByteCount, overflow) = pixelCount.multipliedReportingOverflow(by: 5)
			guard !overflow,
				  uncompressedByteCount <= maximumCacheBytes,
				  compressedLength > 0,
				  compressedLength <= maximumCompressedBytes else {
				throw VNCError.protocol(.invalidData)
			}

			let compressedData = try await connection.readBuffered(
				length: compressedLength,
				minimumChunkSize: 1,
				maximumChunkSize: 16 * 1024
			)
			guard compressedData.count == compressedLength else {
				throw VNCError.protocol(.invalidData)
			}

			let decompressedData = try ZlibStream().decompressedData(
				compressedData: compressedData,
				uncompressedSize: UInt(uncompressedByteCount)
			)
			let bytes = [UInt8](decompressedData)
			guard bytes.count == uncompressedByteCount else {
				throw VNCError.protocol(.invalidData)
			}

			let alphaOffset = pixelCount * 4
			var rgba = Data(repeating: 0, count: pixelCount * 4)
			rgba.withUnsafeMutableBytes { destination in
				guard let pixels = destination.bindMemory(to: UInt8.self).baseAddress else { return }
				for pixelIndex in 0..<pixelCount {
					let sourceOffset = pixelIndex * 4
					let destinationOffset = sourceOffset
					pixels[destinationOffset] = bytes[sourceOffset + 2]
					pixels[destinationOffset + 1] = bytes[sourceOffset + 1]
					pixels[destinationOffset + 2] = bytes[sourceOffset]
					pixels[destinationOffset + 3] = bytes[alphaOffset + pixelIndex]
				}
			}

			let cursor = VNCCursor(
				imageData: rgba,
				size: VNCSize(width: UInt16(width), height: UInt16(height)),
				hotspot: VNCPoint(x: rectangle.xPosition, y: rectangle.yPosition),
				bitsPerComponent: 8,
				bitsPerPixel: 32,
				bytesPerPixel: 4
			)
			cache(cursor, id: cacheID, byteCount: uncompressedByteCount)
			framebuffer.updateCursor(cursor)
		}

		private func cache(_ cursor: VNCCursor, id: UInt32, byteCount: Int) {
			if let previous = cursorCache.removeValue(forKey: id) {
				cachedByteCount -= previous.byteCount
				cacheOrder.removeAll { $0 == id }
			}

			while cachedByteCount + byteCount > maximumCacheBytes,
				  let oldestID = cacheOrder.first,
				  let oldest = cursorCache.removeValue(forKey: oldestID) {
				cachedByteCount -= oldest.byteCount
				cacheOrder.removeFirst()
			}

			cursorCache[id] = CachedCursor(cursor: cursor, byteCount: byteCount)
			cacheOrder.append(id)
			cachedByteCount += byteCount
		}
	}
}
