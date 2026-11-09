import BubblePhysics
import XCTest

final class ModelValidationTests: XCTestCase {
    private let material = PhysicsMaterialID(rawValue: 1)
    private let style = RenderMaterialID(rawValue: 1)

    private func polygon(_ vertices: [WorldPoint], role: MotionRole = .static,
                         position: WorldPoint = .zero, rotation: Float = 0) throws -> RigidBodyDescriptor {
        try RigidBodyDescriptor(id: ObjectID(rawValue: 1), vertices: vertices,
                              position: position, rotation: rotation, motionRole: role,
                              physicsMaterialID: material, renderMaterialID: style)
    }

    func testConcaveSimplePolygonIsAcceptedButHoleAndSelfIntersectionAreRejected() throws {
        let concave: [WorldPoint] = [[0, 0], [4, 0], [4, 4], [2, 2], [0, 4]]
        XCTAssertNoThrow(try polygon(concave))
        XCTAssertNoThrow(try polygon(concave.reversed()))
        XCTAssertThrowsError(try PolygonGeometry(vertices: concave, holes: [[[1, 1], [2, 1], [1, 2]]])) {
            XCTAssertEqual($0 as? ModelValidationError, .polygonHolesUnsupported)
        }
        XCTAssertThrowsError(try polygon([[0, 0], [4, 4], [0, 4], [4, 0]]))
    }

    func testPolygonClosureAndDegenerateEdgesAreValidated() throws {
        let closed = try PolygonGeometry(vertices: [[0, 0], [2, 0], [2, 2], [0, 0]])
        XCTAssertEqual(closed.vertices.count, 3)
        for vertices: [WorldPoint] in [
            [], [[0, 0], [1, 1]], [[0, 0], [1, 1], [2, 2]],
            [[0, 0], [2, 0], [2, 0], [0, 2]],
            [[0, 0], [3, 0], [1, 0], [1, 2]],
            [[0, 0], [4, 0], [4, 4], [2, 0], [0, 4]],
            [[0, 0], [.infinity, 0], [0, 2]],
            [[0, 0], [.nan, 0], [0, 2]]
        ] {
            XCTAssertThrowsError(try PolygonGeometry(vertices: vertices))
        }
        XCTAssertNoThrow(try PolygonGeometry(vertices: [[0, 0], [1, 0], [2, 0], [2, 2], [0, 2]]))
        XCTAssertNoThrow(try PolygonGeometry(vertices: [[0, 0], [1e-20, 0], [0, 1e-20]]))
    }

    func testViewportMapsScreenAndWorldWithoutChangingSimulationRegion() throws {
        let region = try WorldRectangle(min: [-100, -100], max: [100, 100])
        let configuration = try WorldConfiguration(simulationRegion: region)
        let viewport = try Viewport(center: [10, 20], size: [20, 10])
        XCTAssertEqual(try viewport.worldPoint(for: [0, 0], in: [200, 100]), [0, 25])
        XCTAssertEqual(try viewport.worldPoint(for: [200, 100], in: [200, 100]), [20, 15])
        XCTAssertEqual(try viewport.screenPoint(for: [5, 22.5], in: [200, 100]), [50, 25])
        XCTAssertEqual(try viewport.worldPoint(for: [300, 50], in: [200, 100]), [30, 20])
        XCTAssertEqual(configuration.simulationRegion, region)
    }

    func testViewportRejectsInvalidDimensionsAndNonfiniteCoordinates() throws {
        XCTAssertThrowsError(try Viewport(center: [.nan, 0], size: [1, 1]))
        XCTAssertThrowsError(try Viewport(center: .zero, size: [0, 1]))
        let viewport = try Viewport(center: .zero, size: [20, 10])
        XCTAssertThrowsError(try viewport.worldPoint(for: .zero, in: [0, 100]))
        XCTAssertThrowsError(try viewport.screenPoint(for: [.infinity, 0], in: [100, 100]))
    }

    func testMergeGroupSetUsesExactlyUInt64OverlapSemantics() {
        let highest = MergeGroupSet(rawValue: UInt64(1) << 63)
        let lowest = MergeGroupSet(rawValue: 1)
        XCTAssertTrue(highest.overlaps(MergeGroupSet(rawValue: .max)))
        XCTAssertFalse(highest.overlaps(lowest))
        XCTAssertFalse(MergeGroupSet().overlaps(MergeGroupSet(rawValue: .max)))
        XCTAssertEqual(highest.union(lowest).rawValue, 0x8000_0000_0000_0001)
    }

    func testStaticGeometryOutsideSimulationRegionIsRejected() throws {
        let configuration = try WorldConfiguration(simulationRegion: WorldRectangle(min: [0, 0], max: [10, 10]))
        XCTAssertNoThrow(try configuration.validate(polygon([[0, 0], [10, 0], [0, 10]])))
        XCTAssertThrowsError(try configuration.validate(polygon([[0, 0], [11, 0], [0, 10]]))) {
            XCTAssertEqual($0 as? ModelValidationError, .staticGeometryOutsideSimulationRegion)
        }
        XCTAssertThrowsError(try configuration.validate(polygon([[0, 0], [2, 0], [0, 2]], position: [9, 9])))
        XCTAssertThrowsError(try configuration.validate(polygon([[0, 0], [2, 0], [0, 2]], position: [1, 1], rotation: .pi)))
        for role: MotionRole in [.dynamic, .motorDriven, .pathDriven, .playerDriven] {
            XCTAssertNoThrow(try configuration.validate(polygon([[20, 20], [22, 20], [20, 22]], role: role)))
        }
        let bubble = try BubbleDescriptor(id: ObjectID(rawValue: 2), position: [0, 5], targetRadius: 1,
                                          motionRole: .static, physicsMaterialID: material, renderMaterialID: style)
        XCTAssertThrowsError(try configuration.validate(bubble))
    }

    func testConfigurationRejectsInvalidCapacityTimeAndRegion() throws {
        XCTAssertThrowsError(try WorldRectangle(min: [0, 0], max: [0, 1]))
        XCTAssertThrowsError(try WorldRectangle(min: [0, 0], max: [.infinity, 1]))
        let region = try WorldRectangle(min: [0, 0], max: [10, 10])
        XCTAssertThrowsError(try WorldConfiguration(simulationRegion: region, fixedTimeStep: 0))
        XCTAssertThrowsError(try WorldConfiguration(simulationRegion: region, fixedTimeStep: .nan))
        XCTAssertThrowsError(try WorldConfiguration(simulationRegion: region, eventBufferCapacity: 0))
        XCTAssertThrowsError(try WorldConfiguration(simulationRegion: region, globalForce: [.infinity, 0]))
    }

    // P-B-53: limit backlogu ma domyślną wartość 0,25 s i jest walidowany jak krok.
    func testMaximumBacklogDefaultsToQuarterSecondAndIsValidated() throws {
        let region = try WorldRectangle(min: [-1, -1], max: [1, 1])
        XCTAssertEqual(try WorldConfiguration(simulationRegion: region).maximumBacklog, 0.25)
        XCTAssertEqual(try WorldConfiguration(simulationRegion: region, maximumBacklog: 2).maximumBacklog, 2)
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try WorldConfiguration(simulationRegion: region, maximumBacklog: invalid)) {
                XCTAssertEqual($0 as? ModelValidationError, .nonFiniteValue("maximumBacklog"))
            }
        }
        for invalid in [0.0, -0.25] {
            XCTAssertThrowsError(try WorldConfiguration(simulationRegion: region, maximumBacklog: invalid)) {
                XCTAssertEqual($0 as? ModelValidationError, .nonPositiveValue("maximumBacklog"))
            }
        }
    }

    func testBubbleAndPolygonValidatePhysicalValues() throws {
        for radius: Float in [0, -1, .nan, .infinity] {
            XCTAssertThrowsError(try BubbleDescriptor(id: ObjectID(rawValue: 1), position: .zero,
                                                      targetRadius: radius, physicsMaterialID: material, renderMaterialID: style))
        }
        XCTAssertThrowsError(try BubbleDescriptor(id: ObjectID(rawValue: 1), position: [.nan, 0], targetRadius: 1,
                                                  physicsMaterialID: material, renderMaterialID: style))
        XCTAssertThrowsError(try BubbleDescriptor(id: ObjectID(rawValue: 1), position: .zero, targetRadius: 1, mass: 0,
                                                  physicsMaterialID: material, renderMaterialID: style))
        XCTAssertThrowsError(try RigidBodyDescriptor(id: ObjectID(rawValue: 1), vertices: [[0, 0], [1, 0], [0, 1]],
                                                   momentOfInertia: 0, physicsMaterialID: material, renderMaterialID: style))
        XCTAssertThrowsError(try polygon([[0, 0], [1, 0], [0, 1]], rotation: .infinity))
    }

    func testFieldAndSensorValidateRangesAndFieldParameters() throws {
        let circle = try RangeGeometry.circle(radius: 3)
        XCTAssertNoThrow(try ForceFieldDescriptor(id: ObjectID(rawValue: 3), position: .zero, geometry: circle,
                                                 field: .radial(strength: -2, falloff: 1)))
        XCTAssertThrowsError(try RangeGeometry.circle(radius: 0))
        XCTAssertThrowsError(try ForceFieldDescriptor(id: ObjectID(rawValue: 3), position: .zero, geometry: circle,
                                                     field: .directional(force: [.nan, 0])))
        XCTAssertThrowsError(try ForceFieldDescriptor(id: ObjectID(rawValue: 3), position: .zero, geometry: circle,
                                                     field: .vortex(strength: 1, falloff: -1)))
        XCTAssertThrowsError(try SensorDescriptor(id: ObjectID(rawValue: 4), position: [.infinity, 0],
                                                 geometry: circle))
        let configuration = try WorldConfiguration(simulationRegion: WorldRectangle(min: [-2, -2], max: [2, 2]))
        let sensor = try SensorDescriptor(id: ObjectID(rawValue: 4), position: .zero, geometry: circle)
        XCTAssertThrowsError(try configuration.validate(sensor))
        let field = try ForceFieldDescriptor(id: ObjectID(rawValue: 3), position: .zero, geometry: circle,
                                             field: .directional(force: [1, 0]))
        XCTAssertThrowsError(try configuration.validate(field))
    }

    func testPhysicsMaterialValidatesRanges() throws {
        XCTAssertThrowsError(try PhysicsMaterial(kind: .bubble, deformability: 1.1))
        XCTAssertThrowsError(try PhysicsMaterial(kind: .rigid, friction: -1))
        XCTAssertThrowsError(try PhysicsMaterial(kind: .bubble, damping: .nan))
        XCTAssertThrowsError(try PhysicsMaterial(kind: .bubble, restitution: 2))
    }

    func testMaterialSpeedLimitsAreOptionalAndMustBePositiveAndFinite() throws {
        let unlimited = try PhysicsMaterial(kind: .rigid)
        XCTAssertNil(unlimited.maximumLinearSpeed)
        XCTAssertNil(unlimited.maximumAngularSpeed)
        let limited = try PhysicsMaterial(kind: .bubble, maximumLinearSpeed: 30, maximumAngularSpeed: 4)
        XCTAssertEqual(limited.maximumLinearSpeed, 30)
        XCTAssertEqual(limited.maximumAngularSpeed, 4)
        for bad: Float in [0, -1, .nan, .infinity] {
            XCTAssertThrowsError(try PhysicsMaterial(kind: .rigid, maximumLinearSpeed: bad), "linear \(bad)")
            XCTAssertThrowsError(try PhysicsMaterial(kind: .rigid, maximumAngularSpeed: bad), "angular \(bad)")
        }
    }

    func testStaticCircleAndCapsuleMustFitInsideSimulationRegion() throws {
        let configuration = try WorldConfiguration(simulationRegion: WorldRectangle(min: [0, 0], max: [10, 10]))
        func body(_ shape: RigidShape, position: WorldPoint, rotation: Float = 0) throws -> RigidBodyDescriptor {
            try RigidBodyDescriptor(id: ObjectID(rawValue: 1), shape: shape, position: position, rotation: rotation,
                                    motionRole: .static, physicsMaterialID: material, renderMaterialID: style)
        }
        XCTAssertNoThrow(try configuration.validate(body(.circle(radius: 2), position: [5, 5])))
        XCTAssertThrowsError(try configuration.validate(body(.circle(radius: 2), position: [1, 5]))) {
            XCTAssertEqual($0 as? ModelValidationError, .staticGeometryOutsideSimulationRegion)
        }
        // Kapsuła poziomo mieści się (końce na x = 2 i 8), obrócona o 90° wystaje przez górę.
        let capsule = RigidShape.capsule(halfLength: 3, radius: 1)
        XCTAssertNoThrow(try configuration.validate(body(capsule, position: [5, 5])))
        XCTAssertThrowsError(try configuration.validate(body(capsule, position: [5, 8], rotation: .pi / 2)))
        XCTAssertNoThrow(try configuration.validate(body(capsule, position: [5, 5], rotation: .pi / 2)))
    }

    func testJointValidatesAnchorsBodiesAndKindParameters() throws {
        let a = ObjectID(rawValue: 1), b = ObjectID(rawValue: 2)
        let id = JointID(rawValue: 1)
        let rigid = Joint.Kind.distance(length: 3, softness: 0, damping: 0)
        XCTAssertNoThrow(try Joint(id: id, bodyA: a, bodyB: b, kind: rigid))
        XCTAssertNoThrow(try Joint(id: id, bodyA: a, bodyB: nil, anchorB: [4, 5], kind: rigid))
        XCTAssertThrowsError(try Joint(id: id, bodyA: a, bodyB: a, kind: rigid), "to samo ciało na obu końcach")
        XCTAssertThrowsError(try Joint(id: id, bodyA: a, bodyB: b, anchorA: [.nan, 0], kind: rigid))
        XCTAssertThrowsError(try Joint(id: id, bodyA: a, bodyB: b, anchorB: [0, .infinity], kind: rigid))
        XCTAssertThrowsError(try Joint(id: id, bodyA: a, bodyB: b, referenceAngle: .nan, kind: .weld))
        for kind: Joint.Kind in [.distance(length: -1, softness: 0, damping: 0),
                                 .distance(length: .nan, softness: 0, damping: 0),
                                 .distance(length: 1, softness: -0.1, damping: 0),
                                 .distance(length: 1, softness: 0, damping: -1)] {
            XCTAssertThrowsError(try Joint(id: id, bodyA: a, bodyB: b, kind: kind), "\(kind)")
        }
        XCTAssertThrowsError(try HingeLimits(lower: 1, upper: -1))
        XCTAssertThrowsError(try HingeLimits(lower: .nan, upper: 1))
        XCTAssertNoThrow(try HingeLimits(lower: -0.5, upper: 0.5))
        XCTAssertThrowsError(try HingeMotor(targetAngularVelocity: 1, maximumTorque: 0))
        XCTAssertThrowsError(try HingeMotor(targetAngularVelocity: .nan, maximumTorque: 1))
        let hinge = try Joint(id: id, bodyA: a, bodyB: b,
                              kind: .hinge(limits: HingeLimits(lower: -1, upper: 1),
                                           motor: HingeMotor(targetAngularVelocity: 2, maximumTorque: 5)))
        XCTAssertFalse(hinge.collideConnected, "ciała połączone więzem domyślnie nie kolidują")
        XCTAssertTrue(try Joint(id: id, bodyA: a, bodyB: b, kind: .weld, collideConnected: true).collideConnected)
    }
}

/// P-B-39: materiał renderu sprawdza kolor, obrys i mapowanie UV przy tworzeniu.
extension ModelValidationTests {
    func testColorComponentsMustBeFiniteAndInUnitRange() throws {
        for value in [RGBA(-0.01, 0, 0, 1), RGBA(0, 1.01, 0, 1), RGBA(0, 0, 2, 1), RGBA(0, 0, 0, -1), RGBA(0, 0, 0, 1.5)] {
            XCTAssertThrowsError(try RenderMaterial(color: value)) {
                XCTAssertEqual($0 as? ModelValidationError, .valueOutOfRange("renderMaterial.color"))
            }
        }
        for value in [RGBA(.nan, 0, 0, 1), RGBA(0, .infinity, 0, 1), RGBA(0, 0, 0, .nan)] {
            XCTAssertThrowsError(try RenderMaterial(color: value)) {
                XCTAssertEqual($0 as? ModelValidationError, .nonFiniteValue("renderMaterial.color"))
            }
        }
        XCTAssertNoThrow(try RenderMaterial(color: RGBA(0, 0, 0, 0)))
        XCTAssertNoThrow(try RenderMaterial(color: RGBA(1, 1, 1, 1)))
    }

    func testOutlineWidthMustBeFiniteAndNonnegativeAndItsColorInRange() throws {
        XCTAssertThrowsError(try RenderMaterial(outline: RenderOutline(color: .white, width: -0.1))) {
            XCTAssertEqual($0 as? ModelValidationError, .valueOutOfRange("renderMaterial.outline.width"))
        }
        for width in [Float.nan, .infinity] {
            XCTAssertThrowsError(try RenderMaterial(outline: RenderOutline(color: .white, width: width))) {
                XCTAssertEqual($0 as? ModelValidationError, .nonFiniteValue("renderMaterial.outline.width"))
            }
        }
        XCTAssertThrowsError(try RenderMaterial(outline: RenderOutline(color: RGBA(0, 2, 0, 1), width: 1))) {
            XCTAssertEqual($0 as? ModelValidationError, .valueOutOfRange("renderMaterial.outline.color"))
        }
        XCTAssertNoThrow(try RenderMaterial(outline: RenderOutline(color: .white, width: 0)))
        XCTAssertNoThrow(try RenderMaterial(outline: RenderOutline(color: RGBA(1, 0, 0, 1), width: 0.5)))
    }

    func testUVScaleMustBeFiniteAndNonzeroAndOffsetFinite() throws {
        for scale: SIMD2<Float> in [[0, 1], [1, 0], [0, 0]] {
            XCTAssertThrowsError(try RenderMaterial(uvScale: scale)) {
                XCTAssertEqual($0 as? ModelValidationError, .valueOutOfRange("renderMaterial.uvScale"))
            }
        }
        for scale: SIMD2<Float> in [[.nan, 1], [1, .infinity]] {
            XCTAssertThrowsError(try RenderMaterial(uvScale: scale)) {
                XCTAssertEqual($0 as? ModelValidationError, .nonFiniteValue("renderMaterial.uvScale"))
            }
        }
        XCTAssertThrowsError(try RenderMaterial(uvOffset: [.nan, 0])) {
            XCTAssertEqual($0 as? ModelValidationError, .nonFiniteValue("renderMaterial.uvOffset"))
        }
        // Ujemna skala odwraca teksturę i jest poprawna.
        XCTAssertNoThrow(try RenderMaterial(uvOffset: [-3, 2], uvScale: [-2, 0.5]))
    }
}
