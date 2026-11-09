import BubblePhysics
import Metal
import XCTest

/// Pomocnicy testów interpolacji: `advance` z buforem poleceń i renderem do celu harnessu oraz pomiar położenia obiektu
/// z pikseli (kamera 40×40 jednostek na 256 px, czyli 6,4 px na jednostkę).
extension RenderTestScene {
    /// Wywołuje `advance(by:commandBuffer:encodeRender:)` z renderem do celu harnessu; `fail` rzuca z domknięcia.
    @discardableResult
    func advanceRendering(by seconds: TimeInterval, fail: Error? = nil) async throws -> (frame: WorldFrame, command: MTLCommandBuffer) {
        let command = try harness.makeCommandBuffer()
        let frame = await world.advance(by: seconds, commandBuffer: command) { [self] in
            if let fail { throw fail }
            try renderer.encode(world: world, viewport: Self.viewport, commandBuffer: command,
                                renderPassDescriptor: harness.makePass())
        }
        return (frame, command)
    }

    /// Środek (po x, w jednostkach świata) pikseli z `match` w wierszu y = 0; `nil`, gdy żaden piksel nie pasuje.
    func renderedCenterX(row: Int = 128, where match: ([UInt8]) -> Bool = { $0[0] > 128 && $0[1] < 100 && $0[2] < 100 }) -> Float? {
        let columns = (0..<harness.size).filter { match(harness.pixel(x: $0, y: row)) }
        guard let first = columns.first, let last = columns.last else { return nil }
        return -20 + (Float(first) + Float(last) + 1) / 2 / 6.4
    }
}
