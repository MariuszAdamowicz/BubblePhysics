import BubblePhysics
import BubblePhysicsMetalRender
import Metal
import XCTest
import simd

/// P-B-4, P-B-5, P-B-6 (G2-AC1..AC3): świat publikuje stan każdego obiektu w `frame.objects`.
@MainActor
final class ObjectStateTests: XCTestCase {
    private let bubbleMaterial = PhysicsMaterialID(rawValue: 1)
    private let polygonMaterial = PhysicsMaterialID(rawValue: 2)
    private let style = RenderStyleID(rawValue: 1)

    private func makeWorld(device: MTLDevice) throws -> BubbleWorld {
        try BubbleWorld.makeBenchmarkWorld(configuration: try WorldConfiguration(
            simulationRegion: WorldRectangle(min: [0, 0], max: [200, 200]), fixedTimeStep: 1.0 / 60),
            device: device, solverIterationLimit: 4)
    }

    private func baseTransaction() throws -> WorldTransaction {
        try WorldTransaction()
            .updatePhysicsMaterial(bubbleMaterial, material: PhysicsMaterial(kind: .bubble))
            .updatePhysicsMaterial(polygonMaterial, material: PhysicsMaterial(kind: .polygon))
            .updateRenderStyle(style, style: RenderStyle())
    }

    private func bubble(_ id: UInt64, at position: WorldPoint, radius: Float,
                        velocity: WorldPoint = .zero) throws -> WorldObject {
        .bubble(try BubbleDescriptor(id: ObjectID(rawValue: id), position: position, velocity: velocity,
            targetRadius: radius, physicsMaterialID: bubbleMaterial, renderStyleID: style))
    }

    private func box(_ id: UInt64, center: WorldPoint, half: Float, role: MotionRole = .dynamic,
                     velocity: WorldPoint = .zero, angularVelocity: Float = 0) throws -> WorldObject {
        .polygon(try PolygonDescriptor(id: ObjectID(rawValue: id),
            vertices: [[-half, -half], [half, -half], [half, half], [-half, half]], position: center,
            velocity: velocity, angularVelocity: angularVelocity, motionRole: role,
            physicsMaterialID: polygonMaterial, renderStyleID: style))
    }

    func testEveryBubbleAndRigidBodyHasStateWithKinematicsAndBounds() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try makeWorld(device: device)
        world.submit(try baseTransaction()
            .add(try bubble(1, at: [60, 100], radius: 12, velocity: [20, 0]))
            .add(try bubble(2, at: [140, 60], radius: 9))
            .add(try box(3, center: [100, 150], half: 10, velocity: [0, -5], angularVelocity: 1))
            .add(try box(4, center: [100, 190], half: 8, role: .static)))
        var frame = WorldFrame(transactionReceipts: [], events: [])
        for _ in 0..<30 { frame = await world.advance(by: 1.0 / 60) }
        XCTAssertEqual(frame.stepIndex, 30)
        XCTAssertEqual(Set(frame.objects.keys).map(\.rawValue).sorted(), [1, 2, 3, 4])
        for (id, state) in frame.objects {
            XCTAssertTrue(state.position.x.isFinite && state.position.y.isFinite, "\(id)")
            XCTAssertTrue(state.bounds.min.x < state.bounds.max.x && state.bounds.min.y < state.bounds.max.y)
            XCTAssertTrue(state.bounds.contains(state.position), "AABB obiektu \(id) nie zawiera jego środka")
        }
        let moving = try XCTUnwrap(frame.objects[ObjectID(rawValue: 1)])
        XCTAssertGreaterThan(moving.position.x, 60, "bańka z prędkością 20 powinna odjechać w prawo")
        XCTAssertGreaterThan(moving.velocity.x, 1)
        guard case .bubble(let radius) = moving.kind else { return XCTFail("bańka ma kind .bubble") }
        XCTAssertEqual(radius, 12, accuracy: 3)
        let spinning = try XCTUnwrap(frame.objects[ObjectID(rawValue: 3)])
        XCTAssertEqual(spinning.kind, .polygon)
        XCTAssertNotEqual(spinning.rotation, 0)
        XCTAssertNotEqual(spinning.angularVelocity, 0)
        let wall = try XCTUnwrap(frame.objects[ObjectID(rawValue: 4)])
        XCTAssertEqual(wall.position, [100, 190])
        XCTAssertEqual(wall.bounds.min.x, 92, accuracy: 1e-3)
        XCTAssertEqual(wall.bounds.max.y, 198, accuracy: 1e-3)
    }

    func testStress300BubbleCenterMatchesContourCentroidAndBoundsContainContour() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try BubbleWorld.makeBenchmarkWorld(configuration: try Stress300Scene.configuration(),
            device: device, solverIterationLimit: 4)
        world.submit(try Stress300Scene.initialTransaction())
        var frame = WorldFrame(transactionReceipts: [], events: [])
        for index in 0..<60 {
            if index > 0 { world.submit(try Stress300Scene.triangleReplacement(step: index)) }
            frame = await world.advance(by: 1.0 / 60)
        }
        let contours = world.debugContourSnapshot()
        XCTAssertEqual(contours.count, 300)
        for (id, contour) in contours {
            let state = try XCTUnwrap(frame.objects[id], "brak stanu bańki \(id)")
            guard case .bubble(let radius) = state.kind else { return XCTFail("\(id) nie jest bańką") }
            // Centroid pola wielokąta konturu.
            var area: Double = 0, cx: Double = 0, cy: Double = 0
            for index in contour.indices {
                let a = contour[index], b = contour[(index + 1) % contour.count]
                let cross = Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
                area += cross; cx += (Double(a.x) + Double(b.x)) * cross; cy += (Double(a.y) + Double(b.y)) * cross
            }
            let centroid = WorldPoint(Float(cx / (3 * area)), Float(cy / (3 * area)))
            XCTAssertLessThanOrEqual(simd_distance(centroid, state.position), 0.01 * radius, "bańka \(id)")
            for point in contour {
                XCTAssertTrue(point.x >= state.bounds.min.x - 1e-3 && point.x <= state.bounds.max.x + 1e-3
                    && point.y >= state.bounds.min.y - 1e-3 && point.y <= state.bounds.max.y + 1e-3,
                    "kontur bańki \(id) wychodzi poza AABB")
            }
        }
    }

    func testRemovedObjectIsAbsentFromThatFramesStateAndReadingStateDoesNotReadContours() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try makeWorld(device: device)
        world.submit(try baseTransaction()
            .add(try bubble(1, at: [60, 100], radius: 12))
            .add(try bubble(2, at: [140, 100], radius: 12))
            .add(try box(3, center: [100, 20], half: 10, role: .static)))
        let before = await world.advance(by: 1.0 / 60)
        XCTAssertEqual(Set(before.objects.keys).map(\.rawValue).sorted(), [1, 2, 3])
        world.submit(WorldTransaction().remove(ObjectID(rawValue: 1)).remove(ObjectID(rawValue: 3)))
        let after = await world.advance(by: 1.0 / 60)
        XCTAssertEqual(after.stepIndex, 2)
        XCTAssertEqual(Set(after.objects.keys).map(\.rawValue).sorted(), [2])
        XCTAssertEqual(world.benchmarkContourCPUReadbackCount, 0)
    }

    func testRotatedPolygonBoundsFollowItsRotation() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try makeWorld(device: device)
        world.submit(try baseTransaction().add(.polygon(try PolygonDescriptor(id: ObjectID(rawValue: 7),
            vertices: [[-10, -10], [10, -10], [10, 10], [-10, 10]], position: [100, 100], rotation: .pi / 4,
            motionRole: .static, physicsMaterialID: polygonMaterial, renderStyleID: style))))
        let frame = await world.advance(by: 1.0 / 60)
        let state = try XCTUnwrap(frame.objects[ObjectID(rawValue: 7)])
        XCTAssertEqual(state.rotation, .pi / 4, accuracy: 1e-5)
        XCTAssertEqual(state.bounds.min.x, 100 - 10 * Float(2).squareRoot(), accuracy: 1e-3)
        XCTAssertEqual(state.bounds.max.y, 100 + 10 * Float(2).squareRoot(), accuracy: 1e-3)
    }

    /// Zawinięcie przesuwa kontur po obliczeniu AABB; granice muszą przesunąć się razem z konturem.
    func testWrappedBubbleBoundsMatchItsContourAfterWrap() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try makeWorld(device: device)
        let id = ObjectID(rawValue: 1)
        world.submit(try baseTransaction().add(.bubble(try BubbleDescriptor(id: id, position: [190, 100],
            velocity: [900, 0], targetRadius: 8, regionExitPolicy: .wrap, physicsMaterialID: bubbleMaterial,
            renderStyleID: style, eventInterest: [.didWrap]))))
        var wrapped = false
        var frame = WorldFrame(transactionReceipts: [], events: [])
        for _ in 0..<20 {
            frame = await world.advance(by: 1.0 / 60)
            if frame.events.contains(.didWrap(id)) { wrapped = true; break }
        }
        XCTAssertTrue(wrapped, "bańka powinna się zawinąć")
        let state = try XCTUnwrap(frame.objects[id])
        let contour = try XCTUnwrap(world.debugContourSnapshot()[id])
        XCTAssertEqual(state.bounds.min.x, contour.map(\.x).min() ?? .nan, accuracy: 1e-3)
        XCTAssertEqual(state.bounds.max.x, contour.map(\.x).max() ?? .nan, accuracy: 1e-3)
        XCTAssertEqual(state.bounds.min.y, contour.map(\.y).min() ?? .nan, accuracy: 1e-3)
        XCTAssertEqual(state.bounds.max.y, contour.map(\.y).max() ?? .nan, accuracy: 1e-3)
        XCTAssertTrue(state.bounds.contains(state.position))
    }

    func testObjectsStateSurvivesAFrameWithoutNewStepAndForSceneWithoutBodies() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try makeWorld(device: device)
        world.submit(try baseTransaction().add(try bubble(1, at: [60, 100], radius: 12)))
        let first = await world.advance(by: 1.0 / 60)
        let second = await world.advance(by: 0.001)
        XCTAssertEqual(second.stepIndex, first.stepIndex)
        XCTAssertEqual(second.objects, first.objects)
        XCTAssertEqual(first.objects.count, 1)
    }
}
