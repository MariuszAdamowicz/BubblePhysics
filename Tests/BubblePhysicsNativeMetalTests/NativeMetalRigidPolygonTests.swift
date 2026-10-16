import BubblePhysicsModel
import Metal
@testable import BubblePhysicsNativeMetal
import XCTest

@MainActor
final class NativeMetalRigidPolygonTests: XCTestCase {
    private let polygonID = ObjectID(rawValue: UInt64.max)
    private let bubbleID = ObjectID(rawValue: 1)
    private func polygon(role: MotionRole = .dynamic, position: WorldPoint = .zero,
                         velocity: WorldPoint = .zero, angular: Float = 0,
                         vertices: [WorldPoint] = [[-1,-1],[1,-1],[1,1],[-1,1]]) throws -> NativePublicObject {
        NativePublicObject(descriptor: .polygon(try PolygonDescriptor(id: polygonID,
            vertices: vertices, position: position, velocity: velocity, angularVelocity: angular,
            mass: 2, momentOfInertia: 2, motionRole: role,
            physicsMaterialID: .init(rawValue: 2), renderStyleID: .init(rawValue: 1))))
    }
    private func bubble(position: WorldPoint = [-1.6,0.6], velocity: WorldPoint = [6,0]) throws -> NativePublicObject {
        NativePublicObject(descriptor: .bubble(try BubbleDescriptor(id: bubbleID,
            position: position, velocity: velocity, targetRadius: 0.5,
            physicsMaterialID: .init(rawValue: 1), renderStyleID: .init(rawValue: 1))))
    }
    private func step(_ world: NativePublicWorld, _ objects: [NativePublicObject], dt: Double = 1.0/60) async throws -> NativePublicFrame {
        try await world.step(objects: objects,
            materials: [.init(rawValue: 1): PhysicsMaterial(kind: .bubble), .init(rawValue: 2): PhysicsMaterial(kind: .polygon)],
            styles: [.init(rawValue: 1): RenderStyle()], region: WorldRectangle(min: [-100,-100], max: [100,100]), duration: dt)
    }

    // Brak reakcji drugiego ciała lub momentu kontaktowego musi złamać ten test.
    func testDynamicPolygonReceivesTranslationAndRotationFromBubbleImpact() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var frame = try await step(world, [polygon(), bubble()])
        for _ in 0..<12 { frame = try await step(world, Array(frame.objects.values)) }
        let body = try XCTUnwrap(frame.objects[polygonID])
        let ball = try XCTUnwrap(frame.objects[bubbleID])
        XCTAssertGreaterThan(body.position.x, 0.05)
        XCTAssertLessThan(body.rotation, -0.02)
        XCTAssertGreaterThan(body.velocity.x, 0.1)
        XCTAssertLessThan(body.angularVelocity, -0.1)
        XCTAssertLessThan(ball.velocity.x, 5.9)
        XCTAssertEqual(frame.profile.commandBufferCount, 1)
    }

    func testStaticPolygonDoesNotMoveUnderSameImpact() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var frame = try await step(world, [polygon(role: .static), bubble()])
        for _ in 0..<12 { frame = try await step(world, Array(frame.objects.values)) }
        XCTAssertEqual(frame.objects[polygonID]?.position, .zero)
        XCTAssertEqual(frame.objects[polygonID]?.rotation, 0)
    }

    // Wypełnienie wklęsłości convex hullem wypchnęłoby bańkę z pustej wnęki.
    func testConcavePolygonUsesInternalConvexPiecesWithoutPublicDecomposition() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let object = try polygon(vertices: [[0,0],[3,0],[3,1],[1,1],[1,3],[0,3]])
        var frame = try await step(world, [object, bubble(position: [2,2], velocity: .zero)])
        for _ in 0..<5 { frame = try await step(world, Array(frame.objects.values)) }
        XCTAssertEqual(frame.objects[bubbleID]?.position, WorldPoint(2,2))
        XCTAssertEqual(frame.objects[polygonID]?.position, .zero)
        frame = try await step(world, [object, bubble(position: [3.4,0.7], velocity: [-6,0])])
        for _ in 0..<5 { frame = try await step(world, Array(frame.objects.values)) }
        XCTAssertLessThan(try XCTUnwrap(frame.objects[polygonID]).velocity.x, -0.1)
    }

    func testPolygonContactPreservesFiniteStateAndDoesNotMoveThroughStaticWall() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let wall = NativePublicObject(descriptor: .polygon(try PolygonDescriptor(id: .init(rawValue: 3),
            vertices: [[2,-10],[2.25,-10],[2.25,10],[2,10]],
            physicsMaterialID: .init(rawValue: 2), renderStyleID: .init(rawValue: 1))))
        var frame = try await step(world, [polygon(velocity: [8,0], angular: 0.5), wall])
        for _ in 0..<60 {
            frame = try await step(world, Array(frame.objects.values))
            let body = try XCTUnwrap(frame.objects[polygonID])
            XCTAssertTrue(body.position.x.isFinite && body.rotation.isFinite && body.angularVelocity.isFinite)
            XCTAssertLessThan(body.position.x, 1.1)
        }
    }

    func testMotorPolygonIntegratesDeclaredLinearAndAngularVelocity() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let frame = try await step(world, [polygon(role: .motorDriven, velocity: [2,0], angular: 1)], dt: 0.25)
        let body = try XCTUnwrap(frame.objects[polygonID])
        XCTAssertEqual(body.position.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(body.rotation, 0.25, accuracy: 0.0001)
    }

    func testCentralImpactConservesLinearMomentumAndDoesNotGenerateSpin() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var frame = try await step(world, [polygon(), bubble(position: [-1.6,0])])
        for _ in 0..<8 { frame = try await step(world, Array(frame.objects.values)) }
        let body = try XCTUnwrap(frame.objects[polygonID]), ball = try XCTUnwrap(frame.objects[bubbleID])
        XCTAssertEqual(2 * body.velocity.x + ball.velocity.x, 6, accuracy: 0.001)
        XCTAssertEqual(body.angularVelocity, 0, accuracy: 0.001)
        XCTAssertGreaterThan(body.velocity.x, 1)
        XCTAssertEqual(frame.profile.rigidBodyUploadCount, 0)
        XCTAssertEqual(frame.profile.rigidGeometryUploadCount, 0)
    }

    func testFastBubbleCannotTunnelThroughThinDynamicPolygon() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let frame = try await step(world, [polygon(vertices: [[-0.1,-2],[0.1,-2],[0.1,2],[-0.1,2]]),
            bubble(position: [-3,0], velocity: [360,0])])
        let body = try XCTUnwrap(frame.objects[polygonID]), ball = try XCTUnwrap(frame.objects[bubbleID])
        XCTAssertLessThan(ball.position.x, body.position.x)
        XCTAssertGreaterThan(body.velocity.x, 1)
    }

    func testBubbleCannotPushPolygonThroughStaticWall() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let wall = NativePublicObject(descriptor: .polygon(try PolygonDescriptor(id: .init(rawValue: 3),
            vertices: [[1,-10],[1.1,-10],[1.1,10],[1,10]],
            physicsMaterialID: .init(rawValue: 2), renderStyleID: .init(rawValue: 1))))
        var frame = try await step(world, [polygon(), bubble(position: [-1.6,0], velocity: [60,0]), wall])
        for _ in 0..<30 {
            frame = try await step(world, Array(frame.objects.values))
            let body = try XCTUnwrap(frame.objects[polygonID])
            let extent = abs(cos(body.rotation)) + abs(sin(body.rotation))
            XCTAssertLessThanOrEqual(body.position.x + extent, 1.01)
        }
    }

    func testRemovingEarlierPolygonPreservesRemainingGPUVelocity() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let earlier = NativePublicObject(descriptor: .polygon(try PolygonDescriptor(id: .init(rawValue: 3),
            vertices: [[-1,-1],[1,-1],[1,1],[-1,1]], position: [-10,0],
            physicsMaterialID: .init(rawValue: 2), renderStyleID: .init(rawValue: 1))))
        var frame = try await step(world, [polygon(velocity: [2,0]), earlier], dt: 0.25)
        frame = try await step(world, [XCTUnwrap(frame.objects[polygonID])], dt: 0.25)
        XCTAssertEqual(try XCTUnwrap(frame.objects[polygonID]).position.x, 1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(frame.objects[polygonID]).velocity.x, 2, accuracy: 0.0001)
    }

    func testFailedGeometryChangeCannotCorruptPublishedCollisionShape() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let first = try await step(world, [polygon()])
        do {
            _ = try await step(world, [polygon(angular: 1000, vertices: [[-0.1,-2],[0.1,-2],[0.1,2],[-0.1,2]])])
            XCTFail("Przekroczenie budżetu sweep musi odrzucić całą klatkę")
        } catch { }
        let frame = try await step(world, [XCTUnwrap(first.objects[polygonID]), bubble(position: [-1.4,0], velocity: .zero)])
        XCTAssertLessThan(try XCTUnwrap(frame.objects[bubbleID]).position.x, -1.41)
        XCTAssertGreaterThan(try XCTUnwrap(frame.objects[polygonID]).position.x, 0.01)
    }
}
