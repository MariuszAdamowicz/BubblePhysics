@testable import BubblePhysics
import BubblePhysicsNativeMetal
import XCTest
import simd

/// Siły liczone w każdym podkroku (P-B-14, P-B-15, P-B-16; G4-AC3, G4-AC4, G4-AC5): gumka, siła globalna, pola i motor idą na GPU i działają
/// z bieżącej pozycji, a wynik nie zależy od drobności podziału. Próg stabilności gumki w stagerze sprawdza `BandStabilityThresholdTests` (bez GPU).
@MainActor
final class SubstepForceTests: XCTestCase {
    private let wallX: Float = 360

    // MARK: P-B-14 (G4-AC3)

    private typealias Scene = (WorldTransaction) throws -> WorldTransaction

    /// Ta sama scena z naturalną liczbą podkroków i z czterokrotnie drobniejszym podziałem; po 1 s pozycje do 1 j, prędkości do 2 % największej
    /// prędkości w scenie (tolerancja bezwzględna, bo część baniek prawie stoi).
    private func assertSplitInvariance(_ name: String, damping: Float, ids: [UInt64], region: Float = 2000, frames: Int = 60,
                                       before: ((Int) throws -> WorldTransaction?)? = nil, build: Scene) async throws {
        var results: [[ForceScene.Recorded]] = []
        for multiplier in [1, 4] {
            var native = NativeMetalConfiguration.default
            native.substepSplitMultiplier = multiplier
            let world = try ForceScene.makeWorld(half: region, damping: damping, native: native, build: build)
            results.append(try await ForceScene.run(world, frames: frames, before: before))
            ForceScene.assertHealthy(world, "\(name), podział × \(multiplier)")
            XCTAssertEqual(results.last?.count, frames, "\(name), podział × \(multiplier)")
        }
        guard let natural = results.first, let split = results.last, natural.count == frames, split.count == frames else { return }
        // Przełącznik ma działać: czterokrotnie drobniejszy podział daje wyraźnie więcej podkroków (co najmniej 3 × tyle, ile naturalny).
        let naturalSubsteps = natural.reduce(0) { $0 + ($1.telemetry?.substepCount ?? 0) }
        let splitSubsteps = split.reduce(0) { $0 + ($1.telemetry?.substepCount ?? 0) }
        XCTAssertGreaterThanOrEqual(naturalSubsteps, frames, "\(name): naturalny podział ma dać co najmniej 1 podkrok na krok")
        XCTAssertGreaterThanOrEqual(splitSubsteps, 3 * naturalSubsteps, "\(name): podkroków naturalnie \(naturalSubsteps), z podziałem × 4 \(splitSubsteps)")
        let maximumSpeed = ForceScene.maximumSpeed(natural, ids: ids)
        XCTAssertGreaterThan(maximumSpeed, 1, "\(name): scena ma się ruszać")
        for id in ids {
            guard let a = natural.last?.position(id), let b = split.last?.position(id),
                  let va = natural.last?.velocity(id), let vb = split.last?.velocity(id) else { XCTFail("\(name): brak bańki \(id)"); continue }
            XCTAssertLessThanOrEqual(simd_distance(a, b), 1, "\(name), bańka \(id): pozycje \(a) i \(b)")
            XCTAssertLessThanOrEqual(simd_distance(va, vb), 0.02 * maximumSpeed, "\(name), bańka \(id): prędkości \(va) i \(vb), największa \(maximumSpeed)")
        }
    }

    func testHeadOnPairGivesTheSameResultWithFinerSubsteps() async throws {
        try await assertSplitInvariance("(a) para czołowa", damping: 1, ids: [1, 2]) {
            try $0.add(ForceScene.bubble(1, at: [300 - 24 - 30, 0], velocity: [100, 0])).add(ForceScene.bubble(2, at: [300 + 24 + 30, 0], velocity: [-100, 0]))
        }
    }

    func testBounceFromTheWallGivesTheSameResultWithFinerSubsteps() async throws {
        let wallX = self.wallX
        try await assertSplitInvariance("(b) odbicie od ściany", damping: 1, ids: [1]) {
            try $0.add(ForceScene.bubble(1, at: [wallX - 24 - 20, 0], velocity: [100, 0])).add(ForceScene.wall(2, x: wallX))
        }
    }

    /// Gumka K_band = 22 ciągnie „2” (γ = 1) za celem jadącym 100 j/s w tłum 4 × 4 baniek „2” w spoczynku.
    func testBandPullingIntoACrowdGivesTheSameResultWithFinerSubsteps() async throws {
        let policy = try BubbleDrivePolicy(bandStiffness: 22)
        let crowd: [UInt64] = Array(1...16)
        try await assertSplitInvariance("(c) gumka w tłum", damping: 1, ids: [100] + crowd, before: { step in
            WorldTransaction().updatePlayerDrive(ForceScene.id(100), target: [Float(step) * 100 / 60, 0])
        }, build: { setup in
            var transaction = setup
            for row in 0..<4 {
                for column in 0..<4 {
                    transaction = transaction.add(try ForceScene.bubble(UInt64(1 + row * 4 + column),
                                                                        at: [80 + Float(column) * 50, Float(row) * 50 - 75]))
                }
            }
            return transaction.add(try ForceScene.bubble(100, at: [0, 0], drivePolicy: policy))
                .beginPlayerDrive(ForceScene.id(100), target: [0, 0])
        })
    }

    func testRadialFieldGivesTheSameResultWithFinerSubsteps() async throws {
        try await assertSplitInvariance("(d) pole radialne", damping: 0, ids: [1]) {
            try $0.add(ForceScene.bubble(1, at: [100, 0], velocity: [0, 100]))
                .add(.forceField(ForceFieldDescriptor(id: ForceScene.id(2), position: .zero, geometry: .circle(radius: 400),
                                                      field: .radial(strength: -500, falloff: 0))))
        }
    }

    // MARK: P-B-15 (G4-AC4)

    /// Cel gumki jedzie ze stałą prędkością u w osi x (w kroku stoi, a między krokami przesuwa się o u · dt), scena bez ścian w regionie 10⁴ × 10⁴.
    /// Zwraca średnią prędkość i średnie naciągnięcie (cel − środek kroku) z ostatnich `tail` sekund.
    private func dragWithBand(_ kind: ForceScene.Kind, damping: Float, targetSpeed u: Float, maximumForce: Float? = nil, seconds: Int)
        async throws -> (velocity: Double, stretch: Double) {
        let policy = try BubbleDrivePolicy(bandStiffness: 22, maximumForce: maximumForce)
        let start: Float = -3000
        let world = try ForceScene.makeWorld(half: 5000, damping: damping) {
            try $0.add(ForceScene.bubble(1, at: [start, 0], kind, drivePolicy: policy)).beginPlayerDrive(ForceScene.id(1), target: [start, 0])
        }
        let frames = seconds * 60
        let recorded = try await ForceScene.run(world, frames: frames, before: { step in
            step == 0 ? nil : WorldTransaction().updatePlayerDrive(ForceScene.id(1), target: [start + u / 60 * Float(step), 0])
        })
        ForceScene.assertHealthy(world, "gumka, m = \(kind.mass), γ = \(damping), u = \(u)")
        XCTAssertEqual(recorded.count, frames, "gumka, m = \(kind.mass), γ = \(damping), u = \(u)")
        let tail = 300
        guard recorded.count == frames else { return (.nan, .nan) }
        let x = recorded.map { Double($0.position(1)?.x ?? .nan) }
        let velocity = (x[frames - 1] - x[frames - 1 - tail]) / (Double(tail) / 60)
        var stretch = 0.0
        for step in (frames - tail)..<frames {
            let target = Double(start + u / 60 * Float(step))
            stretch += target - 0.5 * (x[step] + x[step - 1])
        }
        return (velocity, stretch / Double(tail))
    }

    /// Po ustaleniu obie bańki jadą z prędkością u ± 1 %, a naciągnięcie wynosi u · m · γ / K_band ± 1 %, czyli rośnie z masą.
    func testBandDragsBubbleTwoAtTheTargetSpeedWithStretchProportionalToMass() async throws {
        for damping: Float in [1, 5] {
            let result = try await dragWithBand(ForceScene.two, damping: damping, targetSpeed: 100, seconds: 60)
            XCTAssertEqual(result.velocity, 100, accuracy: 1, "„2”, γ = \(damping): prędkość")
            let expected = 100 * Double(ForceScene.two.mass) * Double(damping) / 22
            XCTAssertEqual(result.stretch, expected, accuracy: 0.01 * expected, "„2”, γ = \(damping): naciągnięcie")
        }
    }

    func testBandDrags7168AtTheTargetSpeedWithStretchProportionalToMass() async throws {
        for damping: Float in [1, 5] {
            let result = try await dragWithBand(ForceScene.b7168, damping: damping, targetSpeed: 100, seconds: 60)
            XCTAssertEqual(result.velocity, 100, accuracy: 1, "7168, γ = \(damping): prędkość")
            let expected = 100 * Double(ForceScene.b7168.mass) * Double(damping) / 22
            XCTAssertEqual(result.stretch, expected, accuracy: 0.01 * expected, "7168, γ = \(damping): naciągnięcie")
        }
    }

    /// `maximumForce` ogranicza siłę gumki tylko wtedy, gdy jest ustawione: przy limicie 100 siły i γ = 1 bańka „2” jedzie 100 j/s mimo celu
    /// jadącego 300 j/s, bez limitu jedzie za celem.
    func testMaximumForceCapsTheBandOnlyWhenItIsSet() async throws {
        let capped = try await dragWithBand(ForceScene.two, damping: 1, targetSpeed: 300, maximumForce: 100, seconds: 20)
        XCTAssertEqual(capped.velocity, 100, accuracy: 1, "z limitem 100 prędkość wynika z F / (γ m)")
        let free = try await dragWithBand(ForceScene.two, damping: 1, targetSpeed: 300, seconds: 20)
        XCTAssertEqual(free.velocity, 300, accuracy: 3, "bez limitu bańka jedzie za celem")
    }

    /// Puszczenie gumki zachowuje prędkość: bez oporu i bez sił bańka jedzie dalej z prędkością z ostatniego kroku przed puszczeniem.
    func testReleasingTheBandKeepsTheVelocity() async throws {
        let policy = try BubbleDrivePolicy(bandStiffness: 22)
        let world = try ForceScene.makeWorld {
            try $0.add(ForceScene.bubble(1, at: .zero, velocity: [200, 0], drivePolicy: policy)).beginPlayerDrive(ForceScene.id(1), target: .zero)
        }
        let releaseStep = 10
        let recorded = try await ForceScene.run(world, frames: 40, before: { $0 == releaseStep ? WorldTransaction().endPlayerDrive(ForceScene.id(1)) : nil })
        ForceScene.assertHealthy(world)
        XCTAssertEqual(recorded.count, 40)
        let before = try XCTUnwrap(recorded[releaseStep - 1].velocity(1))
        XCTAssertGreaterThan(ForceScene.length(before), 1, "bańka ma się ruszać w chwili puszczenia")
        for item in recorded[releaseStep...] {
            let velocity = try XCTUnwrap(item.velocity(1))
            guard ForceScene.check(simd_distance(velocity, before) <= 1e-3 * ForceScene.length(before),
                                   "krok \(item.step): prędkość \(velocity) zamiast \(before)") else { return }
        }
    }

    // MARK: P-B-16 (G4-AC5)

    /// Pole radialne w kole o promieniu 400 j, strength −500, falloff 0; „2” startuje 100 j od środka z prędkością styczną 100 j/s, γ = 0, bez
    /// kontaktów. Po 2 s pozycja zgadza się z całkowaniem pola w Double (krok 1e-4) do 1 j.
    func testRadialFieldMovesTheBubbleLikeTheDoubleReferenceIntegration() async throws {
        let world = try ForceScene.makeWorld {
            try $0.add(ForceScene.bubble(1, at: [100, 0], velocity: [0, 100]))
                .add(.forceField(ForceFieldDescriptor(id: ForceScene.id(2), position: .zero, geometry: .circle(radius: 400),
                                                      field: .radial(strength: -500, falloff: 0))))
        }
        let recorded = try await ForceScene.run(world, frames: 120)
        ForceScene.assertHealthy(world)
        XCTAssertEqual(recorded.count, 120)
        let position = try XCTUnwrap(recorded.last?.position(1))
        let expected = ContactLawReference.integrateRadialField(.init(strength: -500, falloff: 0, radius: 400), mass: 1, damping: 0,
                                                                position: [100, 0], velocity: [0, 100], duration: 2, step: 1e-4)
        XCTAssertLessThanOrEqual(simd_distance(SIMD2<Double>(Double(position.x), Double(position.y)), expected.position), 1,
                                 "pozycja z silnika \(position), z całkowania w Double \(expected.position)")
    }
}
