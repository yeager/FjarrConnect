import CoreGraphics

enum VNCFrameDiagnostics {
    /// A small preview is sufficient to identify a persistently black desktop.
    static func isBlack(_ image: CGImage) -> Bool {
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 32,
                                          bitsPerComponent: 8, bytesPerRow: 32 * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            let data = bytes.bindMemory(to: UInt8.self)
            return stride(from: 0, to: data.count, by: 4).allSatisfy {
                data[$0] <= 2 && data[$0 + 1] <= 2 && data[$0 + 2] <= 2
            }
        }
    }
}
