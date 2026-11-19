import BubblePhysics
import XCTest

/// P-B-11 (G2-AC1, CD-D-16): kontakt bańki ze ścianą nie zależy od historii. Świat A dociska bańkę stałą siłą globalną przez
/// kilka sekund, aż do spoczynku w położeniu P. Świat B dostaje nową bańkę od razu w P z tą samą prędkością, bez historii
/// konturu i cache kontaktów. Po jednym kroku oba mają to samo położenie i ten sam kontur.
///
/// Materiał z kc = 3: przy kc = 0 podatność nie zależy od ρ i test przeszedłby także z ρ wygładzanym z poprzednich klatek.
/// Tu c = c₀ · ρ³, więc ρ z historii (świat A) i ρ = 1 nowego rekordu (świat B) dałyby różne ugięcia.
@MainActor
final class ContactRhoHistoryTests: XCTestCase {
    private let radius: Float = 20
    private let force: Float = 100
    /// c₀ · F = 20 = r: ε = (1 − ε)³ daje ściśnięcie ok. 0,32 promienia, a ρ w równowadze ok. 0,68.
    private let base: Float = 0.2

    private func world(position: WorldPoint, velocity: WorldPoint) async throws -> BubbleWorld {
        let world = try BubbleWorld(configuration: CrowdScene.configuration())
        var setup = try CrowdScene.resources(bubble: CrowdScene.softBubblePhysics(base: base, compressionExponent: 3))
        for wall in try CrowdScene.walls() { setup = setup.add(wall) }
        setup = try setup.add(CrowdScene.bubble(1, at: position, radius: radius, velocity: velocity, mass: 1))
            .setGlobalForce([-force, 0])
        _ = world.submit(setup)
        return world
    }

    /// Świat A po spoczynku i świat B z nową bańką w tym samym miejscu, oba po jednym kroku.
    private func oneStepAfterRest() async throws -> (history: BubbleWorld, fresh: BubbleWorld, a: ObjectState, b: ObjectState) {
        let touching = WorldPoint(-(CrowdScene.interiorHalfSize.x - radius), 0)
        let history = try await world(position: touching, velocity: .zero)
        var rest: ObjectState?
        for index in 0..<900 {
            let frame = await history.advance(by: CrowdScene.step)
            XCTAssertNil(history.diagnostics.lastAdvanceIssue, "krok \(index)")
            rest = frame.objects[CrowdScene.id(1)]
        }
        let settled = try XCTUnwrap(rest)
        let depth = CrowdScene.wallDepth(of: settled, targetRadius: radius)
        XCTAssertGreaterThan(depth, 0.15 * radius, "bańka ma być wyraźnie ściśnięta, żeby ρ miało znaczenie")
        XCTAssertLessThan(abs(settled.velocity.x), 0.05, "świat A jest w spoczynku")

        let fresh = try await world(position: settled.position, velocity: settled.velocity)
        let historyFrame = await history.advance(by: CrowdScene.step)
        let freshFrame = await fresh.advance(by: CrowdScene.step)
        XCTAssertNil(history.diagnostics.lastAdvanceIssue)
        XCTAssertNil(fresh.diagnostics.lastAdvanceIssue)
        return (history, fresh, try XCTUnwrap(historyFrame.objects[CrowdScene.id(1)]),
                try XCTUnwrap(freshFrame.objects[CrowdScene.id(1)]))
    }

    // G2-AC1: ρ z historii (świat A) i ρ nowego rekordu (świat B) nie dają różnicy położenia po jednym kroku.
    func testWallContactPositionAfterOneStepIsTheSameWithAndWithoutHistory() async throws {
        let (_, _, a, b) = try await oneStepAfterRest()
        XCTAssertEqual(a.position.x, b.position.x, accuracy: 1e-3, "położenie po jednym kroku")
        XCTAssertEqual(a.position.y, b.position.y, accuracy: 1e-3)
        XCTAssertEqual(CrowdScene.effectiveRadius(of: a), CrowdScene.effectiveRadius(of: b), accuracy: 1e-3)
    }

    // G2-AC1: kontur po jednym kroku też. Dopóki `nativeAccumulateContactPressure` bierze max(wgniecenie, recovered) z konturu
    // poprzedniej klatki (G3, usuwane osobno), świat A ma szerszy kontur na bokach niż świat B.
    func testWallContactContourAfterOneStepIsTheSameWithAndWithoutHistory() async throws {
        let (history, fresh, _, _) = try await oneStepAfterRest()
        let contourA = try XCTUnwrap(history.debugContourSnapshot()[CrowdScene.id(1)])
        let contourB = try XCTUnwrap(fresh.debugContourSnapshot()[CrowdScene.id(1)])
        XCTAssertEqual(contourA.count, contourB.count)
        var worst: Float = 0
        for (pointA, pointB) in zip(contourA, contourB) {
            worst = max(worst, abs(pointA.x - pointB.x), abs(pointA.y - pointB.y))
        }
        XCTAssertLessThan(worst, 1e-3, "kontur po jednym kroku")
    }
}
