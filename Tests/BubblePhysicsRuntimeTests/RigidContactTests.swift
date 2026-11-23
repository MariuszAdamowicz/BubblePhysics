@testable import BubblePhysics
import BubblePhysicsNativeMetal
import XCTest
import simd

/// Kontakt bańki z bryłami statycznymi i kinematycznymi (P-B-7, P-B-11, P-B-17; G2-AC4, G3-AC3, G4-AC6): to samo prawo kontaktu co przy ścianie
/// dla koła, kapsuły i stojącej bryły kinematycznej; brak przejścia przez obracającą się bryłę kinematyczną jadącą 10³ j/s; bańka `.pathDriven`
/// dojeżdża do pozy z toru, a kontakt działa na nią siłą. Odrzucenie bańki w roli `.kinematic` sprawdza `KinematicStagingTests` (bez GPU).
@MainActor
final class RigidContactTests: XCTestCase {
    private let stiffness = 229.0

    // MARK: P-B-7 (G2-AC4)

    private enum Body: CustomStringConvertible {
        case circle, capsule, standingKinematic
        var description: String { switch self { case .circle: "koło"; case .capsule: "kapsuła"; case .standingKinematic: "stojąca bryła kinematyczna" } }
        /// Odległość powierzchni od środka bryły w kierunku bańki (bańka z lewej, dociskana siłą w +x).
        var surfaceOffset: Float { switch self { case .circle: 50; case .capsule: 20; case .standingKinematic: 50 } }
        @MainActor func object() throws -> WorldObject {
            switch self {
            case .circle: try ForceScene.rigid(2, .circle(radius: 50), at: .zero)
            // Kapsuła o promieniu 20 i długości 100 (halfLength 50), obrócona o 90°: bańka dotyka jej płaskiego boku.
            case .capsule: try ForceScene.rigid(2, .capsule(halfLength: 50, radius: 20), at: .zero, rotation: .pi / 2)
            // Kwadrat 100 j, rola kinematyczna bez napędu, czyli prędkość zadana 0.
            case .standingKinematic: try ForceScene.square(2, at: .zero, side: 100, role: .kinematic)
            }
        }
    }

    /// Bańka „2” dociśnięta siłą F do bryły, start w spoczynku w d* liczonym od środka bańki do powierzchni bryły, γ = 0, 20 s:
    /// |d − d*| ≤ 0,5 % · d* + 1e-3 w każdej klatce.
    private func assertEquilibrium(_ body: Body, force: Float) async throws {
        let dStar = ContactLawReference.equilibriumDistance(force: Double(force), stiffness: stiffness, radius: 24)
        let start = -Float(Double(body.surfaceOffset) + dStar)
        let world = try ForceScene.makeWorld {
            try $0.add(ForceScene.bubble(1, at: [start, 0])).add(body.object()).setGlobalForce([force, 0])
        }
        let recorded = try await ForceScene.run(world, frames: 1200)
        let context = "\(body), F = \(force)"
        ForceScene.assertHealthy(world, context)
        XCTAssertEqual(recorded.count, 1200, context)
        for item in recorded {
            guard let x = item.position(1) else { XCTFail("\(context): bańka zniknęła"); return }
            let d = -Double(x.x) - Double(body.surfaceOffset)
            guard ForceScene.check(d > 0, "\(context), krok \(item.step): d = \(d) ≤ 0"),
                  ForceScene.check(abs(d - dStar) <= 0.005 * dStar + 1e-3, "\(context), krok \(item.step): d = \(d), d* = \(dStar)") else { return }
        }
    }

    func testBubblePressedToAStaticCircleHoldsTheLawDistance() async throws {
        for force: Float in [100, 1200, 10_000] { try await assertEquilibrium(.circle, force: force) }
    }

    func testBubblePressedToAStaticCapsuleHoldsTheLawDistance() async throws {
        for force: Float in [100, 1200, 10_000] { try await assertEquilibrium(.capsule, force: force) }
    }

    func testBubblePressedToAStandingKinematicBodyHoldsTheLawDistance() async throws {
        for force: Float in [100, 1200, 10_000] { try await assertEquilibrium(.standingKinematic, force: force) }
    }

    // MARK: P-B-11 (G3-AC3)

    /// Kwadrat o boku 50 j (ρ ≈ 35 j) jedzie 10³ j/s i obraca się 20 rad/s, uderza w swobodną „2” (γ = 0) przy współrzędnych rzędu 360 j. Po każdym
    /// podkroku środek bańki jest poza bryłą (poza bryły z interpolacji między pozami początku i końca kroku), bańka odbija się, a bryła jedzie
    /// dalej po swoim torze bez zmiany.
    func testSpinningKinematicBodyNeverEntersTheBubbleCenterAndKeepsItsPath() async throws {
        let speed: Float = 1000, spin: Float = 20, side: Float = 50, frames = 30
        var native = NativeMetalConfiguration.default
        native.captureSubsteps = true
        let startBody = WorldPoint(250, 0)
        let world = try ForceScene.makeWorld(native: native) {
            try $0.add(ForceScene.bubble(1, at: [360, 0]))
                .add(ForceScene.square(2, at: startBody, side: side, role: .kinematic))
                .setKinematicDrive(ForceScene.id(2), drive: .velocity(linear: [speed, 0], angular: spin))
        }
        let recorded = try await ForceScene.run(world, frames: frames)
        ForceScene.assertHealthy(world)
        XCTAssertEqual(recorded.count, frames)
        var previous = (position: startBody, rotation: Float(0))
        var checked = 0
        for item in recorded {
            guard let pose = item.frame.objects[ForceScene.id(2)] else { XCTFail("bryła zniknęła w kroku \(item.step)"); return }
            let total = item.samples.reduce(Float(0)) { $0 + $1.h }
            var elapsed: Float = 0
            for sample in item.samples {
                elapsed += sample.h
                guard let bubble = sample.bubbles[1] else { continue }
                let fraction = total > 0 ? elapsed / total : 1
                let center = previous.position + (pose.position - previous.position) * fraction
                let rotation = previous.rotation + (pose.rotation - previous.rotation) * fraction
                checked += 1
                guard ForceScene.check(!ForceScene.isInsideSquare(bubble.position, center: center, rotation: rotation, half: side / 2),
                                       "krok \(item.step): środek bańki \(bubble.position) wewnątrz bryły w \(center)") else { return }
            }
            previous = (pose.position, pose.rotation)
        }
        XCTAssertGreaterThan(checked, frames, "zapis podkroków ma dać co najmniej jeden podkrok na klatkę")
        let bubble = try XCTUnwrap(recorded.last?.velocity(1))
        XCTAssertGreaterThan(bubble.x, 0.5 * speed, "bańka ma odbić się od bryły w kierunku jazdy, prędkość \(bubble)")
        let last = try XCTUnwrap(recorded.last?.frame.objects[ForceScene.id(2)])
        let elapsed = Float(frames) / 60
        XCTAssertEqual(last.position.x, startBody.x + speed * elapsed, accuracy: 2e-3, "tor bryły")
        XCTAssertEqual(last.position.y, startBody.y, accuracy: 2e-3, "tor bryły")
        XCTAssertEqual(last.rotation, spin * elapsed, accuracy: 1e-3, "obrót bryły")
    }

    // MARK: P-B-17 (G4-AC6)

    /// Bańka `.pathDriven` bez kontaktów dociera do pozy z toru z dokładnością 1e-3 j, a po drodze jedzie po torze z prędkością zadaną
    /// (po k krokach x = x₀ + min(speed · k · dt, długość toru); pośrednio z tolerancją 5e-3 j na kumulację Float w k krokach).
    func testPathDrivenBubbleWithoutContactsFollowsThePath() async throws {
        let track = PathDriveCase(speed: 100, from: -500, to: -300)
        let world = try ForceScene.makeWorld {
            try $0.add(ForceScene.bubble(1, at: [track.from, 0], role: .pathDriven))
                .setPathDrive(ForceScene.id(1), drive: PathDrive(points: [[track.from, 0], [track.to, 0]], speed: track.speed))
        }
        let recorded = try await ForceScene.run(world, frames: 150)
        ForceScene.assertHealthy(world)
        XCTAssertEqual(recorded.count, 150)
        for item in recorded {
            let expected = track.from + min(track.speed * Float(item.step + 1) / 60, track.to - track.from)
            guard let position = item.position(1) else { XCTFail("bańka zniknęła"); return }
            guard ForceScene.check(abs(position.x - expected) <= 5e-3 && abs(position.y) <= 1e-3,
                                   "krok \(item.step): pozycja \(position), z toru \(expected)") else { return }
        }
        let final = try XCTUnwrap(recorded.last?.position(1))
        XCTAssertEqual(final.x, track.to, accuracy: 1e-3, "pozycja docelowa toru")
        XCTAssertEqual(final.y, 0, accuracy: 1e-3, "pozycja docelowa toru")
    }

    private struct PathDriveCase {
        var speed: Float
        var from: Float
        var to: Float
    }

    /// Kontakt działa na bańkę `.pathDriven` siłą: tor prowadzi w cienką ścianę w x = 0, a środek zostaje po stronie startowej, d > 0, bez
    /// `worldFailed`. Bańka wchodzi w kontakt (środek bliżej niż r), więc to siła kontaktu, a nie brak ruchu, ją zatrzymuje.
    func testPathDrivenBubbleIsStoppedByContactForceBeforeAWall() async throws {
        let world = try ForceScene.makeWorld {
            try $0.add(ForceScene.bubble(1, at: [-300, 0], role: .pathDriven)).add(ForceScene.wall(2, x: 0))
                .setPathDrive(ForceScene.id(1), drive: PathDrive(points: [[-300, 0], [300, 0]], speed: 100))
        }
        let recorded = try await ForceScene.run(world, frames: 420)
        ForceScene.assertHealthy(world)
        XCTAssertEqual(recorded.count, 420)
        var deepest: Float = -.infinity
        for item in recorded {
            guard let position = item.position(1) else { XCTFail("bańka zniknęła"); return }
            deepest = max(deepest, position.x)
            guard ForceScene.check(position.x < 0, "krok \(item.step): środek \(position.x) za płaszczyzną ściany") else { return }
        }
        XCTAssertGreaterThan(deepest, -24, "bańka ma wejść w kontakt ze ścianą (środek bliżej niż r), najgłębiej \(deepest)")
    }
}
