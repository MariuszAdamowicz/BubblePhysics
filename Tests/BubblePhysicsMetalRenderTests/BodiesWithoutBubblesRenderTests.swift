import BubblePhysics
import Metal
import XCTest

/// Regresja po zmianie, która rysuje bryły tylko z rekordu GPU (bez rezerwy z CPU): świat bez żadnej bańki, z samymi
/// bryłami statycznymi albo samymi kinematycznymi, rysuje te bryły i ich naklejki po kroku, w klatce pośredniej, w klatce
/// z krokiem i w klatce bez opublikowanego kroku.
@MainActor
final class BodiesWithoutBubblesRenderTests: XCTestCase {
    private typealias B = SceneBuilders
    private let ghost = RenderTestScene.ghost
    private let redID = RenderMaterialID(rawValue: 10)
    private let tolerance: Float = 0.25
    private let isRed: ([UInt8]) -> Bool = { $0[0] > 128 && $0[1] < 100 && $0[2] < 100 }
    private let isGreen: ([UInt8]) -> Bool = { $0[1] > 128 && $0[0] < 100 && $0[2] < 100 }

    private func makeScene(role: MotionRole, withDecal: Bool = true) throws -> RenderTestScene {
        let scene = try RenderTestScene(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        try scene.submitMaterials([(redID, RenderMaterial(color: RGBA(1, 0, 0)))])
        let decal: Decal? = withDecal
            ? try .image(scene.assets.register(OffscreenRenderHarness.image(width: 1, height: 1, pixels: [[0, 255, 0, 255]])),
                         scale: 0.5)
            : nil
        scene.world.submit(try WorldTransaction()
            .add(B.box(1, at: [-10, 0], half: [2, 2], role: role, filter: ghost, render: redID, decal: decal)))
        return scene
    }

    /// Bryła i środek jej naklejki leżą w x = −10; po zmianie rysowania poza i kotwica nie zależą od baniek.
    private func assertBodyAndDecalAreDrawn(_ scene: RenderTestScene, _ context: String,
                                            file: StaticString = #filePath, line: UInt = #line) throws {
        let body = try XCTUnwrap(scene.renderedCenterX(where: isRed), "\(context): brak bryły", file: file, line: line)
        XCTAssertEqual(body, -10, accuracy: tolerance, context, file: file, line: line)
        let decal = try XCTUnwrap(scene.renderedCenterX(where: isGreen), "\(context): brak naklejki", file: file, line: line)
        XCTAssertEqual(decal, -10, accuracy: tolerance, context, file: file, line: line)
    }

    private func checkAfterAStep(_ role: MotionRole) async throws {
        let scene = try makeScene(role: role)
        await scene.step()
        try await scene.render()
        try assertBodyAndDecalAreDrawn(scene, "render po kroku")
    }

    private func checkInIntermediateFrame(_ role: MotionRole) async throws {
        let scene = try makeScene(role: role)
        await scene.step()
        let result = try await scene.advanceRendering(by: 1.0 / 120)
        XCTAssertEqual(result.frame.stepIndex, 1, "klatka pośrednia niczego nie publikuje")
        XCTAssertTrue(scene.world.diagnostics.didRenderLastAdvance)
        try assertBodyAndDecalAreDrawn(scene, "klatka pośrednia")
    }

    private func checkInStepFrame(_ role: MotionRole) async throws {
        let scene = try makeScene(role: role)
        let first = try await scene.advanceRendering(by: 1.0 / 60)
        XCTAssertEqual(first.frame.stepIndex, 1)
        try assertBodyAndDecalAreDrawn(scene, "pierwsza klatka z krokiem")
        await scene.step()
        let second = try await scene.advanceRendering(by: 1.5 / 60)
        XCTAssertEqual(second.frame.stepIndex, 3)
        try assertBodyAndDecalAreDrawn(scene, "klatka z krokiem i α = 0,5")
    }

    /// Przed pierwszym krokiem stan opublikowany jest pusty (transakcje wchodzą na granicy kroku), więc klatka bez kroku
    /// rysuje samo tło, nie zawodzi i niczego nie publikuje; następna klatka z krokiem rysuje bryłę.
    private func checkBeforeTheFirstStep(_ role: MotionRole) async throws {
        let scene = try makeScene(role: role)
        let empty = try await scene.advanceRendering(by: 1.0 / 120)
        XCTAssertEqual(empty.frame.stepIndex, 0)
        XCTAssertTrue(scene.world.diagnostics.didRenderLastAdvance)
        XCTAssertNil(scene.world.diagnostics.failureReason)
        XCTAssertNil(scene.renderedCenterX(where: isRed), "przed pierwszym krokiem nie ma czego rysować")
        let stepped = try await scene.advanceRendering(by: 1.0 / 120)
        XCTAssertEqual(stepped.frame.stepIndex, 1)
        try assertBodyAndDecalAreDrawn(scene, "pierwsza klatka z krokiem po klatce bez kroku")
    }

    func testStaticBodyWithoutBubblesIsDrawnWithItsDecalAfterAStep() async throws { try await checkAfterAStep(.static) }
    func testKinematicBodyWithoutBubblesIsDrawnWithItsDecalAfterAStep() async throws { try await checkAfterAStep(.kinematic) }
    func testStaticBodyWithoutBubblesIsDrawnInAnIntermediateFrame() async throws { try await checkInIntermediateFrame(.static) }
    func testKinematicBodyWithoutBubblesIsDrawnInAnIntermediateFrame() async throws { try await checkInIntermediateFrame(.kinematic) }
    func testStaticBodyWithoutBubblesIsDrawnInAStepFrame() async throws { try await checkInStepFrame(.static) }
    func testKinematicBodyWithoutBubblesIsDrawnInAStepFrame() async throws { try await checkInStepFrame(.kinematic) }
    func testStaticBodyWithoutBubblesFirstFrameWithoutAStepDrawsNothingAndNextStepDrawsIt() async throws {
        try await checkBeforeTheFirstStep(.static)
    }
    func testKinematicBodyWithoutBubblesFirstFrameWithoutAStepDrawsNothingAndNextStepDrawsIt() async throws {
        try await checkBeforeTheFirstStep(.kinematic)
    }
}
