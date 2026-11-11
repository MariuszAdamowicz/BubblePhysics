import BubblePhysics
import BubblePhysicsMetalRender
import Metal
import XCTest

/// Cache geometrii pierścieni brył (indeksy trójkątów i prostokąt otaczający): przy więcej niż 256 różnych kształtach
/// w jednej klatce nie może czyścić się co klatkę, bo wtedy każda bryła byłaby triangulowana od nowa w każdej klatce.
@MainActor
final class RingGeometryCacheTests: XCTestCase {
    private typealias B = SceneBuilders
    private let red = RGBA(1, 0, 0, 1)

    private func makeScene(shapeCount: Int) async throws -> RenderTestScene {
        let scene = try RenderTestScene(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let material = RenderMaterialID(rawValue: 10)
        try scene.submitMaterials([(material, RenderMaterial(color: red))])
        var transaction = WorldTransaction()
        for index in 0..<shapeCount {
            // Każda bryła ma inną szerokość, więc inny lokalny pierścień; siatka 20 × N co 4 jednostki mieści się w regionie.
            let center = WorldPoint(Float(index % 20) * 4 - 38, Float(index / 20) * 4 - 38)
            transaction = transaction.add(try B.box(UInt64(index + 1), at: center, half: [0.5 + Float(index) * 0.001, 0.5],
                                                    filter: RenderTestScene.ghost, render: material))
        }
        scene.world.submit(transaction)
        await scene.step()
        return scene
    }

    func testMoreThanTheCacheLimitOfDistinctShapesAreNotTriangulatedAgainOnTheNextFrame() async throws {
        let shapeCount = 300
        let scene = try await makeScene(shapeCount: shapeCount)
        XCTAssertEqual(scene.renderer.ringTriangulationCount, 0)
        try await scene.render()
        XCTAssertEqual(scene.renderer.ringTriangulationCount, shapeCount, "pierwsza klatka trianguluje każdy kształt raz")
        for frame in 2...4 {
            try await scene.render()
            XCTAssertEqual(scene.renderer.ringTriangulationCount, shapeCount,
                           "klatka \(frame): kształty z poprzedniej klatki zostają w cache, nic nie jest triangulowane od nowa")
        }
    }

    func testShapesGoneFromTheSceneAreEvictedOnceTheCacheIsOverTheLimit() async throws {
        let scene = try await makeScene(shapeCount: 300)
        try await scene.render()
        XCTAssertEqual(scene.renderer.ringTriangulationCount, 300)
        // Zostaje 10 brył; cache (300 > 256) pozbywa się kształtów nieużytych w poprzedniej klatce, ale nie tych 10.
        var removal = WorldTransaction()
        for index in 10..<300 { removal = removal.remove(ObjectID(rawValue: UInt64(index + 1))) }
        scene.world.submit(removal)
        await scene.step()
        try await scene.render()
        try await scene.render()
        XCTAssertEqual(scene.renderer.ringTriangulationCount, 300, "pozostałe kształty nie wymagają ponownej triangulacji")
        XCTAssertLessThanOrEqual(scene.renderer.ringGeometryCacheCount, 256, "cache nie rośnie ponad limit, gdy kształtów jest mniej")
    }
}
