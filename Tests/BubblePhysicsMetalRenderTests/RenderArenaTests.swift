import BubblePhysics
import BubblePhysicsMetalRender
import Metal
import XCTest

/// P-B-89: pula buforów areny renderera. Bufor wraca do puli w `addCompletedHandler` swojego bufora poleceń (wątek Metala),
/// kolejne klatki biorą ten sam bufor, a dwa `encode` przed ukończeniem bufora poleceń dostają różne bufory. Bufor
/// poleceń bez commit nigdy nie oddaje bufora, więc nie może blokować kolejnych klatek, a pula trzyma najwyżej 3 bufory.
@MainActor
final class RenderArenaTests: XCTestCase {
    private typealias B = SceneBuilders
    private let red = RGBA(1, 0, 0, 1)

    private func makeScene() async throws -> RenderTestScene {
        let scene = try RenderTestScene(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let material = RenderMaterialID(rawValue: 10)
        try scene.submitMaterials([(material, RenderMaterial(color: red))])
        scene.world.submit(try WorldTransaction()
            .add(B.bubble(1, at: .zero, radius: 8, filter: RenderTestScene.ghost, role: .static, render: material))
            .add(B.box(2, at: [12, 0], half: [2, 2], filter: RenderTestScene.ghost, render: material)))
        await scene.step()
        return scene
    }

    /// Koduje klatkę do podanego bufora poleceń (bez commit).
    private func encode(_ scene: RenderTestScene, into command: MTLCommandBuffer) throws {
        try scene.renderer.encode(world: scene.world, viewport: RenderTestScene.viewport, commandBuffer: command,
                                  renderPassDescriptor: scene.harness.makePass())
    }

    private func finish(_ commands: [MTLCommandBuffer]) async {
        for command in commands { command.commit() }
        for command in commands {
            await command.completed()
            XCTAssertEqual(command.status, .completed)
        }
    }

    /// Uchwyt oddany w wątku Metala trafia do puli zaraz po ukończeniu bufora poleceń; czekanie jest tylko zabezpieczeniem
    /// przed kolejnością wywołań uchwytów.
    private func assertPool(_ scene: RenderTestScene, _ expected: Int, _ message: String,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 where scene.renderer.arenaPoolCount != expected { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(scene.renderer.arenaPoolCount, expected, message, file: file, line: line)
    }

    func testConsecutiveFramesTakeTheSameArenaBufferFromThePool() async throws {
        let scene = try await makeScene()
        XCTAssertEqual(scene.renderer.arenaAllocationCount, 0, "bufor powstaje przy pierwszym kodowaniu")
        try await scene.render()
        XCTAssertEqual(scene.renderer.arenaAllocationCount, 1)
        try await assertPool(scene, 1, "bufor wrócił do puli po ukończeniu bufora poleceń")
        for frame in 2...5 {
            try await scene.render()
            XCTAssertEqual(scene.renderer.arenaAllocationCount, 1, "klatka \(frame) bierze bufor z puli bez nowego przydziału")
            try await assertPool(scene, 1, "klatka \(frame) oddała bufor")
        }
        scene.assertPixel([0, 0], red, "obraz z buforu z puli jest poprawny")
    }

    /// Prawdziwa ścieżka klatki: `advance(by:commandBuffer:encodeRender:)` koduje fizykę i render do jednego bufora poleceń,
    /// zatwierdza go i czeka na ukończenie; test niczego nie czeka ręcznie. Przydział areny nie rośnie z liczbą klatek.
    func testArenaAllocationsStayBoundedOverFramesDrivenByAdvance() async throws {
        let scene = try await makeScene()
        let queue = try XCTUnwrap(scene.device.makeCommandQueue())
        let frames = 30
        for frame in 1...frames {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let pass = scene.harness.makePass()
            _ = await scene.world.advance(by: SceneBuilders.step, commandBuffer: command) {
                try scene.renderer.encode(world: scene.world, viewport: RenderTestScene.viewport, commandBuffer: command,
                                          renderPassDescriptor: pass)
            }
            XCTAssertEqual(command.status, .completed, "klatka \(frame)")
            XCTAssertNil(scene.world.diagnostics.lastAdvanceIssue, "klatka \(frame)")
            XCTAssertLessThanOrEqual(scene.renderer.arenaAllocationCount, 2,
                "klatka \(frame): bufor wraca do puli, więc przydział nie rośnie z liczbą klatek")
        }
        XCTAssertGreaterThanOrEqual(scene.renderer.arenaAllocationCount, 1)
        XCTAssertLessThanOrEqual(scene.renderer.arenaPoolCount, 3)
        scene.assertPixel([0, 0], red, "obraz z klatek `advance` jest poprawny")
    }

    func testTwoEncodesInOneCommandBufferGetDifferentBuffers() async throws {
        let scene = try await makeScene()
        let command = try scene.harness.makeCommandBuffer()
        try encode(scene, into: command)
        try encode(scene, into: command)
        XCTAssertEqual(scene.renderer.arenaAllocationCount, 2, "drugi encode przed ukończeniem nie może użyć bufora pierwszego")
        XCTAssertEqual(scene.renderer.arenaPoolCount, 0, "oba bufory są w użyciu do ukończenia bufora poleceń")
        await finish([command])
        try await assertPool(scene, 2, "oba bufory wracają po ukończeniu bufora poleceń")
        // Następna para korzysta z puli.
        let next = try scene.harness.makeCommandBuffer()
        try encode(scene, into: next)
        try encode(scene, into: next)
        XCTAssertEqual(scene.renderer.arenaAllocationCount, 2, "para z puli, bez nowych przydziałów")
        await finish([next])
        try await assertPool(scene, 2, "bufory wróciły ponownie")
    }

    func testTwoFramesInFlightAtOnceGetDifferentBuffersAndBothReturn() async throws {
        let scene = try await makeScene()
        let first = try scene.harness.makeCommandBuffer(), second = try scene.harness.makeCommandBuffer()
        try encode(scene, into: first)
        try encode(scene, into: second)
        XCTAssertEqual(scene.renderer.arenaAllocationCount, 2, "klatka w locie trzyma swój bufor")
        await finish([first, second])
        try await assertPool(scene, 2, "obie klatki oddały bufory")
    }

    func testCommandBufferWithoutCommitDoesNotBlockLaterFrames() async throws {
        let scene = try await makeScene()
        let abandoned = try scene.harness.makeCommandBuffer()
        try encode(scene, into: abandoned)  // nigdy nie commitowany: jego bufor nie wróci do puli
        XCTAssertEqual(scene.renderer.arenaAllocationCount, 1)
        XCTAssertEqual(scene.renderer.arenaPoolCount, 0)
        for frame in 1...4 {
            try await scene.render()
            try await assertPool(scene, 1, "klatka \(frame) po porzuconym buforze poleceń oddała swój bufor")
        }
        XCTAssertEqual(scene.renderer.arenaAllocationCount, 2, "jeden bufor porzucony i jeden w obiegu między klatkami")
        scene.assertPixel([0, 0], red, "kolejne klatki rysują się poprawnie")
    }

    func testPoolKeepsAtMostThreeBuffersAndAllocatesNewOnesWhenNoneIsFree() async throws {
        let scene = try await makeScene()
        let commands = try (0..<5).map { _ in try scene.harness.makeCommandBuffer() }
        for command in commands { try encode(scene, into: command) }
        XCTAssertEqual(scene.renderer.arenaAllocationCount, 5, "pięć klatek w locie, pięć buforów")
        await finish(commands)
        try await assertPool(scene, 3, "pula zatrzymuje najwyżej 3 bufory, pozostałe są zwalniane")
        XCTAssertLessThanOrEqual(scene.renderer.arenaPoolCount, 3)
        // Pięć kolejnych klatek w locie: trzy z puli, dwa nowe.
        let again = try (0..<5).map { _ in try scene.harness.makeCommandBuffer() }
        for command in again { try encode(scene, into: command) }
        XCTAssertEqual(scene.renderer.arenaAllocationCount, 7, "trzy bufory z puli, dwa nowe przydziały")
        await finish(again)
        try await assertPool(scene, 3, "pula nadal ≤ 3")
    }

    /// Klatka większa niż bufor w puli dostaje nowy, większy bufor, a za mały wolny bufor jest zwalniany.
    func testLargerFrameAllocatesALargerBufferAndDropsTheTooSmallOneFromThePool() async throws {
        let scene = try await makeScene()
        try await scene.render()
        try await assertPool(scene, 1, "mała klatka oddała bufor")
        var transaction = WorldTransaction()
        for index in 0..<400 {
            transaction = try transaction.add(B.box(UInt64(100 + index), at: [Float(index % 20) - 10, Float(index / 20) - 10],
                half: [0.2, 0.2], filter: RenderTestScene.ghost, render: RenderMaterialID(rawValue: 10)))
        }
        scene.world.submit(transaction)
        await scene.step()
        try await scene.render()
        XCTAssertEqual(scene.renderer.arenaAllocationCount, 2, "duża klatka nie mieści się w małym buforze z puli")
        try await assertPool(scene, 1, "mały bufor zwolniony, duży wrócił do puli")
        try await scene.render()
        XCTAssertEqual(scene.renderer.arenaAllocationCount, 2, "kolejna duża klatka bierze duży bufor z puli")
        try await assertPool(scene, 1, "pula nadal ma jeden bufor")
    }

    func testFrameWithoutObjectsAllocatesNoArena() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let scene = try RenderTestScene(device: device)
        try await scene.render()
        XCTAssertEqual(scene.renderer.arenaAllocationCount, 0, "klatka bez ciągów rysowania nie potrzebuje areny")
        XCTAssertEqual(scene.renderer.arenaPoolCount, 0)
    }
}
