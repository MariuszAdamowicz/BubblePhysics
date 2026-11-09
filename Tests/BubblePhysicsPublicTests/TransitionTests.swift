import BubblePhysics
@testable import BubblePhysicsRuntime
import XCTest

final class TransitionTests: XCTestCase {
    let style = RenderMaterialID(rawValue: 1), material = PhysicsMaterialID(rawValue: 1)
    let object = ObjectID(rawValue: 1)
    func initial() throws -> RuntimeState {
        try TransactionStager.stage(WorldTransaction()
            .updatePhysicsMaterial(material, material: PhysicsMaterial(kind: .bubble))
            .updateRenderMaterial(style, material: RenderMaterial())
            .add(.bubble(BubbleDescriptor(id: object, position: .zero, targetRadius: 1,
                physicsMaterialID: material, renderMaterialID: style))), against: RuntimeState(configuration:
                    WorldConfiguration(simulationRegion: WorldRectangle(min: [-20,-20], max: [20,20])))).state
    }
    func testNewTransitionForSameParameterReplacesPriorTransitionDeterministically() throws {
        let friction = TransitionTarget.physicsMaterial(material, .friction)
        var state = try initial()
        state.physicsMaterials[material] = try PhysicsMaterial(kind: .bubble, friction: 2)
        state = try TransactionStager.stage(WorldTransaction().startTransition(.init(target: friction,
            value: .scalar(10), duration: 2)), against: state).state
        try MotionControllers.prepare(&state, duration: 0.5)
        XCTAssertEqual(state.physicsMaterials[material]?.friction, 4)
        state = try TransactionStager.stage(WorldTransaction().startTransition(.init(target: friction,
            value: .scalar(0), duration: 1)), against: state).state
        try MotionControllers.prepare(&state, duration: 0.5)
        XCTAssertEqual(state.physicsMaterials[material]?.friction, 2)
        try MotionControllers.prepare(&state, duration: 0.5)
        XCTAssertEqual(state.physicsMaterials[material]?.friction, 0)
        XCTAssertTrue(state.transitions.isEmpty)
    }
    func testSerializableCurvesReachEndpointsAndSimulationTimeIsPartitionIndependent() throws {
        for curve in [TransitionCurve.linear, .easeIn, .easeOut, .easeInOut, .cubicBezier(x1: 0.2,y1: 0,x2: 0.8,y2: 1)] {
            XCTAssertEqual(try JSONDecoder().decode(TransitionCurve.self, from: JSONEncoder().encode(curve)), curve)
            let tx = WorldTransaction().startTransition(.init(target: .globalForce, value: .vector([8,4]), duration: 1, curve: curve))
            var a = try TransactionStager.stage(tx, against: initial()).state, b = a
            try MotionControllers.prepare(&a, duration: 0.5)
            for _ in 0..<4 { try MotionControllers.prepare(&b, duration: 0.125) }
            XCTAssertEqual(a.globalForce, b.globalForce)
            try MotionControllers.prepare(&a, duration: 0.5)
            XCTAssertEqual(a.globalForce, [8,4])
        }
    }

    // P-B-28: przejście parametru materiału nie może zgubić limitów prędkości (materiał jest budowany od nowa).
    func testMaterialTransitionKeepsSpeedLimits() throws {
        var state = try initial()
        state.physicsMaterials[material] = try PhysicsMaterial(kind: .bubble, maximumLinearSpeed: 30, maximumAngularSpeed: 4)
        state = try TransactionStager.stage(WorldTransaction()
            .startTransition(.init(target: .physicsMaterial(material, .friction), value: .scalar(0.8), duration: 1)),
            against: state).state
        try MotionControllers.prepare(&state, duration: 0.5)
        XCTAssertEqual(state.physicsMaterials[material]?.friction, 0.4)
        XCTAssertEqual(state.physicsMaterials[material]?.maximumLinearSpeed, 30)
        XCTAssertEqual(state.physicsMaterials[material]?.maximumAngularSpeed, 4)
    }

    func testMaterialContactTransitionsUpdateFrictionAndRestitutionTogether() throws {
        var state = try TransactionStager.stage(WorldTransaction()
            .startTransition(.init(target: .physicsMaterial(material, .friction), value: .scalar(0.8), duration: 1))
            .startTransition(.init(target: .physicsMaterial(material, .restitution), value: .scalar(0.6), duration: 1)),
            against: initial()).state
        try MotionControllers.prepare(&state, duration: 0.5)
        XCTAssertEqual(state.physicsMaterials[material]?.friction, 0.4)
        XCTAssertEqual(state.physicsMaterials[material]?.restitution, 0.3)
        try MotionControllers.prepare(&state, duration: 0.5)
        XCTAssertEqual(state.physicsMaterials[material]?.friction, 0.8)
        XCTAssertEqual(state.physicsMaterials[material]?.restitution, 0.6)
    }
}

@MainActor
final class MaterialContactTransitionTests: XCTestCase {
    private let material = PhysicsMaterialID(rawValue: 1)
    private let style = RenderMaterialID(rawValue: 1)

    func testMaterialFrictionRestitutionAndTransitionAreAcceptedByNativeWorld() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try BubbleWorld(configuration: WorldConfiguration(simulationRegion:
            WorldRectangle(min: [-10, -10], max: [10, 10]), fixedTimeStep: 1.0 / 60.0), device: device)
        let bubble = try BubbleDescriptor(id: .init(rawValue: 1), position: .zero, velocity: [2, 0],
            targetRadius: 1, physicsMaterialID: material, renderMaterialID: style)
        let token = world.submit(WorldTransaction()
            .updatePhysicsMaterial(material, material: try PhysicsMaterial(kind: .bubble, friction: 0.6, restitution: 0.4))
            .updateRenderMaterial(style, material: try RenderMaterial())
            .add(.bubble(bubble))
            .startTransition(ParameterTransition(target: .physicsMaterial(material, .restitution), value: .scalar(0.8), duration: 1)))

        let frame = await world.advance(by: 1.0 / 60.0)
        XCTAssertEqual(frame.transactionReceipts.map(\.token), [token])
        XCTAssertFalse(frame.events.contains { if case .transactionRejected = $0 { return true }; return false })
    }
}
