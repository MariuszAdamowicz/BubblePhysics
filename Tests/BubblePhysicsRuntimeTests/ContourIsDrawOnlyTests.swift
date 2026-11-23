@testable import BubblePhysics
import XCTest

/// P-B-25 (G5-AC1): kontur jest tylko rysowany. Dwa światy z tą samą sceną różnią się wyłącznie `deformability` materiału baniek
/// (0 i 0,65), a jeden z nich czyta kontur (`debugContourSnapshot()`) w każdym kroku. Pozycje, prędkości, obroty i promienie fizyki
/// (`targetRadius`, `collisionRadius`) wszystkich baniek mają być identyczne bit w bit przez 600 kroków.
/// Obwiednia (`ObjectState.bounds`) pochodzi z konturu, więc w obu światach musi się różnić (inaczej test niczego by nie rozróżniał).
/// `effectiveRadius` nie służy do tego: kernel liczy go z geometrii kontaktów, bez udziału `deformability`.
@MainActor
final class ContourIsDrawOnlyTests: XCTestCase {
    private func material(deformability: Float) throws -> PhysicsMaterial {
        // Kontakty twarde: tylko one czytają `deformability` w kernelu konturu (kontakt miękki omija bramkę deformowalności).
        try PhysicsMaterial(kind: .bubble, contactStiffness: 1e9, damping: 0.5)
    }

    private func length(_ vector: WorldPoint) -> Float { (vector.x * vector.x + vector.y * vector.y).squareRoot() }

    /// Stałe bańki sceny (scalenie: 1 i 2, podział: 3, chwyt gumką: 4) i losowy tłok z ziarna; razem 24 bańki.
    private func layout() -> [(id: UInt64, position: WorldPoint, radius: Float)] {
        var placed: [(id: UInt64, position: WorldPoint, radius: Float)] = [
            (1, [-120, -260], 20), (2, [-80, -260], 20), (3, [-40, -200], 24), (4, [100, 200], 24)]
        var generator = CrowdScene.SeededGenerator(seed: 6_100)
        var attempts = 0
        while placed.count < 24, attempts < 20_000 {
            attempts += 1
            let radius = Float.random(in: 12...48, using: &generator)
            let limit = CrowdScene.interiorHalfSize - WorldPoint(repeating: radius + 1)
            let point = WorldPoint(Float.random(in: -limit.x...limit.x, using: &generator),
                                   Float.random(in: -limit.y...limit.y, using: &generator))
            guard placed.allSatisfy({ length($0.position - point) - $0.radius - radius >= 2 }) else { continue }
            placed.append((UInt64(10 + placed.count), point, radius))
        }
        return placed
    }

    private func makeWorld(deformability: Float) async throws -> BubbleWorld {
        let placed = layout()
        XCTAssertGreaterThanOrEqual(placed.count, 20, "scena ma mieć co najmniej 20 baniek")
        let policy = try BubbleDrivePolicy(bandStiffness: 20, maximumForce: 600)
        return try await CrowdScene.makeWorld(bubble: material(deformability: deformability)) { setup in
            var transaction = setup
            for bubble in placed {
                transaction = transaction.add(try CrowdScene.bubble(bubble.id, at: bubble.position, radius: bubble.radius,
                    mass: bubble.radius * bubble.radius / 400, drivePolicy: bubble.id == 4 ? policy : nil))
            }
            return transaction.setGlobalForce([-40, -40]).beginPlayerDrive(CrowdScene.id(4), target: [-100, -100])
        }
    }

    private func mergeTransaction() -> WorldTransaction {
        WorldTransaction().mergeBubbles([CrowdScene.id(1), CrowdScene.id(2)],
            result: BubbleResult(id: CrowdScene.id(100), physicsMaterialID: CrowdScene.bubbleMaterial,
                                 renderMaterialID: CrowdScene.style, eventInterest: [.didAdd]))
    }

    private func splitTransaction() -> WorldTransaction {
        func part(_ id: UInt64) -> BubbleSplitPart {
            BubbleSplitPart(result: BubbleResult(id: CrowdScene.id(id), physicsMaterialID: CrowdScene.bubbleMaterial,
                                                 renderMaterialID: CrowdScene.style, eventInterest: [.didAdd]), share: 0.5)
        }
        return WorldTransaction().splitBubble(CrowdScene.id(3), first: part(101), second: part(102))
    }

    private func bits(_ point: WorldPoint) -> [UInt32] { [point.x.bitPattern, point.y.bitPattern] }

}
