import BubblePhysics
import XCTest

final class RigidShapeTests: XCTestCase {
    private let material = PhysicsMaterialID(rawValue: 1)
    private let style = RenderMaterialID(rawValue: 1)

    private func assertRelativelyEqual(_ actual: Float, _ expected: Float, tolerance: Float,
                                       _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(actual - expected), abs(expected) * tolerance,
                                 "\(message) \(actual) vs \(expected)", file: file, line: line)
    }

    private func body(_ shape: RigidShape, mass: Float = 1, inertia: Float? = nil) throws -> RigidBodyDescriptor {
        try RigidBodyDescriptor(id: ObjectID(rawValue: 1), shape: shape, mass: mass, momentOfInertia: inertia,
                                physicsMaterialID: material, renderMaterialID: style)
    }

    func testCircleInertiaIsHalfMassTimesRadiusSquaredWithinTenthOfPercent() throws {
        for (mass, radius) in [(Float(3), Float(2.5)), (1, 1), (0.2, 40), (500, 0.05)] {
            let expected = mass * radius * radius / 2
            assertRelativelyEqual(RigidShape.circle(radius: radius).momentOfInertia(mass: mass), expected,
                                  tolerance: 0.001, "r=\(radius) m=\(mass)")
            assertRelativelyEqual(try body(.circle(radius: radius), mass: mass).resolvedMomentOfInertia, expected,
                                  tolerance: 0.001)
        }
    }

    func testRectangleInertiaFollowsFormulaAroundCentroidRegardlessOfOriginAndWinding() throws {
        // m·(w² + h²) / 12, także gdy początek układu leży poza prostokątem i przy odwróconym obiegu.
        let centred: [WorldPoint] = [[-2, -1], [2, -1], [2, 1], [-2, 1]]
        let shifted: [WorldPoint] = [[10, 20], [14, 20], [14, 22], [10, 22]]
        let expected: Float = 6 * (16 + 4) / 12
        for vertices in [centred, shifted, centred.reversed(), shifted.reversed()] {
            let shape = RigidShape.polygon(try PolygonGeometry(vertices: vertices))
            assertRelativelyEqual(shape.momentOfInertia(mass: 6), expected, tolerance: 0.001)
        }
    }

    func testTriangleAndConcavePolygonInertiaMatchNumericalIntegration() throws {
        let shapes: [[WorldPoint]] = [
            [[0, 0], [4, 0], [0, 3]],
            [[0, 0], [4, 0], [4, 4], [2, 1], [0, 4]]
        ]
        for vertices in shapes {
            let geometry = try PolygonGeometry(vertices: vertices)
            let expected = numericalInertia(mass: 2, samples: 700,
                inside: { x, y in self.contains(vertices, x, y) },
                bounds: (min: SIMD2<Float>(-1, -1), max: SIMD2<Float>(5, 5)))
            assertRelativelyEqual(RigidShape.polygon(geometry).momentOfInertia(mass: 2), expected, tolerance: 0.01,
                                  "\(vertices)")
        }
    }

    func testCapsuleInertiaMatchesNumericalIntegrationAndLimitCases() throws {
        let h: Float = 2, r: Float = 1, mass: Float = 5
        let numeric = numericalInertia(mass: mass, samples: 1200,
            inside: { x, y in
                let cx = min(max(x, -h), h)
                return (x - cx) * (x - cx) + y * y <= r * r
            }, bounds: (min: SIMD2<Float>(-h - r, -r), max: SIMD2<Float>(h + r, r)))
        assertRelativelyEqual(RigidShape.capsule(halfLength: h, radius: r).momentOfInertia(mass: mass), numeric,
                              tolerance: 0.005)
        // Bardzo krótka kapsuła to koło, bardzo cienka to pręt o długości 2h.
        assertRelativelyEqual(RigidShape.capsule(halfLength: 1e-4, radius: 2).momentOfInertia(mass: 3),
                              3 * 4 / 2, tolerance: 0.001)
        assertRelativelyEqual(RigidShape.capsule(halfLength: 3, radius: 1e-5).momentOfInertia(mass: 3),
                              3 * 36 / 12, tolerance: 0.001)
    }

    func testSuppliedInertiaWinsAndMissingInertiaIsComputed() throws {
        let circle = RigidShape.circle(radius: 2)
        XCTAssertEqual(try body(circle, mass: 2, inertia: 77).resolvedMomentOfInertia, 77)
        XCTAssertEqual(try body(circle, mass: 2, inertia: 77).momentOfInertia, 77)
        XCTAssertNil(try body(circle, mass: 2).momentOfInertia)
        assertRelativelyEqual(try body(circle, mass: 2).resolvedMomentOfInertia, 4, tolerance: 0.001)
    }

    func testInvalidShapesAndInertiaAreRejected() throws {
        let invalid: [RigidShape] = [
            .circle(radius: 0), .circle(radius: -1), .circle(radius: .nan), .circle(radius: .infinity),
            .capsule(halfLength: 0, radius: 1), .capsule(halfLength: 1, radius: 0),
            .capsule(halfLength: -1, radius: 1), .capsule(halfLength: .nan, radius: 1),
            .capsule(halfLength: 1, radius: .infinity)
        ]
        for shape in invalid {
            XCTAssertThrowsError(try body(shape), "\(shape)")
        }
        for inertia: Float in [0, -2, .nan, .infinity] {
            XCTAssertThrowsError(try body(.circle(radius: 1), inertia: inertia), "inertia \(inertia)")
        }
        // Moment liczony, który w Float znika, nie może trafić do solvera jako odwrotność nieskończona.
        XCTAssertThrowsError(try body(.circle(radius: 1e-30), mass: 1e-10))
    }

    func testRigidBodyDescriptorKeepsShapeAndPolygonShortcutBuildsPolygon() throws {
        let capsule = try body(.capsule(halfLength: 2, radius: 0.5))
        XCTAssertEqual(capsule.shape, .capsule(halfLength: 2, radius: 0.5))
        let vertices: [WorldPoint] = [[0, 0], [1, 0], [0, 1]]
        let shortcut = try RigidBodyDescriptor(id: ObjectID(rawValue: 2), vertices: vertices,
                                               physicsMaterialID: material, renderMaterialID: style)
        XCTAssertEqual(shortcut.shape, .polygon(try PolygonGeometry(vertices: vertices)))
    }

    // MARK: Całkowanie numeryczne (środki komórek, jednostajna gęstość) jako niezależny wzorzec.

    private func numericalInertia(mass: Float, samples: Int, inside: (Float, Float) -> Bool,
                                  bounds: (min: SIMD2<Float>, max: SIMD2<Float>)) -> Float {
        let nx = samples, ny = samples
        let dx = (bounds.max.x - bounds.min.x) / Float(nx), dy = (bounds.max.y - bounds.min.y) / Float(ny)
        var count: Double = 0, sx: Double = 0, sy: Double = 0
        var points: [(Double, Double)] = []
        for i in 0..<nx {
            for j in 0..<ny {
                let x = bounds.min.x + (Float(i) + 0.5) * dx, y = bounds.min.y + (Float(j) + 0.5) * dy
                if inside(x, y) { count += 1; sx += Double(x); sy += Double(y); points.append((Double(x), Double(y))) }
            }
        }
        let cx = sx / count, cy = sy / count
        var sum: Double = 0
        for (x, y) in points { sum += (x - cx) * (x - cx) + (y - cy) * (y - cy) }
        return Float(Double(mass) * sum / count)
    }

    private func contains(_ ring: [WorldPoint], _ x: Float, _ y: Float) -> Bool {
        var inside = false
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            if (a.y > y) != (b.y > y), x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        }
        return inside
    }
}
