@testable import BubblePhysics
import BubblePhysicsNativeMetal
import XCTest

/// Całkowanie siłowe uderzenia w ścianę (P-B-12, P-B-13; G4-AC1, G4-AC2): bez oporu bańka odbija się z prędkością z przed uderzenia,
/// z oporem γ ubytek energii równa się ∫ γ · m · |v|² dt z zapisu podkroków. Ściana grubości 1 leży w x = 360 (rząd współrzędnych planszy).
@MainActor
final class ForceIntegrationTests: XCTestCase {
    private let wallX: Float = 360
    private let stiffness = 229.0

    // MARK: P-B-12 (G4-AC1)

    /// Uderzenie prostopadłe bez oporu i bez gumki: prędkość po odbiciu ma moduł prędkości z przed uderzenia ± 2 %.
    private func assertRebound(_ kind: ForceScene.Kind, name: String, speed: Float) async throws {
        let wallX = self.wallX
        let start = wallX - kind.radius - 100
        let world = try ForceScene.makeWorld {
            try $0.add(ForceScene.bubble(1, at: [start, 0], kind, velocity: [speed, 0])).add(ForceScene.wall(2, x: wallX))
        }
        let recorded = try await ForceScene.run(world, frames: 400, until: { item in
            guard let x = item.position(1), let v = item.velocity(1) else { return true }
            return v.x < 0 && x.x < wallX - kind.radius
        })
        ForceScene.assertHealthy(world, "\(name), v = \(speed)")
        let last = try XCTUnwrap(recorded.last)
        let velocity = try XCTUnwrap(last.velocity(1))
        XCTAssertLessThan(velocity.x, 0, "\(name), v = \(speed): bańka ma się odbić")
        XCTAssertEqual(abs(velocity.x), speed, accuracy: 0.02 * speed, "\(name), v = \(speed): prędkość po odbiciu \(velocity.x)")
        XCTAssertEqual(velocity.y, 0, accuracy: 0.02 * speed, "\(name), v = \(speed): prędkość poprzeczna")
    }

    func testBubbleTwoReboundsFromTheWallWithItsImpactSpeed() async throws {
        for speed: Float in [100, 1000, 3000] { try await assertRebound(ForceScene.two, name: "„2”", speed: speed) }
    }

    func testBubble7168ReboundsFromTheWallWithItsImpactSpeed() async throws {
        for speed: Float in [100, 1000, 3000] { try await assertRebound(ForceScene.b7168, name: "7168", speed: speed) }
    }

    // MARK: P-B-13 (G4-AC2)

    /// Bańka z oporem γ dociera do ściany z prędkością `contactSpeed` w chwili pierwszego kontaktu (start 0,1 · v nad powierzchnią, więc
    /// prędkość początkowa to v + γ · odległość: opór wytraca prędkość o γ · drogę). Okno [t₀, t₀ + 3 s], t₀ to 0,1 s przed pierwszym
    /// kontaktem; bilans z diagnostycznego zapisu podkroków, nie z próbek co klatkę.
    private func assertEnergyBalance(_ kind: ForceScene.Kind, damping: Float, contactSpeed: Float, name: String) async throws {
        let gap = 0.1 * contactSpeed
        let initialSpeed = contactSpeed + damping * gap
        let start = wallX - kind.radius - gap
        var native = NativeMetalConfiguration.default
        native.captureSubsteps = true
        let world = try ForceScene.makeWorld(damping: damping, native: native) {
            try $0.add(ForceScene.bubble(1, at: [start, 0], kind, velocity: [initialSpeed, 0])).add(ForceScene.wall(2, x: wallX))
        }
        let recorded = try await ForceScene.run(world, frames: 215)
        let context = "\(name), γ = \(damping), v = \(contactSpeed)"
        ForceScene.assertHealthy(world, context)
        XCTAssertEqual(recorded.count, 215, context)
        let samples = EnergyBalance.samples(of: 1, in: recorded, wallX: wallX, initialX: start, initialVx: initialSpeed)
        XCTAssertGreaterThan(samples.count, 215, "\(context): zapis podkroków ma dać co najmniej jeden podkrok na klatkę")
        let result = try XCTUnwrap(EnergyBalance.evaluate(samples, radius: Double(kind.radius), mass: Double(kind.mass),
                                                          stiffness: stiffness, damping: Double(damping)), context)
        XCTAssertTrue(result.coversWindow, "\(context): zapis kończy się przed końcem okna")
        XCTAssertEqual(result.energyLoss, result.dissipated, accuracy: 0.05 * result.dissipated + 0.01 * result.initialEnergy,
                       "\(context): ubytek energii \(result.energyLoss), ∫ γ m v² dt = \(result.dissipated)")
    }

    func testEnergyLossEqualsTheDragIntegralForBubbleTwo() async throws {
        for damping: Float in [1, 5] {
            for speed: Float in [100, 1000] {
                try await assertEnergyBalance(ForceScene.two, damping: damping, contactSpeed: speed, name: "„2”")
            }
        }
    }

    func testEnergyLossEqualsTheDragIntegralForBubble7168() async throws {
        try await assertEnergyBalance(ForceScene.b7168, damping: 1, contactSpeed: 1000, name: "7168")
    }

    /// Narzędzie bilansu na odniesieniu w Double: ten sam rachunek na śladzie jednowymiarowej symulacji reguły h daje zgodność w
    /// tolerancji z kryterium, więc tolerancja testów powyżej mierzy silnik, a nie błąd metody liczenia.
    func testEnergyBalanceHelperAgreesWithTheReferenceTrace() {
        for (damping, speed) in [(1.0, 100.0), (5.0, 1000.0), (1.0, 1000.0)] {
            let gap = 0.1 * speed
            let scene = ContactLawReference.WallScene(radius: 24, mass: 1, stiffness: stiffness, damping: damping,
                                                      startDistance: 24 + gap, velocity: -(speed + damping * gap))
            let trace = scene.run(frames: 215)
            XCTAssertFalse(trace.limitExceeded)
            XCTAssertFalse(trace.penetrated)
            var samples = [EnergyBalance.Sample(h: 0, distance: scene.startDistance, velocity: scene.velocity)]
            samples += trace.substeps.map { .init(h: $0.h, distance: $0.distance, velocity: $0.velocity) }
            let result = EnergyBalance.evaluate(samples, radius: 24, mass: 1, stiffness: stiffness, damping: damping)
            XCTAssertNotNil(result)
            guard let result else { continue }
            XCTAssertTrue(result.coversWindow)
            XCTAssertEqual(result.energyLoss, result.dissipated, accuracy: 0.05 * result.dissipated + 0.01 * result.initialEnergy,
                           "γ = \(damping), v = \(speed)")
            XCTAssertGreaterThan(result.dissipated, 0.1 * result.initialEnergy, "okno ma obejmować wyraźną stratę")
        }
    }
}
