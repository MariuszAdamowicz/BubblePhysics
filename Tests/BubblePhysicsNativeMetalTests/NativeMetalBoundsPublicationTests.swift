import BubblePhysicsModel
import BubblePhysicsRuntime
import Metal
@testable import BubblePhysicsNativeMetal
import XCTest

/// Zła obwiednia konturu z kernelu (odwrócona albo nieskończona) nie odrzuca kroku, a bańka publikuje obwiednię koła
/// (`ObjectState.bounds` = pozycja ± `targetRadius`), a nie obwiednię z poprzedniej klatki (CHANGELOG, MIGRATION-v3).
@MainActor
final class NativeMetalBoundsPublicationTests: XCTestCase {
    private let material = PhysicsMaterialID(rawValue: 1), style = RenderMaterialID(rawValue: 1)
    private let id = ObjectID(rawValue: 1)

    /// Psuje bufor roboczy po zakończeniu klatki, tuż przed odczytem rekordów na CPU.
    private final class CorruptingExecutor: NativeMetalCommandExecuting {
        var corrupt: (() -> Void)?
        func complete(_ command: MTLCommandBuffer) async throws -> NativeMetalCommandTiming {
            let timing = try await NativeMetalCommandExecutor().complete(command)
            corrupt?()
            corrupt = nil
            return timing
        }
    }

    private func initialState() throws -> RuntimeState {
        let tx = try WorldTransaction().updatePhysicsMaterial(material, material: PhysicsMaterial(kind: .bubble, contactStiffness: 1e9))
            .updateRenderMaterial(style, material: try RenderMaterial())
            .add(.bubble(try BubbleDescriptor(id: id, position: [3, 4], targetRadius: 2, mass: 1,
                physicsMaterialID: material, renderMaterialID: style)))
        return try TransactionStager.stage(tx, against: RuntimeState(configuration:
            WorldConfiguration(simulationRegion: WorldRectangle(min: [-100, -100], max: [100, 100])))).state
    }

    private func step(_ stepper: NativeCompleteStepper, _ state: RuntimeState) async throws -> RuntimeState {
        let batch = TransactionStager.stageBatch([], against: state, validate: stepper.validate)
        return try await stepper.completePublishedStep(batch, duration: 1.0 / 60).state
    }

    func testBadBoundsRecordPublishesTheBubbleCircleInsteadOfThePreviousBounds() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let executor = CorruptingExecutor()
        let world = try NativePublicWorld(device: device, commandExecutor: executor)
        let stepper = NativeCompleteStepper(world: world)
        var state = try await step(stepper, try initialState())
        // Po poprawnej klatce obiekt ma obwiednię z kernelu; ma ona zostać zastąpiona, nie zachowana.
        XCTAssertNotNil(state.objects[id]?.bounds, "poprawna klatka publikuje obwiednię z kernelu")
        let persistent = try XCTUnwrap(world.persistentState)
        executor.corrupt = {
            let bubbles = persistent.workingBubbles.contents().bindMemory(to: NativeMetalBubble.self, capacity: 1)
            bubbles[0].bounds = SIMD4(1, 1, -1, -1)
        }
        state = try await step(stepper, state)
        XCTAssertNil(state.objects[id]?.bounds, "zła obwiednia z kernelu to nil, nie poprzednia wartość")
        let published = try XCTUnwrap(state.publishedObjectStates()[id])
        let object = try XCTUnwrap(state.objects[id])
        let radius = object.targetRadius
        XCTAssertEqual(published.bounds.min, object.position - SIMD2(radius, radius))
        XCTAssertEqual(published.bounds.max, object.position + SIMD2(radius, radius))
    }
}
