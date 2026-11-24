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
        NativePublicObject(descriptor: .rigidBody(try RigidBodyDescriptor(id: polygonID,
            vertices: vertices, position: position, velocity: velocity, angularVelocity: angular,
            mass: 2, momentOfInertia: 2, motionRole: role,
            physicsMaterialID: .init(rawValue: 2), renderMaterialID: .init(rawValue: 1))))
    }
    private func bubble(position: WorldPoint = [-1.6,0.6], velocity: WorldPoint = [6,0], radius: Float = 0.5) throws -> NativePublicObject {
        NativePublicObject(descriptor: .bubble(try BubbleDescriptor(id: bubbleID,
            position: position, velocity: velocity, targetRadius: radius,
            physicsMaterialID: .init(rawValue: 1), renderMaterialID: .init(rawValue: 1))))
    }
    private func step(_ world: NativePublicWorld, _ objects: [NativePublicObject], dt: Double = 1.0/60) async throws -> NativePublicFrame {
        try await world.step(objects: objects,
            materials: [.init(rawValue: 1): PhysicsMaterial(kind: .bubble, contactStiffness: 1e4), .init(rawValue: 2): PhysicsMaterial(kind: .rigid)],
            region: WorldRectangle(min: [-100,-100], max: [100,100]), duration: dt)
    }

    func testStaticPolygonDoesNotMoveUnderSameImpact() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var frame = try await step(world, [polygon(role: .static), bubble()])
        for _ in 0..<12 { frame = try await step(world, Array(frame.objects.values)) }
        XCTAssertEqual(frame.objects[polygonID]?.position, .zero)
        XCTAssertEqual(frame.objects[polygonID]?.rotation, 0)
    }

    // Wypełnienie wklęsłości convex hullem wypchnęłoby bańkę z pustej wnęki. Wielokąt jest statyczny: w 4.0.0 bańka nie ma kontaktu
    // z bryłą dynamiczną (CD-D-2), a kontakt ze statyczną używa wewnętrznych wypukłych części wielokąta wklęsłego.
    func testConcavePolygonUsesInternalConvexPiecesWithoutPublicDecomposition() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let object = try polygon(role: .static, vertices: [[0,0],[3,0],[3,1],[1,1],[1,3],[0,3]])
        var frame = try await step(world, [object, bubble(position: [2,2], velocity: .zero)])
        for _ in 0..<5 { frame = try await step(world, Array(frame.objects.values)) }
        XCTAssertEqual(try XCTUnwrap(frame.objects[bubbleID]).position.x, 2, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(frame.objects[bubbleID]).position.y, 2, accuracy: 1e-4)
        XCTAssertEqual(frame.objects[polygonID]?.position, .zero)
        frame = try await step(world, [object, bubble(position: [3.4,0.7], velocity: [-6,0])])
        for _ in 0..<5 { frame = try await step(world, Array(frame.objects.values)) }
        XCTAssertGreaterThan(try XCTUnwrap(frame.objects[bubbleID]).velocity.x, 0, "bańka odbija się od prawej ściany wnęki")
        XCTAssertGreaterThan(try XCTUnwrap(frame.objects[bubbleID]).position.x, 3.5 - 0.5, "środek bańki zostaje po zewnętrznej stronie")
    }

    func testPolygonContactPreservesFiniteStateAndDoesNotMoveThroughStaticWall() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let wall = NativePublicObject(descriptor: .rigidBody(try RigidBodyDescriptor(id: .init(rawValue: 3),
            vertices: [[2,-10],[2.25,-10],[2.25,10],[2,10]],
            physicsMaterialID: .init(rawValue: 2), renderMaterialID: .init(rawValue: 1))))
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

    func testFastBubbleCannotTunnelThroughThinStaticPolygon() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let frame = try await step(world, [polygon(role: .static, vertices: [[-0.1,-2],[0.1,-2],[0.1,2],[-0.1,2]]),
            bubble(position: [-3,0], velocity: [360,0])])
        let body = try XCTUnwrap(frame.objects[polygonID]), ball = try XCTUnwrap(frame.objects[bubbleID])
        XCTAssertLessThan(ball.position.x, body.position.x - 0.1, "środek bańki zostaje po stronie startowej")
    }

    func testRemovingEarlierPolygonPreservesRemainingGPUVelocity() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let earlier = NativePublicObject(descriptor: .rigidBody(try RigidBodyDescriptor(id: .init(rawValue: 3),
            vertices: [[-1,-1],[1,-1],[1,1],[-1,1]], position: [-10,0],
            physicsMaterialID: .init(rawValue: 2), renderMaterialID: .init(rawValue: 1))))
        var frame = try await step(world, [polygon(velocity: [2,0]), earlier], dt: 0.25)
        frame = try await step(world, [XCTUnwrap(frame.objects[polygonID])], dt: 0.25)
        XCTAssertEqual(try XCTUnwrap(frame.objects[polygonID]).position.x, 1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(frame.objects[polygonID]).velocity.x, 2, accuracy: 0.0001)
    }

    // P-B-27: dwie bryły mogą minąć się między końcami kroku bez overlapu końcowych AABB. CCD bryła–bryła ma je zatrzymać
    // bez błędu klatki: dawniej `guardFailure` uchodził za sukces, teraz krok musi się udać i bryły muszą zostać po swoich stronach.
    func testFastDynamicPolygonsCannotSwapPositionsWithoutContact() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let left = try polygon(position: [-3,0], velocity: [360,0])
        let right = NativePublicObject(descriptor: .rigidBody(try RigidBodyDescriptor(id: .init(rawValue: 3),
            vertices: [[-1,-1],[1,-1],[1,1],[-1,1]], position: [3,0], velocity: [-360,0],
            mass: 2, momentOfInertia: 2, motionRole: .dynamic,
            physicsMaterialID: .init(rawValue: 2), renderMaterialID: .init(rawValue: 1))))
        let frame = try await step(world, [left, right])
        let a = try XCTUnwrap(frame.objects[polygonID]), b = try XCTUnwrap(frame.objects[.init(rawValue: 3)])
        XCTAssertLessThan(a.position.x, b.position.x)
        XCTAssertGreaterThanOrEqual(b.position.x - a.position.x, 2 - 0.05, "bryły (po 2 szerokości) nie mogą się przenikać")
    }

    // P-B-7: prepare nie może porównywać prefiksów list przy każdym ciele (O(k²)).
    private func input(_ index: Int, x: Float = 0) throws -> NativeRigidPolygonInput {
        let id = ObjectID(rawValue: UInt64(1000 + index))
        let object = NativePublicObject(descriptor: .rigidBody(try RigidBodyDescriptor(id: id,
            vertices: [[0,0],[1,0],[1,1],[0,1]], position: [Float(index) * 3 + x, 0],
            mass: 2, momentOfInertia: 2, motionRole: .static,
            physicsMaterialID: .init(rawValue: 2), renderMaterialID: .init(rawValue: 1))))
        return NativeRigidPolygonInput(object: object, damping: 0, friction: 0.5, restitution: 0.1)
    }

    private func settled(_ state: NativeRigidPolygonState, _ inputs: [NativeRigidPolygonInput]) throws {
        try state.prepare(inputs, bubbleCount: 0, timeStep: 1 / 60)
        var objects: [ObjectID: NativePublicObject] = [:]
        for value in inputs { objects[value.object.descriptor.id] = value.object }
        state.publish(objects)
    }

    func testPrepareUploadsOnlyChangedBodiesAndReusesUnchangedOnes() throws {
        let state = NativeRigidPolygonState(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var inputs = try (0..<6).map { try input($0) }
        try settled(state, inputs)
        try state.prepare(inputs, bubbleCount: 0, timeStep: 1 / 60)
        XCTAssertEqual(state.bodyUploadCount, 0)
        XCTAssertEqual(state.geometryUploadCount, 0)
        try settled(state, inputs)
        inputs[4] = try input(4, x: 0.5)
        try state.prepare(inputs, bubbleCount: 0, timeStep: 1 / 60)
        XCTAssertEqual(state.bodyUploadCount, 1)
        XCTAssertEqual(state.geometryUploadCount, 0)
        try settled(state, inputs)
        // Zmiana kolejności zmienia offsety geometrii, więc wszystkie rekordy są ponownie wysyłane.
        try state.prepare(Array(inputs.reversed()), bubbleCount: 0, timeStep: 1 / 60)
        XCTAssertEqual(state.bodyUploadCount, 6)
        XCTAssertEqual(state.geometryUploadCount, 6)
    }

    func testPrepareCostGrowsLinearlyWithBodyCount() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        func steadyStateSeconds(_ count: Int) throws -> Double {
            let state = NativeRigidPolygonState(device: device)
            let inputs = try (0..<count).map { try input($0) }
            try settled(state, inputs)
            var best = Double.infinity
            for _ in 0..<5 {
                let start = DispatchTime.now().uptimeNanoseconds
                try state.prepare(inputs, bubbleCount: 0, timeStep: 1 / 60)
                best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
                try settled(state, inputs)
            }
            return best
        }
        let small = try steadyStateSeconds(500), large = try steadyStateSeconds(2000)
        // Czterokrotnie więcej ciał: liniowo około 4×, kwadratowo około 16×.
        XCTAssertLessThan(large / small, 8, "small=\(small)s large=\(large)s")
    }

    /// P-B-40: `candidateLimit` skraca wiersze brył (długość wiersza w `control.z` i `bubbleControl.z`), a pojemność buforów zostaje na 128 na bryłę.
    func testCandidateLimitShortensTheRowsButKeepsTheBufferCapacity() throws {
        let inputs = try (0..<4).map { try input($0) }
        func rows(_ limit: Int?) throws -> (control: SIMD4<UInt32>, bubbleControl: SIMD4<UInt32>, capacity: Int) {
            let state = NativeRigidPolygonState(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
            if let limit {
                try state.prepare(inputs, bubbleCount: 2, timeStep: 1 / 60, candidateLimit: limit)
            } else {
                try state.prepare(inputs, bubbleCount: 2, timeStep: 1 / 60)
            }
            return (state.control.contents().load(as: SIMD4<UInt32>.self), state.bubbleControl.contents().load(as: SIMD4<UInt32>.self),
                    state.rowCapacity)
        }
        let full = try rows(nil)
        XCTAssertEqual(full.control.z, UInt32(NativeMetalSolver.candidateLimitPerObject), "domyślny limit to pojemność 128")
        XCTAssertEqual(full.capacity, 4 * NativeMetalSolver.candidateLimitPerObject)
        let short = try rows(3)
        XCTAssertEqual(short.control.z, 3)
        XCTAssertEqual(short.bubbleControl.z, 3)
        XCTAssertEqual(short.capacity, full.capacity, "pojemność buforów zostaje na 128 na bryłę")
    }
}
