import BubblePhysics
import XCTest

final class ModelValidationTests: XCTestCase {
    private let material = PhysicsMaterialID(rawValue: 1)
    private let style = RenderStyleID(rawValue: 1)

    private func polygon(_ vertices: [WorldPoint], role: MotionRole = .static,
                         position: WorldPoint = .zero, rotation: Float = 0) throws -> PolygonDescriptor {
        try PolygonDescriptor(id: ObjectID(rawValue: 1), vertices: vertices,
                              position: position, rotation: rotation, motionRole: role,
                              physicsMaterialID: material, renderStyleID: style)
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
                                          motionRole: .static, physicsMaterialID: material, renderStyleID: style)
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

    func testBubbleAndPolygonValidatePhysicalValues() throws {
        for radius: Float in [0, -1, .nan, .infinity] {
            XCTAssertThrowsError(try BubbleDescriptor(id: ObjectID(rawValue: 1), position: .zero,
                                                      targetRadius: radius, physicsMaterialID: material, renderStyleID: style))
        }
        XCTAssertThrowsError(try BubbleDescriptor(id: ObjectID(rawValue: 1), position: [.nan, 0], targetRadius: 1,
                                                  physicsMaterialID: material, renderStyleID: style))
        XCTAssertThrowsError(try BubbleDescriptor(id: ObjectID(rawValue: 1), position: .zero, targetRadius: 1, mass: 0,
                                                  physicsMaterialID: material, renderStyleID: style))
        XCTAssertThrowsError(try PolygonDescriptor(id: ObjectID(rawValue: 1), vertices: [[0, 0], [1, 0], [0, 1]],
                                                   momentOfInertia: 0, physicsMaterialID: material, renderStyleID: style))
        XCTAssertThrowsError(try polygon([[0, 0], [1, 0], [0, 1]], rotation: .infinity))
    }

    func testFieldAndSensorValidateRangesAndFieldParameters() throws {
        let circle = try RangeGeometry.circle(radius: 3)
        XCTAssertNoThrow(try ForceFieldDescriptor(id: ObjectID(rawValue: 3), position: .zero, geometry: circle,
                                                 field: .radial(strength: -2, falloff: 1), renderStyleID: style))
        XCTAssertThrowsError(try RangeGeometry.circle(radius: 0))
        XCTAssertThrowsError(try ForceFieldDescriptor(id: ObjectID(rawValue: 3), position: .zero, geometry: circle,
                                                     field: .directional(force: [.nan, 0]), renderStyleID: style))
        XCTAssertThrowsError(try ForceFieldDescriptor(id: ObjectID(rawValue: 3), position: .zero, geometry: circle,
                                                     field: .vortex(strength: 1, falloff: -1), renderStyleID: style))
        XCTAssertThrowsError(try SensorDescriptor(id: ObjectID(rawValue: 4), position: [.infinity, 0],
                                                 geometry: circle, renderStyleID: style))
        let configuration = try WorldConfiguration(simulationRegion: WorldRectangle(min: [-2, -2], max: [2, 2]))
        let sensor = try SensorDescriptor(id: ObjectID(rawValue: 4), position: .zero, geometry: circle, renderStyleID: style)
        XCTAssertThrowsError(try configuration.validate(sensor))
        let field = try ForceFieldDescriptor(id: ObjectID(rawValue: 3), position: .zero, geometry: circle,
                                             field: .directional(force: [1, 0]), renderStyleID: style)
        XCTAssertThrowsError(try configuration.validate(field))
    }

    func testResourcesValidatePhysicsAndLocalChannelsOverrideStyle() throws {
        XCTAssertThrowsError(try PhysicsMaterial(kind: .bubble, deformability: 1.1))
        XCTAssertThrowsError(try PhysicsMaterial(kind: .polygon, friction: -1))
        XCTAssertThrowsError(try PhysicsMaterial(kind: .bubble, damping: .nan))
        XCTAssertThrowsError(try PhysicsMaterial(kind: .bubble, restitution: 2))
        let saturation = ParameterID(rawValue: "saturation")
        let highlight = ParameterID(rawValue: "selectionHighlight")
        let renderStyle = try RenderStyle(shader: .custom("game.bubble"), channels: [saturation: 0.5, highlight: 0])
        let local = try PresentationParameters(channels: [highlight: 1])
        XCTAssertEqual(renderStyle.resolvedChannels(overrides: local), [saturation: 0.5, highlight: 1])
        XCTAssertThrowsError(try PresentationParameters(channels: [saturation: .nan]))
        XCTAssertThrowsError(try RenderStyle(shader: .technical, channels: [saturation: .infinity]))
    }
}
