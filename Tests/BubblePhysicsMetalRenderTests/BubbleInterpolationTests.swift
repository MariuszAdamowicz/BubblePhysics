import BubblePhysics
import Metal
import XCTest

/// P-B-50, P-B-51 (bańki): kontur bańki w klatce pośredniej to mieszanie konturów t−1 i t z α. Bańka ma prędkość 60
/// jednostek na sekundę i nie koliduje z niczym, więc jej środek w krokach t−1 i t odczytujemy z `frame.objects`.
@MainActor
final class BubbleInterpolationTests: XCTestCase {
    private typealias B = SceneBuilders
    private let ghost = RenderTestScene.ghost
    private let redID = RenderMaterialID(rawValue: 10), blueID = RenderMaterialID(rawValue: 11)
    private let tolerance: Float = 0.25
    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }

    private func makeScene() async throws -> (scene: RenderTestScene, previous: Float, current: Float) {
        let scene = try RenderTestScene(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        try scene.submitMaterials([(redID, RenderMaterial(color: RGBA(1, 0, 0))), (blueID, RenderMaterial(color: RGBA(0, 0, 1)))])
        scene.world.submit(try WorldTransaction()
            .add(B.bubble(1, at: [-10, 0], radius: 5, velocity: [60, 0], filter: ghost, render: redID)))
        var previous: Float = 0, current: Float = 0
        for _ in 0..<3 {
            previous = current
            let stepped = await scene.step()
            current = try XCTUnwrap(stepped.objects[id(1)]).position.x
        }
        XCTAssertGreaterThan(current - previous, 0.5, "bańka jedzie")
        return (scene, previous, current)
    }

    // P-B-50
    func testIntermediateFrameDrawsTheBubbleContourBetweenTheTwoSteps() async throws {
        let (scene, previous, current) = try await makeScene()
        let result = try await scene.advanceRendering(by: 1.0 / 120)
        XCTAssertEqual(result.frame.stepIndex, 3)
        XCTAssertEqual(result.command.status, .completed)
        XCTAssertTrue(scene.world.diagnostics.didRenderLastAdvance)
        let center = try XCTUnwrap(scene.renderedCenterX())
        XCTAssertEqual(center, (previous + current) / 2, accuracy: tolerance, "α = 0,5")
    }

    // P-B-50
    func testStepFrameDrawsThePreviousStepWhenNothingIsOwed() async throws {
        let (scene, previous, current) = try await makeScene()
        try await scene.advanceRendering(by: 1.0 / 120)
        let result = try await scene.advanceRendering(by: 1.0 / 120)
        XCTAssertEqual(result.frame.stepIndex, 4)
        let center = try XCTUnwrap(scene.renderedCenterX())
        XCTAssertEqual(center, current, accuracy: tolerance, "α = 0: krok t−1, czyli poprzedni t (\(previous))")
    }

    // P-B-51
    func testBacklogOverAStepDrawsTheNewStepWithFractionOne() async throws {
        let (scene, _, current) = try await makeScene()
        let result = try await scene.advanceRendering(by: 2.5 / 60)
        let newest = try XCTUnwrap(result.frame.objects[id(1)]).position.x
        XCTAssertGreaterThan(newest, current)
        XCTAssertEqual(scene.world.diagnostics.stepsInLastAdvance, 1)
        let center = try XCTUnwrap(scene.renderedCenterX())
        XCTAssertEqual(center, newest, accuracy: tolerance, "α = 1: stan nowego kroku")
    }

    // Klatka pośrednia po odrzuconej klatce rysuje opublikowane t, a nie stan odrzuconego kroku.
    func testFrameAfterARejectedStepDrawsThePublishedStateNotTheRejectedOne() async throws {
        struct GameError: Error {}
        let (scene, _, current) = try await makeScene()
        let rejected = try await scene.advanceRendering(by: 1.0 / 60, fail: GameError())
        XCTAssertEqual(rejected.frame.stepIndex, 3)
        XCTAssertEqual(scene.world.diagnostics.lastAdvanceIssue, .frameRejected)
        try await scene.render()
        let center = try XCTUnwrap(scene.renderedCenterX())
        XCTAssertEqual(center, current, accuracy: tolerance, "opublikowane t, nie odrzucone t+1")
    }

    // Po dodaniu baniek ponad pojemność stan GPU jest przydzielany od nowa: istniejąca bańka ma zostać w miejscu.
    func testIntermediateFrameAfterGrowingCapacityKeepsExistingBubblesInPlace() async throws {
        let (scene, _, current) = try await makeScene()
        var transaction = WorldTransaction()
        for index in 0..<17 {
            transaction = transaction.add(try B.bubble(UInt64(10 + index), at: WorldPoint(Float(-45 + 5 * index), 40), radius: 2, filter: ghost,
                                                       role: .static, render: blueID))
        }
        scene.world.submit(transaction)
        let grown = await scene.step()
        let now = try XCTUnwrap(grown.objects[id(1)]).position.x
        XCTAssertGreaterThan(now, current)
        try await scene.advanceRendering(by: 1.0 / 120)
        let center = try XCTUnwrap(scene.renderedCenterX())
        XCTAssertEqual(center, (current + now) / 2, accuracy: tolerance, "kontury t−1 przeżyły ponowne przydzielenie")
    }
}
