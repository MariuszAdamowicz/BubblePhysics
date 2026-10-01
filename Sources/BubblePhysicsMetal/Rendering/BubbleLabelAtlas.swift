import Metal
import CoreGraphics
import CoreText

public struct BubbleLabelAtlasEntry: Equatable, Sendable {
    public let label: String
    public let uvOrigin: SIMD2<Float>
    public let uvSize: SIMD2<Float>
}

public struct BubbleLabelAtlas: @unchecked Sendable {
    public let texture: MTLTexture
    public let entries: [String: BubbleLabelAtlasEntry]

    public static func build(labels: [String], device: MTLDevice) throws -> BubbleLabelAtlas {
        let unique = Array(Set(labels)).sorted()
        let columns = max(1, min(16, unique.count))
        let rows = max(1, (unique.count + columns - 1) / columns)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: columns * 64, height: rows * 64, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw MetalSolverError.bufferAllocationFailed }
        let entries = Dictionary(uniqueKeysWithValues: unique.enumerated().map { index, label in
            let column = index % columns, row = index / columns
            return (label, BubbleLabelAtlasEntry(label: label, uvOrigin: SIMD2(Float(column) / Float(columns), Float(row) / Float(rows)), uvSize: SIMD2(1 / Float(columns), 1 / Float(rows))))
        })
        let width = descriptor.width, height = descriptor.height
        var pixels = Array(repeating: UInt8.zero, count: width * height)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { throw MetalSolverError.bufferAllocationFailed }
        context.setFillColor(gray: 1, alpha: 1)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 30, nil)
        for (index, label) in unique.enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes))
            let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            let column = index % columns, row = index / columns
            context.textPosition = CGPoint(x: CGFloat(column * 64) + (64 - bounds.width) * 0.5, y: CGFloat((rows - row - 1) * 64) + (64 - bounds.height) * 0.5 - bounds.minY)
            CTLineDraw(line, context)
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: width)
        return BubbleLabelAtlas(texture: texture, entries: entries)
    }
}
