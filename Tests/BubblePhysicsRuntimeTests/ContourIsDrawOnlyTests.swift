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
        try PhysicsMaterial(kind: .bubble, deformability: deformability, damping: 0.5, maximumLinearSpeed: 600)
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

    func testContourDoesNotChangePhysicsOverSixHundredSteps() async throws {
        let plain = try await makeWorld(deformability: 0)
        let reading = try await makeWorld(deformability: 0.65)
        var differingBounds = 0
        var comparedObjects = 0
        var accepted: [String: Bool] = [:]
        for step in 1...600 {
            var tokens: [(String, TransactionToken, TransactionToken)] = []
            if step == 150 { tokens.append(("merge", plain.submit(mergeTransaction()), reading.submit(mergeTransaction()))) }
            if step == 300 { tokens.append(("split", plain.submit(splitTransaction()), reading.submit(splitTransaction()))) }
            let frameA = await plain.advance(by: CrowdScene.step)
            let frameB = await reading.advance(by: CrowdScene.step)
            let contours = reading.debugContourSnapshot()
            XCTAssertNil(plain.diagnostics.lastAdvanceIssue, "świat bez odczytu konturu, krok \(step)")
            XCTAssertNil(reading.diagnostics.lastAdvanceIssue, "świat z odczytem konturu, krok \(step)")
            if plain.diagnostics.lastAdvanceIssue != nil || reading.diagnostics.lastAdvanceIssue != nil { return }
            for (name, tokenA, tokenB) in tokens {
                accepted[name] = frameA.transactionReceipts.contains { $0.token == tokenA }
                    && frameB.transactionReceipts.contains { $0.token == tokenB }
            }
            XCTAssertEqual(Set(frameA.objects.keys), Set(frameB.objects.keys), "krok \(step): te same obiekty")
            let bubbleCount = frameB.objects.values.filter { if case .bubble = $0.kind { return true }; return false }.count
            XCTAssertEqual(contours.count, bubbleCount, "krok \(step): świat z odczytem ma kontur każdej bańki")
            let radiiA = plain.debugBubbleRadii, radiiB = reading.debugBubbleRadii
            XCTAssertEqual(Set(radiiA.keys), Set(radiiB.keys), "krok \(step): te same bańki")
            for (id, a) in frameA.objects.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                guard let b = frameB.objects[id] else { continue }
                comparedObjects += 1
                XCTAssertEqual(bits(a.position), bits(b.position), "krok \(step), obiekt \(id.rawValue): pozycja")
                XCTAssertEqual(bits(a.velocity), bits(b.velocity), "krok \(step), obiekt \(id.rawValue): prędkość")
                XCTAssertEqual(a.rotation.bitPattern, b.rotation.bitPattern, "krok \(step), obiekt \(id.rawValue): obrót")
                XCTAssertEqual(a.angularVelocity.bitPattern, b.angularVelocity.bitPattern,
                               "krok \(step), obiekt \(id.rawValue): prędkość kątowa")
                if let ra = radiiA[id], let rb = radiiB[id] {
                    XCTAssertEqual(ra.target.bitPattern, rb.target.bitPattern, "krok \(step), obiekt \(id.rawValue): targetRadius")
                    XCTAssertEqual(ra.collision.bitPattern, rb.collision.bitPattern, "krok \(step), obiekt \(id.rawValue): collisionRadius")
                }
                if case .bubble = a.kind,
                   bits(a.bounds.min) + bits(a.bounds.max) != bits(b.bounds.min) + bits(b.bounds.max) {
                    differingBounds += 1
                }
            }
        }
        XCTAssertEqual(accepted["merge"], true, "scalenie przyjęte w obu światach")
        XCTAssertEqual(accepted["split"], true, "podział przyjęty w obu światach")
        XCTAssertGreaterThan(comparedObjects, 600 * 20)
        XCTAssertGreaterThan(differingBounds, 0, "kontur obu światów ma się różnić, inaczej test niczego nie rozróżnia")
    }
}
