import Metal

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
        return BubbleLabelAtlas(texture: texture, entries: entries)
    }
}
