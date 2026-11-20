import BubblePhysics
import XCTest

/// P-B-17 (G3-AC2): kontur bańki z `debugContourSnapshot()` nie jest płytszy niż wgniecenie geometryczne bieżących kontaktów,
/// czyli odcięcie naturalnego koła ścianą albo cięciwą pary, a po uspokojeniu nie przenika ściany ani drugiej bańki.
///
/// Pomocnik wgniecenia geometrycznego liczy z samej geometrii sceny (położenie z klatki, promień docelowy, płaszczyzna ściany albo
/// cięciwa radykalna dwóch kół), bez korzystania z kodu jądra: w kierunku `u` od środka kontur sięga najdalej
/// `min(r, d / (u · n))`, gdy płaszczyzna o normalnej `n` leży w odległości `d` od środka i `u · n > 0`.
@MainActor
final class ContactContourTests: XCTestCase {
    private let radius: Float = 20
    /// Tolerancja asercji „nie płycej niż geometria”: kontur z GPU w Float, próbkowany punktami.
    private let depthTolerance: Float = 0.02

    private func softWorld(compressionExponent: Float, base: Float, _ build: (WorldTransaction) throws -> WorldTransaction) throws -> BubbleWorld {
        let world = try BubbleWorld(configuration: CrowdScene.configuration())
        var setup = try CrowdScene.resources(bubble: CrowdScene.softBubblePhysics(base: base, compressionExponent: compressionExponent))
        for wall in try CrowdScene.walls() { setup = setup.add(wall) }
        _ = world.submit(try build(setup))
        return world
    }

    /// Najdalszy zasięg naturalnego koła w kierunku `direction`, gdy odcina je płaszczyzna (normalna `normal`, odległość `distance`).
    private func geometricLimit(direction: WorldPoint, normal: WorldPoint, distance: Float) -> Float {
        let alignment = direction.x * normal.x + direction.y * normal.y
        return alignment > 1e-6 ? min(radius, distance / alignment) : radius
    }

    private func length(_ vector: WorldPoint) -> Float { (vector.x * vector.x + vector.y * vector.y).squareRoot() }

    /// Największa głębokość, o jaką kontur jest płytszy niż geometria (≤ 0 oznacza „nie płycej”), po wszystkich próbkach.
    private func worstShortfall(contour: [WorldPoint], center: WorldPoint, normal: WorldPoint, distance: Float) -> Float {
        var worst = -Float.infinity
        for point in contour {
            let offset = point - center
            let reach = length(offset)
            guard reach > 1e-6 else { continue }
            let limit = geometricLimit(direction: offset / reach, normal: normal, distance: distance)
            worst = max(worst, reach - limit)
        }
        return worst
    }

    /// Najgłębsze wgniecenie konturu w promieniach, żeby test nie przechodził na konturze kołowym.
    private func deepestDent(_ contour: [WorldPoint], center: WorldPoint) -> Float {
        radius - (contour.map { length($0 - center) }.min() ?? radius)
    }

    // P-B-17, ściana: bańka dociśnięta siłą globalną do lewej ściany (kc = 3, więc ρ i wgniecenie są wyraźne).
    func testWallContourIsNotShallowerThanTheGeometricDentAndDoesNotPenetrateTheWall() async throws {
        let wallX = -CrowdScene.interiorHalfSize.x
        let world = try softWorld(compressionExponent: 3, base: 0.2) {
            try $0.add(CrowdScene.bubble(1, at: [wallX + radius, 0], radius: radius, mass: 1)).setGlobalForce([-100, 0])
        }
        var checked = 0
        for step in 0..<600 {
            let frame = await world.advance(by: CrowdScene.step)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue, "krok \(step)")
            guard step >= 5, let state = frame.objects[CrowdScene.id(1)],
                  let contour = world.debugContourSnapshot()[CrowdScene.id(1)] else { continue }
            let distance = state.position.x - wallX
            let shortfall = worstShortfall(contour: contour, center: state.position, normal: [-1, 0], distance: distance)
            XCTAssertLessThanOrEqual(shortfall, depthTolerance, "krok \(step): kontur płytszy niż wgniecenie geometryczne o \(shortfall)")
            checked += 1
            if step == 599 {
                XCTAssertGreaterThan(deepestDent(contour, center: state.position), 0.15 * radius, "bańka ma być wyraźnie wgnieciona")
                let penetration = -((contour.map(\.x).min() ?? 0) - wallX)
                XCTAssertLessThanOrEqual(penetration, 0.5, "kontur po uspokojeniu nie przenika ściany")
            }
        }
        XCTAssertGreaterThan(checked, 500)
    }

    // P-B-17, para: dwie jednakowe miękkie bańki ściskane siłami `MotorDrive`. Dla jednakowych kół i podatności podział wgniecenia c_a : c_b
    // jest równy połowie, więc cięciwa pary leży na płaszczyźnie symetrii w odległości D / 2 od każdego środka.
    func testPairContoursAreNotShallowerThanTheChordDentAndDoNotPenetrateEachOther() async throws {
        let world = try softWorld(compressionExponent: 0, base: 0.2) {
            try $0.add(CrowdScene.bubble(1, at: [-radius, 0], radius: radius, mass: 1))
                .add(CrowdScene.bubble(2, at: [radius, 0], radius: radius, mass: 1))
                .setMotorDrive(CrowdScene.id(1), drive: MotorDrive(force: [30, 0]))
                .setMotorDrive(CrowdScene.id(2), drive: MotorDrive(force: [-30, 0]))
        }
        var checked = 0
        for step in 0..<400 {
            let frame = await world.advance(by: CrowdScene.step)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue, "krok \(step)")
            guard step >= 5, let first = frame.objects[CrowdScene.id(1)], let second = frame.objects[CrowdScene.id(2)] else { continue }
            let snapshot = world.debugContourSnapshot()
            guard let contourA = snapshot[CrowdScene.id(1)], let contourB = snapshot[CrowdScene.id(2)] else { continue }
            let offset = second.position - first.position
            let distance = length(offset)
            let normal = offset / distance
            let shortfallA = worstShortfall(contour: contourA, center: first.position, normal: normal, distance: distance / 2)
            let shortfallB = worstShortfall(contour: contourB, center: second.position, normal: normal * -1, distance: distance / 2)
            XCTAssertLessThanOrEqual(shortfallA, depthTolerance, "krok \(step): kontur a płytszy niż cięciwa o \(shortfallA)")
            XCTAssertLessThanOrEqual(shortfallB, depthTolerance, "krok \(step): kontur b płytszy niż cięciwa o \(shortfallB)")
            checked += 1
            if step == 399 {
                XCTAssertLessThan(distance, 2 * radius - 5, "para ma być wyraźnie ściśnięta")
                XCTAssertGreaterThan(deepestDent(contourA, center: first.position), 0.1 * radius)
                // Bez przenikania: punkty a nie wchodzą w b głębiej niż 0,5 (płaszczyzna cięciwy leży w D / 2 od każdego środka).
                let intoB = contourA.map { ($0 - first.position).x * normal.x + ($0 - first.position).y * normal.y - distance / 2 }.max() ?? 0
                let intoA = contourB.map { -(($0 - second.position).x * normal.x + ($0 - second.position).y * normal.y) - distance / 2 }.max() ?? 0
                XCTAssertLessThanOrEqual(intoB, 0.5, "kontur a nie przenika b")
                XCTAssertLessThanOrEqual(intoA, 0.5, "kontur b nie przenika a")
            }
        }
        XCTAssertGreaterThan(checked, 350)
    }
}
