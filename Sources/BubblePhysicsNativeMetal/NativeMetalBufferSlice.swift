import Metal

/// Wycinek wspólnego bufora. Małe bufory jednej grupy (sterowanie kroku, rekordy sił) leżą w jednym `MTLBuffer`, żeby jądro jednej
/// grupy mieściło się w 31 wiązaniach buforów argument buffers tier 1 (A11, bugfix iPhone X, BF-D-2); jądra wiążą wycinek z przesunięciem.
struct NativeMetalBufferSlice {
    /// Wyrównanie przesunięcia wycinka: wystarcza dla `setBuffer` w każdej przestrzeni adresowej i dla `indirectBufferOffset`.
    static let alignment = 256
    let buffer: MTLBuffer
    let offset: Int
    let length: Int

    /// Cały bufor jako wycinek (bufory testowe jąder, które w produkcji dostają wycinek wspólnego bufora).
    init(_ buffer: MTLBuffer) { self.init(buffer, offset: 0, length: buffer.length) }

    init(_ buffer: MTLBuffer, offset: Int, length: Int) {
        self.buffer = buffer
        self.offset = offset
        self.length = length
    }

    /// Wycinek z wiązania jądra: `NativeMetalBufferSlice` bez zmian, `MTLBuffer` jako cały bufor.
    init(binding: Any) {
        switch binding {
        case let slice as NativeMetalBufferSlice: self = slice
        case let buffer as MTLBuffer: self.init(buffer)
        default: preconditionFailure("wiązanie nie jest ani MTLBuffer, ani NativeMetalBufferSlice")
        }
    }

    func contents() -> UnsafeMutableRawPointer { buffer.contents().advanced(by: offset) }

    /// Przesunięcia kolejnych wycinków o długościach `lengths`, każde wyrównane do `alignment`, i długość wspólnego bufora.
    static func layout(_ lengths: [Int]) -> (offsets: [Int], length: Int) {
        var offsets: [Int] = []
        var end = 0
        for length in lengths {
            let offset = (end + alignment - 1) / alignment * alignment
            offsets.append(offset)
            end = offset + length
        }
        return (offsets, end)
    }

    /// Wycinki bufora `buffer` w układzie `layout(lengths)`, w kolejności `lengths`.
    static func slices(of buffer: MTLBuffer, lengths: [Int]) -> [NativeMetalBufferSlice] {
        zip(layout(lengths).offsets, lengths).map { NativeMetalBufferSlice(buffer, offset: $0, length: $1) }
    }
}

extension MTLComputeCommandEncoder {
    /// Wiąże `MTLBuffer` (od początku) albo `NativeMetalBufferSlice` (jego bufor z przesunięciem) pod `index`.
    func setBinding(_ binding: Any, index: Int) {
        let slice = NativeMetalBufferSlice(binding: binding)
        setBuffer(slice.buffer, offset: slice.offset, index: index)
    }

    /// Wiąże kolejne bufory i wycinki pod indeksami od zera.
    func setBindings(_ bindings: [Any]) {
        for (index, binding) in bindings.enumerated() { setBinding(binding, index: index) }
    }

    func dispatchThreadgroups(indirectSlice slice: NativeMetalBufferSlice, threadsPerThreadgroup: MTLSize) {
        dispatchThreadgroups(indirectBuffer: slice.buffer, indirectBufferOffset: slice.offset, threadsPerThreadgroup: threadsPerThreadgroup)
    }
}
