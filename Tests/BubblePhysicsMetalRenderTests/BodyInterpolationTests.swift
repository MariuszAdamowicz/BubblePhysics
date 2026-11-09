import BubblePhysics
import Metal
import XCTest

/// P-B-50, P-B-51 (bryły): przy 120 Hz i kroku 1/60 każde `advance` z buforem poleceń rysuje, a bryła w klatce pośredniej
/// leży między pozami kroków t−1 i t. Kinematyczna skrzynka jedzie 1 jednostkę na krok (60 jednostek na sekundę), więc
/// pozycje kroków są dokładne, a α = 0, 0,5 i 1 daje środek odpowiednio w t−1, w połowie i w t.
@MainActor
final class BodyInterpolationTests: XCTestCase {
    private typealias B = SceneBuilders
    private let ghost = RenderTestScene.ghost
    private let redID = RenderMaterialID(rawValue: 10)
    private let tolerance: Float = 0.2

    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }

    /// Skrzynka jedzie w prawo; po trzech krokach stoi w x = −7, a poprzedni krok to −8.
    private func makeScene() async throws -> (scene: RenderTestScene, current: Float, previous: Float) {
        let scene = try RenderTestScene(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        try scene.submitMaterials([(redID, RenderMaterial(color: RGBA(1, 0, 0)))])
        scene.world.submit(try WorldTransaction()
            .add(B.box(1, at: [-10, 0], half: [1, 1], role: .kinematic, filter: ghost, render: redID))
            .setKinematicDrive(id(1), drive: .velocity(linear: [60, 0], angular: 0)))
        var previous: Float = 0, current: Float = 0
        for _ in 0..<3 {
            previous = current
            let stepped = await scene.step()
            current = try XCTUnwrap(stepped.objects[id(1)]).position.x
        }
        XCTAssertEqual(current, -7, accuracy: 1e-3)
        XCTAssertEqual(current - previous, 1, accuracy: 1e-3)
        return (scene, current, previous)
    }

    // P-B-50
    func testIntermediateFrameDrawsTheBodyBetweenTheTwoSteps() async throws {
        let (scene, current, previous) = try await makeScene()
        let result = try await scene.advanceRendering(by: 1.0 / 120)
        XCTAssertEqual(result.frame.stepIndex, 3, "klatka pośrednia nic nie publikuje")
        XCTAssertEqual(result.command.status, .completed, "bufor zatwierdzony mimo braku kroku")
        XCTAssertTrue(scene.world.diagnostics.didRenderLastAdvance)
        let center = try XCTUnwrap(scene.renderedCenterX())
        XCTAssertEqual(center, (previous + current) / 2, accuracy: tolerance, "α = 0,5: w połowie między krokami")
    }

    // P-B-50
    func testStepFrameDrawsTheRemainderFractionBetweenThePreviousAndTheNewStep() async throws {
        let (scene, current, _) = try await makeScene()
        try await scene.advanceRendering(by: 1.0 / 120)
        let result = try await scene.advanceRendering(by: 1.0 / 120)
        XCTAssertEqual(result.frame.stepIndex, 4)
        XCTAssertEqual(result.command.status, .completed)
        XCTAssertTrue(scene.world.diagnostics.didRenderLastAdvance)
        XCTAssertEqual(scene.world.diagnostics.backlogSeconds, 0, accuracy: 1e-9)
        let center = try XCTUnwrap(scene.renderedCenterX())
        XCTAssertEqual(center, current, accuracy: tolerance, "po kroku bez reszty α = 0: poprzedni krok")
    }

    // P-B-51
    func testBacklogOverAStepGivesFractionOneAndASingleStep() async throws {
        let (scene, current, _) = try await makeScene()
        let result = try await scene.advanceRendering(by: 2.5 / 60)
        XCTAssertEqual(result.frame.stepIndex, 4)
        XCTAssertEqual(scene.world.diagnostics.stepsInLastAdvance, 1)
        XCTAssertEqual(scene.world.diagnostics.backlogSeconds, 1.5 / 60, accuracy: 1e-9, "diagnostyka raportuje zaległość")
        let center = try XCTUnwrap(scene.renderedCenterX())
        XCTAssertEqual(center, current + 1, accuracy: tolerance, "α = 1: stan bieżącego kroku")
    }

    // Klatka pośrednia po odrzuconej klatce: renderer widzi opublikowane t, nie stan odrzuconego kroku.
    func testFrameAfterARejectedStepDrawsThePublishedStateNotTheRejectedOne() async throws {
        struct GameError: Error {}
        let (scene, current, _) = try await makeScene()
        let rejected = try await scene.advanceRendering(by: 1.0 / 60, fail: GameError())
        XCTAssertEqual(rejected.frame.stepIndex, 3)
        XCTAssertEqual(scene.world.diagnostics.lastAdvanceIssue, .frameRejected)
        XCTAssertFalse(scene.world.diagnostics.didRenderLastAdvance)
        try await scene.render()
        let center = try XCTUnwrap(scene.renderedCenterX())
        XCTAssertEqual(center, current, accuracy: tolerance, "opublikowane t, nie odrzucone t+1")
    }

    func testBodyDecalAnchorFollowsTheInterpolatedPose() async throws {
        let scene = try RenderTestScene(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let blueID = RenderMaterialID(rawValue: 11)
        try scene.submitMaterials([(redID, RenderMaterial(color: RGBA(1, 0, 0))), (blueID, RenderMaterial(color: RGBA(0, 0, 1)))])
        let image = try OffscreenRenderHarness.image(width: 1, height: 1, pixels: [[0, 255, 0, 255]])
        let texture = try scene.assets.register(image)
        scene.world.submit(try WorldTransaction()
            .add(B.box(1, at: [-10, 0], half: [2, 2], role: .kinematic, filter: ghost, render: redID,
                       decal: try .image(texture)))
            .setKinematicDrive(id(1), drive: .velocity(linear: [60, 0], angular: 0)))
        var previous: Float = 0, current: Float = 0
        for _ in 0..<3 {
            previous = current
            let stepped = await scene.step()
            current = try XCTUnwrap(stepped.objects[id(1)]).position.x
        }
        try await scene.advanceRendering(by: 1.0 / 120)
        let green: ([UInt8]) -> Bool = { $0[1] > 128 && $0[0] < 100 && $0[2] < 100 }
        let center = try XCTUnwrap(scene.renderedCenterX(where: green))
        XCTAssertEqual(center, (previous + current) / 2, accuracy: tolerance, "obraz naklejki jedzie z bryłą w klatce pośredniej")
    }

    // P-B-50: klatka z krokiem i α ∈ (0, 1): bryła leży między pozą sprzed kroku (t) a pozą nowego kroku (t+1).
    func testStepFrameWithAFractionBetweenZeroAndOneDrawsTheBodyBetweenTheStates() async throws {
        let (scene, current, _) = try await makeScene()
        let result = try await scene.advanceRendering(by: 1.5 / 60)
        XCTAssertEqual(result.frame.stepIndex, 4)
        XCTAssertEqual(scene.world.diagnostics.backlogSeconds, 0.5 / 60, accuracy: 1e-9, "α = 0,5 po kroku")
        let newest = try XCTUnwrap(result.frame.objects[id(1)]).position.x
        XCTAssertEqual(newest - current, 1, accuracy: 1e-3)
        let center = try XCTUnwrap(scene.renderedCenterX())
        XCTAssertEqual(center, (current + newest) / 2, accuracy: tolerance, "α = 0,5: w połowie między t i t+1")
    }

    /// Koło leci na ścianę (jej lewa krawędź w x = 0) z prędkością 1 jednostka na krok: po trzech krokach stoi w −1,5, a
    /// następny krok przeniósłby je do −0,5, czyli w ścianę (koło o promieniu 1 może stać najdalej w −1). Ściana ma mniejsze ID,
    /// więc koło rysuje się na niej i jego środek da się zmierzyć w całości.
    private func makeCollisionScene() async throws -> (scene: RenderTestScene, before: Float) {
        let scene = try RenderTestScene(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let blueID = RenderMaterialID(rawValue: 11)
        try scene.submitMaterials([(redID, RenderMaterial(color: RGBA(1, 0, 0))), (blueID, RenderMaterial(color: RGBA(0, 0, 1)))])
        scene.world.submit(try WorldTransaction()
            .add(B.box(1, at: [1, 0], half: [1, 10], role: .static, render: blueID))
            .add(B.circle(2, at: [-4.5, 0], radius: 1, velocity: [60, 0], render: redID)))
        var before: Float = -4.5
        for _ in 0..<3 {
            let stepped = await scene.step()
            before = try XCTUnwrap(stepped.objects[id(2)]).position.x
        }
        XCTAssertEqual(before, -1.5, accuracy: 0.05, "trzy kroki po 1 jednostce, jeszcze bez kontaktu")
        return (scene, before)
    }

    // P-B-51, udokumentowane ograniczenie (A2): w klatce z krokiem bryła jest ekstrapolowana z pozy sprzed kroku (poza po
    // kroku GPU nie jest znana w chwili kodowania), więc przy α = 1 koło uderzające w ścianę rysuje się o pełne v·dt dalej, niż
    // ustawił je solver (w ścianie), zamiast przy ścianie. Bańki mieszają prawdziwe kontury t i t+1 i tego nie robią.
    func testDynamicBodyHittingAWallAtFractionOneIsDrawnExtrapolatedPastTheWall() async throws {
        let (scene, before) = try await makeCollisionScene()
        let result = try await scene.advanceRendering(by: 2.5 / 60)
        XCTAssertEqual(scene.world.diagnostics.stepsInLastAdvance, 1)
        let newest = try XCTUnwrap(result.frame.objects[id(2)]).position.x
        XCTAssertLessThanOrEqual(newest, -0.95, "solver zatrzymał koło przy ścianie (powierzchnia w x = 0, promień 1)")
        XCTAssertLessThan(newest, before + 1 - 0.3, "po kroku koło jest wyraźnie przed miejscem ekstrapolacji")
        let center = try XCTUnwrap(scene.renderedCenterX())
        XCTAssertEqual(center, before + 1, accuracy: tolerance, "rysunek: poza sprzed kroku plus v·dt (w ścianie)")
    }

    // P-B-50, to samo przy α = 0,5: ekstrapolacja o pół kroku, nie prawdziwe mieszanie t i t+1.
    func testDynamicBodyHittingAWallInAStepFrameWithHalfFractionIsExtrapolatedByHalfAStep() async throws {
        let (scene, before) = try await makeCollisionScene()
        let result = try await scene.advanceRendering(by: 1.5 / 60)
        XCTAssertEqual(scene.world.diagnostics.backlogSeconds, 0.5 / 60, accuracy: 1e-9)
        let newest = try XCTUnwrap(result.frame.objects[id(2)]).position.x
        let center = try XCTUnwrap(scene.renderedCenterX())
        XCTAssertEqual(center, before + 0.5, accuracy: tolerance, "poza sprzed kroku plus α·v·dt")
        XCTAssertGreaterThan(abs(center - (before + newest) / 2), 0.1, "to nie jest mieszanie t i t+1")
    }
}
