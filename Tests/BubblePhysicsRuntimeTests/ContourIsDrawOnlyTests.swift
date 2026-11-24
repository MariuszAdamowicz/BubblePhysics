@testable import BubblePhysics
import XCTest

/// P-B-25 (G5-AC1): kontur jest tylko rysowany. Dwa światy z tą samą sceną i tym samym K_c; jeden z nich czyta kontur
/// (`debugContourSnapshot()`, kopia z pamięci GPU) w każdym kroku. Pozycje, prędkości, obroty, prędkości kątowe i obwiednie wszystkich
/// obiektów oraz promienie fizyki baniek (`targetRadius`, `collisionRadius`) mają być identyczne bit w bit przez 600 kroków, także
/// po scaleniu i podziale bańki. Kontur nie ma sprzężenia zwrotnego do fizyki: gdyby odczyt go zmieniał albo kontur wpływał na siły,
/// światy by się rozeszły.
@MainActor
final class ContourIsDrawOnlyTests: XCTestCase {
    private func material() throws -> PhysicsMaterial {
        try PhysicsMaterial(kind: .bubble, contactStiffness: 5195, damping: 0.5)
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

    private func makeWorld() async throws -> BubbleWorld {
        let placed = layout()
        XCTAssertGreaterThanOrEqual(placed.count, 20, "scena ma mieć co najmniej 20 baniek")
        let policy = try BubbleDrivePolicy(bandStiffness: 20, maximumForce: 600)
        return try await CrowdScene.makeWorld(bubble: material()) { setup in
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

    /// Jeden krok obu światów z tą samą transakcją przed krokiem; zwraca klatki.
    private func advance(_ worlds: (reading: BubbleWorld, plain: BubbleWorld), submit transaction: WorldTransaction?) async
        -> (reading: WorldFrame, plain: WorldFrame) {
        if let transaction {
            _ = worlds.reading.submit(transaction)
            _ = worlds.plain.submit(transaction)
        }
        let reading = await worlds.reading.advance(by: CrowdScene.step)
        _ = worlds.reading.debugContourSnapshot()
        let plain = await worlds.plain.advance(by: CrowdScene.step)
        return (reading, plain)
    }

    func testReadingTheContourEveryStepDoesNotChangePhysicsForSixHundredSteps() async throws {
        let worlds = (reading: try await makeWorld(), plain: try await makeWorld())
        var compared = 0
        for step in 0..<600 {
            let transaction: WorldTransaction? = step == 150 ? mergeTransaction() : step == 300 ? splitTransaction() : nil
            let frames = await advance(worlds, submit: transaction)
            XCTAssertNil(worlds.reading.diagnostics.lastAdvanceIssue, "krok \(step), świat z odczytem konturu")
            XCTAssertNil(worlds.plain.diagnostics.lastAdvanceIssue, "krok \(step), świat bez odczytu")
            XCTAssertEqual(Set(frames.reading.objects.keys), Set(frames.plain.objects.keys), "krok \(step): zbiory obiektów")
            for (id, state) in frames.reading.objects {
                guard let other = frames.plain.objects[id] else { continue }
                compared += 1
                guard bits(state.position) == bits(other.position), bits(state.velocity) == bits(other.velocity),
                      state.rotation.bitPattern == other.rotation.bitPattern,
                      state.angularVelocity.bitPattern == other.angularVelocity.bitPattern,
                      bits(state.bounds.min) == bits(other.bounds.min), bits(state.bounds.max) == bits(other.bounds.max) else {
                    return XCTFail("krok \(step), obiekt \(id.rawValue): stan fizyki różni się między światami (\(state) kontra \(other))")
                }
            }
            let radii = worlds.reading.debugBubbleRadii, otherRadii = worlds.plain.debugBubbleRadii
            guard radii.count == otherRadii.count, radii.allSatisfy({ id, value in
                otherRadii[id].map { $0.target.bitPattern == value.target.bitPattern && $0.collision.bitPattern == value.collision.bitPattern } == true
            }) else { return XCTFail("krok \(step): promienie fizyki różnią się między światami") }
        }
        XCTAssertGreaterThan(compared, 600 * 20, "porównano stany co najmniej 20 obiektów przez 600 kroków")
        let contours = worlds.reading.debugContourSnapshot()
        XCTAssertGreaterThanOrEqual(contours.count, 20, "odczyt konturu nie jest pusty")
        XCTAssertTrue(contours.values.allSatisfy { $0.count >= 32 })
        XCTAssertNotNil(worlds.reading.debugBubbleRadii[CrowdScene.id(100)], "scalenie z kroku 150 weszło do obu światów")
        XCTAssertNotNil(worlds.reading.debugBubbleRadii[CrowdScene.id(101)], "podział z kroku 300 weszło do obu światów")
    }

}
