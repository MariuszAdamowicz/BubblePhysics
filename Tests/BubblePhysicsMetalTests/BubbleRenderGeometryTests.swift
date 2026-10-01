import XCTest
@testable import BubblePhysicsMetal

final class BubbleRenderGeometryTests: XCTestCase {
    func testTriangleBubbleBuildsCompleteFanOutlineAndDiagnosticPoints() {
        let range = makeRange(id: 7, center: 4, boundaryStart: 10, boundaryCount: 3)

        let geometry = BubbleRenderGeometry.build(ranges: [range])

        XCTAssertEqual(geometry.fillIndices, [4, 10, 11, 4, 11, 12, 4, 12, 10])
        XCTAssertEqual(geometry.outlineIndices, [10, 11, 11, 12, 12, 10])
        XCTAssertEqual(geometry.diagnosticPointIndices, [4, 10, 11, 12])
        XCTAssertEqual(geometry.bubbles[0].fillIndexRange, 0..<9)
        XCTAssertEqual(geometry.bubbles[0].outlineIndexRange, 0..<6)
    }

    func testAdaptiveGeometryKeepsEveryIndexInsideItsBubbleParticleRange() {
        for boundaryCount in [12, 257] {
            let range = makeRange(id: UInt32(boundaryCount), center: 2, boundaryStart: 20, boundaryCount: boundaryCount)

            let geometry = BubbleRenderGeometry.build(ranges: [range])

            XCTAssertEqual(geometry.fillIndices.count, boundaryCount * 3)
            XCTAssertEqual(geometry.outlineIndices.count, boundaryCount * 2)
            XCTAssertTrue(geometry.fillIndices.allSatisfy { index in
                index == 2 || (20..<(20 + UInt32(boundaryCount))).contains(index)
            })
            XCTAssertTrue(geometry.outlineIndices.allSatisfy { (20..<(20 + UInt32(boundaryCount))).contains($0) })
        }
    }

    func testMaterialAxisUnwrapsAcrossMinusPiBoundary() {
        let range = makeRange(id: 1, center: 0, boundaryStart: 1, boundaryCount: 3)
        var axis = BubbleMaterialAxis()
        let before = axis.pose(range: range, particles: particles(firstBoundaryAngle: .pi - 0.05, radius: 10))
        let after = axis.pose(range: range, particles: particles(firstBoundaryAngle: -.pi + 0.05, radius: 10))

        XCTAssertGreaterThan(after.angleRadians - before.angleRadians, 0)
        XCTAssertLessThan(after.angleRadians - before.angleRadians, 0.2)
    }

    func testRadialDeformationDoesNotScaleLabel() {
        let range = makeRange(id: 1, center: 0, boundaryStart: 1, boundaryCount: 3)
        var axis = BubbleMaterialAxis()

        let compact = axis.pose(range: range, particles: particles(firstBoundaryAngle: 0.5, radius: 5))
        let stretched = axis.pose(range: range, particles: particles(firstBoundaryAngle: 0.5, radius: 50))

        XCTAssertEqual(compact.scale, stretched.scale)
        XCTAssertEqual(compact.angleRadians, stretched.angleRadians, accuracy: 0.0001)
    }

    private func makeRange(id: UInt32, center: UInt32, boundaryStart: UInt32, boundaryCount: Int) -> MetalBubbleRange {
        MetalBubbleRange(
            id: id,
            centerIndex: center,
            boundaryStart: boundaryStart,
            boundaryCount: UInt32(boundaryCount),
            restArea: 100
        )
    }

    private func particles(firstBoundaryAngle: Float, radius: Float) -> [MetalParticle] {
        let center = SIMD2<Float>(20, 30)
        return [
            MetalParticle(position: center, previousPosition: center, inverseMass: 1, bubbleIndex: 0),
            particle(center + SIMD2(cos(firstBoundaryAngle), sin(firstBoundaryAngle)) * radius),
            particle(center + SIMD2<Float>(-4, 4)),
            particle(center + SIMD2<Float>(-4, -4))
        ]
    }

    private func particle(_ position: SIMD2<Float>) -> MetalParticle {
        MetalParticle(position: position, previousPosition: position, inverseMass: 1, bubbleIndex: 0)
    }
}
