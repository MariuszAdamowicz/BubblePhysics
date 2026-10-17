import BubblePhysics
@testable import BubblePhysicsRuntime
import XCTest

final class TransitionTests: XCTestCase {
    let style = RenderStyleID(rawValue: 1), material = PhysicsMaterialID(rawValue: 1)
    let object = ObjectID(rawValue: 1), channel = ParameterID(rawValue: "brightness")
    func initial() throws -> RuntimeState {
        try TransactionStager.stage(WorldTransaction()
            .updatePhysicsMaterial(material, material: PhysicsMaterial(kind: .bubble))
            .updateRenderStyle(style, style: RenderStyle(channels: [channel: 2]))
            .add(.bubble(BubbleDescriptor(id: object, position: .zero, targetRadius: 1,
                physicsMaterialID: material, renderStyleID: style))), against: RuntimeState(configuration:
                    WorldConfiguration(simulationRegion: WorldRectangle(min: [-20,-20], max: [20,20])))).state
    }
    func testNewTransitionForSameParameterReplacesPriorTransitionDeterministically() throws {
        var state = try TransactionStager.stage(WorldTransaction().startTransition(.init(target: .renderStyle(style, channel),
            value: .scalar(10), duration: 2)), against: initial()).state
        try MotionControllers.prepare(&state, duration: 0.5)
        XCTAssertEqual(state.renderStyles[style]?.presentation.channels[channel], 4)
        state = try TransactionStager.stage(WorldTransaction().startTransition(.init(target: .renderStyle(style, channel),
            value: .scalar(0), duration: 1)), against: state).state
        try MotionControllers.prepare(&state, duration: 0.5)
        XCTAssertEqual(state.renderStyles[style]?.presentation.channels[channel], 2)
        try MotionControllers.prepare(&state, duration: 0.5)
        XCTAssertEqual(state.renderStyles[style]?.presentation.channels[channel], 0)
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
}
