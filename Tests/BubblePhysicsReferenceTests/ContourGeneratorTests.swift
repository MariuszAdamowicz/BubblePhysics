import XCTest
@testable import BubblePhysicsReference

final class ContourGeneratorTests: XCTestCase {
    func testAdaptiveContourKeepsEverySegmentWithinConfiguredLength() throws {
        let bubble = try ReferenceBubble(
            id: .init(rawValue: 1),
            center: ReferenceVector2(x: 5, y: -3),
            mass: 1,
            targetRadius: 100
        )
        var configuration = ReferenceConfiguration.default
        configuration.maxContourSegmentLength = 1

        let points = ReferenceContourGenerator.points(for: bubble, configuration: configuration)

        XCTAssertGreaterThan(points.count, 64, "The contour must not use the old hard cap")
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            XCTAssertLessThanOrEqual((next - points[index]).length, 1.001)
        }
    }

    func testCompressedBubbleUsesFewerPointsThanUncompressedBubble() throws {
        let uncompressed = try makeBubble(radius: 40)
        var compressed = uncompressed
        compressed.directionalDeformations = (0..<8).map { index in
            let angle = Float(index) * .pi / 4
            return DirectionalDeformation(
                contactID: .init(rawValue: UInt64(index)),
                direction: .init(x: cosf(angle), y: sinf(angle)),
                depth: 18,
                angularWidth: .pi / 2,
                pressure: 1
            )
        }
        var configuration = ReferenceConfiguration.default
        configuration.maxContourSegmentLength = 4

        let fullPoints = ReferenceContourGenerator.points(for: uncompressed, configuration: configuration)
        let compressedPoints = ReferenceContourGenerator.points(for: compressed, configuration: configuration)

        XCTAssertLessThan(compressedPoints.count, fullPoints.count)
    }

    func testContourSamplesCurrentSupportRadius() throws {
        var bubble = try makeBubble(radius: 20)
        bubble.center = ReferenceVector2(x: 3, y: 7)
        bubble.directionalDeformations = [
            .init(contactID: .init(rawValue: 1), direction: .init(x: 1, y: 0), depth: 8, angularWidth: .pi / 2, pressure: 2)
        ]

        let points = ReferenceContourGenerator.points(for: bubble, configuration: .default)

        for point in points {
            let offset = point - bubble.center
            XCTAssertEqual(offset.length, bubble.supportRadius(along: offset), accuracy: 0.001)
        }
    }

    private func makeBubble(radius: Float) throws -> ReferenceBubble {
        try ReferenceBubble(id: .init(rawValue: 1), center: .zero, mass: 1, targetRadius: radius)
    }
}
