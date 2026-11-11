import Foundation
import XCTest

/// P-B-86 (zadanie 99): materiał trafia do fragmentu z wierzchołka (`[[flat]]`), a fragment nie czyta bufora materiałów po
/// indeksie z wyjścia wierzchołka. Zmiana nie może ruszyć pikseli: pilnują tego testy obrazu materiałów i
/// `AcceptanceRenderEquivalenceTests`; ten test pilnuje samej struktury shaderów.
final class RenderMaterialFromVertexTests: XCTestCase {
    private func shaderSource(file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/BubblePhysicsNativeMetal/Shaders/NativeRenderKernels.metal-source")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testFragmentsDoNotIndexTheMaterialBufferPerFragment() throws {
        let source = try shaderSource()
        XCTAssertFalse(source.contains("materials[in.material]"), "fragment czyta materiał z bufora na każdy fragment")
    }

    func testVerticesReadTheMaterialOnce() throws {
        let source = try shaderSource()
        // Wierzchołek bańki i bryły dostaje bufor materiałów i zapisuje materiał w wyjściu płaskim.
        XCTAssertTrue(source.contains("device const NativeRenderMaterial *materials [[buffer(9)]]"))
        XCTAssertGreaterThanOrEqual(source.components(separatedBy: "materials[").count - 1, 2)
        XCTAssertTrue(source.contains("float4 materialColor [[flat]]"))
    }
}
