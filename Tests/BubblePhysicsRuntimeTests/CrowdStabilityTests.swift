@testable import BubblePhysics
import BubblePhysicsNativeMetal
import XCTest
import simd

/// Stabilność tłumu (P-B-21; G6-AC1): 150 baniek (120 × „2” i 30 × 128, K_c = 229, γ = 1) w ramce ze ścian 640 × 1280 j, startują w spoczynku z połową
/// promienia (ok. 18 % pokrycia, ziarno 1), w 2 s rosną do pełnego promienia (ok. 74 %), a gumka K_band = 22 bez `maximumForce` ciągnie po kolei trzy
/// bańki do lewego dolnego rogu, każdą przez 5 s, w cyklu przez 60 s. Zero `worldFailed`, zero wartości nieskończonych, d > 0, przenikanie konturów 0.
@MainActor
final class CrowdStabilityTests: XCTestCase {
    private let interior = WorldPoint(320, 640)
    private let thickness: Float = 48
    private let seconds = 60
    /// Dopuszczalne wejście wierzchołka jednego konturu w drugi (szum Float na wspólnej cięciwie).
    private let penetrationTolerance: Float = 0.02

    /// Rama ze ścian: boczne na pełną wysokość, górna i dolna między nimi.
    private func walls() throws -> [WorldObject] {
        let inner = interior, outer = interior + WorldPoint(repeating: thickness)
        let rectangles: [(WorldPoint, WorldPoint)] = [
            ([-outer.x, -outer.y], [-inner.x, outer.y]), ([inner.x, -outer.y], [outer.x, outer.y]),
            ([-inner.x, -outer.y], [inner.x, -inner.y]), ([-inner.x, inner.y], [inner.x, outer.y])]
        return try rectangles.enumerated().map { index, corners in
            let (low, high) = corners
            return .rigidBody(try RigidBodyDescriptor(id: ForceScene.id(9_001 + UInt64(index)),
                vertices: [low, [high.x, low.y], high, [low.x, high.y]], motionRole: .static,
                physicsMaterialID: ForceScene.wallMaterial, renderMaterialID: ForceScene.style))
        }
    }

    private struct Placement {
        var id: UInt64
        var kind: ForceScene.Kind
        var position: WorldPoint
    }

    /// Losowe rozmieszczenie bez nakładania przy połowie promienia (ziarno 1): najpierw 30 baniek 128, potem 120 baniek „2”.
    private func placements() -> [Placement] {
        var generator = CrowdScene.SeededGenerator(seed: 1)
        var placed: [Placement] = []
        let kinds: [ForceScene.Kind] = Array(repeating: ForceScene.b128, count: 30) + Array(repeating: ForceScene.two, count: 120)
        for (index, kind) in kinds.enumerated() {
            let half = kind.radius / 2
            var attempts = 0
            while true {
                attempts += 1
                let limit = interior - WorldPoint(repeating: half + 1)
                let point = WorldPoint(Float.random(in: -limit.x...limit.x, using: &generator),
                                       Float.random(in: -limit.y...limit.y, using: &generator))
                if placed.allSatisfy({ simd_distance($0.position, point) > $0.kind.radius / 2 + half + 1 }) || attempts > 10_000 {
                    placed.append(Placement(id: UInt64(index + 1), kind: kind, position: point)); break
                }
            }
        }
        return placed
    }

    /// Głębokość wejścia najgłębszego wierzchołka konturu `inner` we wnętrze wielokąta `outer` (0, gdy żaden wierzchołek nie jest w środku).
    private func penetration(of inner: [WorldPoint], into outer: [WorldPoint]) -> Float {
        var deepest: Float = 0
        for point in inner {
            var inside = false
            var nearest = Float.infinity
            for index in outer.indices {
                let a = outer[index], b = outer[(index + 1) % outer.count]
                if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
                let edge = b - a, along = max(0, min(1, simd_dot(point - a, edge) / max(simd_dot(edge, edge), 1e-12)))
                nearest = min(nearest, simd_distance(point, a + edge * along))
            }
            if inside { deepest = max(deepest, nearest) }
        }
        return deepest
    }

    func testGrowingCrowdPulledByTheBandStaysStableForAMinute() async throws {
        let crowd = placements()
        XCTAssertEqual(crowd.count, 150)
        let policy = try BubbleDrivePolicy(bandStiffness: 22)
        let outer = interior + WorldPoint(repeating: thickness)
        let region = try WorldRectangle(min: -outer, max: outer)
        let world = try ForceScene.makeWorld(damping: 1, region: region) { setup in
            var transaction = setup
            for wall in try walls() { transaction = transaction.add(wall) }
            for item in crowd {
                transaction = transaction.add(try ForceScene.bubble(item.id, at: item.position, item.kind, radius: item.kind.radius / 2, drivePolicy: policy))
                    .startTransition(ParameterTransition(target: .bubbleRadius(ForceScene.id(item.id)), value: .scalar(item.kind.radius), duration: 2))
            }
            return transaction
        }
        let frames = seconds * 60
        let pullers: [UInt64] = [1, 31, 32]
        let corner = WorldPoint(-interior.x, -interior.y)
        var violation: String?
        var penetrationSamples = 0
        let recorded = try await ForceScene.run(world, frames: frames, before: { step in
            guard step % 300 == 0 else { return nil }
            let cycle = step / 300
            var transaction = WorldTransaction()
            if cycle > 0 { transaction = transaction.endPlayerDrive(ForceScene.id(pullers[(cycle - 1) % 3])) }
            return transaction.beginPlayerDrive(ForceScene.id(pullers[cycle % 3]), target: corner)
        }, until: { item in
            var positions: [(id: UInt64, position: WorldPoint)] = []
            for entry in crowd {
                guard let position = item.position(entry.id) else { violation = "krok \(item.step): bańka \(entry.id) zniknęła"; return true }
                guard position.x.isFinite, position.y.isFinite else { violation = "krok \(item.step): bańka \(entry.id) ma wartość nieskończoną"; return true }
                guard abs(position.x) < self.interior.x, abs(position.y) < self.interior.y else {
                    violation = "krok \(item.step): środek bańki \(entry.id) w \(position) poza ramą"; return true
                }
                positions.append((entry.id, position))
            }
            for first in 0..<positions.count {
                for second in (first + 1)..<positions.count where simd_distance(positions[first].position, positions[second].position) <= 0 {
                    violation = "krok \(item.step): środki baniek \(positions[first].id) i \(positions[second].id) się pokrywają"; return true
                }
            }
            if item.step % 60 == 59 {
                let snapshot = world.debugContourSnapshot()
                penetrationSamples += 1
                for first in 0..<crowd.count {
                    for second in (first + 1)..<crowd.count {
                        let a = positions[first], b = positions[second]
                        guard simd_distance(a.position, b.position) < crowd[first].kind.radius + crowd[second].kind.radius,
                              let contourA = snapshot[ForceScene.id(a.id)], let contourB = snapshot[ForceScene.id(b.id)] else { continue }
                        let depth = max(self.penetration(of: contourA, into: contourB), self.penetration(of: contourB, into: contourA))
                        if depth > self.penetrationTolerance {
                            violation = "krok \(item.step): kontury baniek \(a.id) i \(b.id) przenikają się o \(depth)"; return true
                        }
                    }
                }
            }
            return false
        })
        ForceScene.assertHealthy(world, "krok \(recorded.count - 1)")
        if let violation { XCTFail(violation) }
        XCTAssertEqual(recorded.count, frames, "tłum ma przejść całą minutę")
        XCTAssertEqual(penetrationSamples, frames / 60, "kontury sprawdza się co sekundę")
    }
}
