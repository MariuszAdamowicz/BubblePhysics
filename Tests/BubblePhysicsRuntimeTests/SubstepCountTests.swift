@testable import BubblePhysics
import BubblePhysicsNativeMetal
import XCTest
import simd

/// Liczba podkroków w klatce (P-B-18, P-B-19; G5-AC1, G5-AC2) z `NativeMetalFrameTelemetry.substepCount`: 1 podkrok na krok tam, gdzie nic
/// nie wymaga drobniejszego h (tłum w spoczynku, swobodny ruch, gumka gry), a przy docisku F = 20 000 i uderzeniu 10³ j/s liczba rośnie
/// z ω · dt i z v · dt / d zgodnie ze wzorem na h. Odniesienie uderzenia to jednowymiarowa symulacja reguły h w Double.
@MainActor
final class SubstepCountTests: XCTestCase {
    private let wallX: Float = 360
    private let stiffness = 229.0

    private func substeps(_ item: ForceScene.Recorded) -> Int { item.telemetry?.substepCount ?? -1 }

    // MARK: P-B-18 (G5-AC1)

    /// Tłum 4 × 4 baniek „2” z nakładaniem 2 j (ściśnięty, z γ = 1) w spoczynku: kontakty działają siłą, a każdy krok to 1 podkrok.
    func testCrowdAtRestTakesOneSubstepPerStep() async throws {
        let world = try ForceScene.makeWorld(damping: 1) { setup in
            var transaction = setup
            for row in 0..<4 {
                for column in 0..<4 {
                    let position = WorldPoint(Float(column) * 46 - 69, Float(row) * 46 - 69)
                    transaction = transaction.add(try ForceScene.bubble(UInt64(1 + row * 4 + column), at: position))
                }
            }
            return transaction
        }
        let recorded = try await ForceScene.run(world, frames: 300)
        ForceScene.assertHealthy(world)
        XCTAssertEqual(recorded.count, 300)
        for item in recorded {
            guard ForceScene.check(substeps(item) == 1, "krok \(item.step): \(substeps(item)) podkroków zamiast 1") else { return }
        }
    }

    /// Bańka „2” lecąca 30 j/s (wolniej niż d / (4 · dt)) w kierunku ściany i odbijająca się od niej: 1 podkrok także w kontakcie.
    func testSlowFreeMotionWithAWallBounceTakesOneSubstepPerStep() async throws {
        let world = try ForceScene.makeWorld {
            try $0.add(ForceScene.bubble(1, at: [wallX - 24 - 60, 0], velocity: [30, 0])).add(ForceScene.wall(2, x: wallX))
        }
        let recorded = try await ForceScene.run(world, frames: 480)
        ForceScene.assertHealthy(world)
        XCTAssertEqual(recorded.count, 480)
        XCTAssertLessThan(try XCTUnwrap(recorded.last?.velocity(1)).x, 0, "bańka ma się odbić, żeby kontakt wszedł do próby")
        for item in recorded {
            guard ForceScene.check(substeps(item) == 1, "krok \(item.step): \(substeps(item)) podkroków zamiast 1") else { return }
        }
    }

    /// Bańka „2” ciągnięta gumką gry (K_band = 22, γ = 1) do celu 100 j od niej, w wolnej przestrzeni: 1 podkrok na krok.
    func testBubbleDraggedByTheGameBandTakesOneSubstepPerStep() async throws {
        let policy = try BubbleDrivePolicy(bandStiffness: 22)
        let world = try ForceScene.makeWorld(damping: 1) {
            try $0.add(ForceScene.bubble(1, at: .zero, drivePolicy: policy)).beginPlayerDrive(ForceScene.id(1), target: [100, 0])
        }
        let recorded = try await ForceScene.run(world, frames: 300)
        ForceScene.assertHealthy(world)
        XCTAssertEqual(recorded.count, 300)
        XCTAssertGreaterThan(try XCTUnwrap(recorded.compactMap { $0.velocity(1)?.x }.max()), 50, "gumka ma rozpędzić bańkę")
        for item in recorded {
            guard ForceScene.check(substeps(item) == 1, "krok \(item.step): \(substeps(item)) podkroków zamiast 1") else { return }
        }
    }

    // MARK: P-B-19 (G5-AC2)

    /// Statyczny docisk F = 20 000 do ściany (ω · dt ≈ 2,2): 3 ± 1 podkroki w każdej klatce po ustaleniu.
    func testStaticPressOfTwentyThousandTakesAboutThreeSubsteps() async throws {
        let force: Float = 20_000
        let dStar = ContactLawReference.equilibriumDistance(force: Double(force), stiffness: stiffness, radius: 24)
        let world = try ForceScene.makeWorld {
            try $0.add(ForceScene.bubble(1, at: .zero)).add(ForceScene.wall(2, x: Float(dStar))).setGlobalForce([force, 0])
        }
        let recorded = try await ForceScene.run(world, frames: 120)
        ForceScene.assertHealthy(world)
        XCTAssertEqual(recorded.count, 120)
        for item in recorded where item.step >= 5 {
            guard ForceScene.check((2...4).contains(substeps(item)), "krok \(item.step): \(substeps(item)) podkroków zamiast 3 ± 1") else { return }
        }
    }

    /// Czołowe uderzenie „2” w ścianę z prędkością 1000 j/s (γ = 0): największa liczba podkroków w jednej klatce zgadza się ± 20 % z jednowymiarową
    /// symulacją reguły h w Double (ta sama odległość i prędkość na początku, te same klatki), a od pierwszej klatki, w której bańka oddalająca się
    /// ma d > 4 · v · dt, znowu jest 1 podkrok.
    func testImpactAtOneThousandPeaksLikeTheOneDimensionalReferenceAndThenReturnsToOneSubstep() async throws {
        let gap: Float = 100
        let start = wallX - 24 - gap
        let world = try ForceScene.makeWorld {
            try $0.add(ForceScene.bubble(1, at: [start, 0], velocity: [1000, 0])).add(ForceScene.wall(2, x: wallX))
        }
        let frames = 40
        let recorded = try await ForceScene.run(world, frames: frames)
        ForceScene.assertHealthy(world)
        XCTAssertEqual(recorded.count, frames)
        let reference = ContactLawReference.WallScene(radius: 24, mass: 1, stiffness: stiffness, damping: 0,
                                                      startDistance: 24 + Double(gap), velocity: -1000).run(frames: frames)
        XCTAssertFalse(reference.limitExceeded)
        let expectedPeak = Double(try XCTUnwrap(reference.frames.map(\.substeps).max()))
        let peak = Double(recorded.map(substeps).max() ?? 0)
        XCTAssertGreaterThan(expectedPeak, 5, "odniesienie ma pokazywać wyraźny szczyt podkroków")
        XCTAssertEqual(peak, expectedPeak, accuracy: 0.2 * expectedPeak, "szczyt podkroków w klatce: silnik \(peak), odniesienie \(expectedPeak)")
        // Po kontakcie: stan na początku klatki to stan końca poprzedniej.
        var checkedReturn = 0
        for index in 1..<recorded.count {
            guard let x = recorded[index - 1].position(1), let v = recorded[index - 1].velocity(1), v.x < 0 else { continue }
            let d = wallX - x.x
            guard d > 24, d > 4 * abs(v.x) * Float(ForceScene.step) else { continue }
            checkedReturn += 1
            guard ForceScene.check(substeps(recorded[index]) == 1,
                                   "krok \(index): d = \(d), v = \(v.x), a podkroków \(substeps(recorded[index])) zamiast 1") else { return }
        }
        XCTAssertGreaterThan(checkedReturn, 5, "po odbiciu ma być co najmniej kilka klatek z d > 4 · v · dt")
    }
}
