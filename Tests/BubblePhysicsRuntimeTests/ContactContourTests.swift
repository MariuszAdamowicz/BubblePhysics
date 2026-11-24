import BubblePhysics
import BubblePhysicsNativeMetal
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

    private func softWorld(base: Float, damping: Float = 0, _ build: (WorldTransaction) throws -> WorldTransaction) throws -> BubbleWorld {
        try softWorld(material: CrowdScene.softBubblePhysics(base: base, damping: damping), build)
    }

    private func softWorld(material: PhysicsMaterial, _ build: (WorldTransaction) throws -> WorldTransaction) throws -> BubbleWorld {
        let world = try BubbleWorld(configuration: CrowdScene.configuration())
        var setup = try CrowdScene.resources(bubble: material)
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

    /// P-B-26 (G5-AC2): niezmienniki konturu rysowanego w każdej scenie: każdy punkt leży w kole o promieniu bańki (± 1e-3),
    /// żadna krawędź nie jest dłuższa niż `maxContourSegmentLength` konfiguracji NativeMetal, a krok nie został odrzucony.
    private func assertContourInvariants(_ contour: [WorldPoint], center: WorldPoint, radius: Float, world: BubbleWorld, _ context: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let maximumEdge = NativeSolverConfiguration().maxContourSegmentLength
        XCTAssertNil(world.diagnostics.lastAdvanceIssue, context, file: file, line: line)
        XCTAssertGreaterThanOrEqual(contour.count, 3, context, file: file, line: line)
        for (index, point) in contour.enumerated() {
            XCTAssertLessThanOrEqual(length(point - center), radius + 1e-3, "\(context): punkt \(index) poza kołem bańki", file: file, line: line)
            let next = contour[(index + 1) % contour.count]
            XCTAssertLessThanOrEqual(length(next - point), maximumEdge, "\(context): krawędź \(index) dłuższa niż limit", file: file, line: line)
        }
    }

    /// Najgłębsze wgniecenie konturu w promieniach, żeby test nie przechodził na konturze kołowym.
    private func deepestDent(_ contour: [WorldPoint], center: WorldPoint, radius: Float? = nil) -> Float {
        let full = radius ?? self.radius
        return full - (contour.map { length($0 - center) }.min() ?? full)
    }

    // P-B-17, ściana: bańka dociśnięta siłą globalną do lewej ściany. c₀ = 0,06 i F = 100 dają ugięcie c · F = 6 = 0,3 r, więc
    // wgniecenie jest wyraźne.
    func testWallContourIsNotShallowerThanTheGeometricDentAndDoesNotPenetrateTheWall() async throws {
        let wallX = -CrowdScene.interiorHalfSize.x
        let world = try softWorld(base: 0.06) {
            try $0.add(CrowdScene.bubble(1, at: [wallX + radius, 0], radius: radius, mass: 1)).setGlobalForce([-100, 0])
        }
        var checked = 0
        for step in 0..<600 {
            let frame = await world.advance(by: CrowdScene.step)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue, "krok \(step)")
            guard step >= 5, let state = frame.objects[CrowdScene.id(1)],
                  let contour = world.debugContourSnapshot()[CrowdScene.id(1)] else { continue }
            assertContourInvariants(contour, center: state.position, radius: radius, world: world, "ściana, krok \(step)")
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
        let world = try softWorld(base: 0.2) {
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
            assertContourInvariants(contourA, center: first.position, radius: radius, world: world, "para a, krok \(step)")
            assertContourInvariants(contourB, center: second.position, radius: radius, world: world, "para b, krok \(step)")
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

    // MARK: tłok w narożniku (P-B-6, G5-AC3)

    /// Odległość punktu od odcinka.
    private func distance(from point: WorldPoint, toSegment start: WorldPoint, _ end: WorldPoint) -> Float {
        let edge = end - start
        let lengthSquared = edge.x * edge.x + edge.y * edge.y
        let t = lengthSquared > 0 ? max(0, min(1, ((point - start).x * edge.x + (point - start).y * edge.y) / lengthSquared)) : 0
        return length(point - (start + edge * t))
    }

    /// Głębokość, na jaką punkt wchodzi w zamknięty wielokąt `polygon` (0, gdy leży na zewnątrz): odległość od jego brzegu.
    private func depth(of point: WorldPoint, in polygon: [WorldPoint]) -> Float {
        var inside = false
        var nearest = Float.infinity
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            nearest = min(nearest, distance(from: point, toSegment: a, b))
        }
        return inside ? nearest : 0
    }

    // P-B-6 (G5-AC3): co najmniej 20 baniek r 12–48 (c₀ 0,0108, r_ref 20) dociśniętych siłą globalną do narożnika pudła. Po uspokojeniu
    // kontury nie przenikają się nawzajem ani ścian o więcej niż 0,5.
    func testCrowdInBoxCornerContoursDoNotPenetrateEachOtherOrWalls() async throws {
        let count = 24
        var generator = CrowdScene.SeededGenerator(seed: 3_850)
        var placed: [(id: UInt64, position: WorldPoint, radius: Float)] = []
        var attempts = 0
        while placed.count < count, attempts < 20_000 {
            attempts += 1
            let bubbleRadius = Float.random(in: 12...48, using: &generator)
            let limit = CrowdScene.interiorHalfSize - WorldPoint(repeating: bubbleRadius + 1)
            let point = WorldPoint(Float.random(in: -limit.x...limit.x, using: &generator),
                                   Float.random(in: -limit.y...limit.y, using: &generator))
            guard placed.allSatisfy({ length($0.position - point) >= $0.radius + bubbleRadius + 2 }) else { continue }
            placed.append((UInt64(placed.count + 1), point, bubbleRadius))
        }
        XCTAssertEqual(placed.count, count, "scena ma mieć co najmniej 20 baniek")
        // Silnik 4.0.0 ma tylko siły: uspokojenie tłoku daje opór γ materiału (bez niego tłok drga bez końca), a bańki bez tarcia osiadają
        // powoli (zsuwanie wzdłuż ścian z prędkością graniczną F / (m γ)), stąd 4 000 klatek.
        let world = try softWorld(base: 0.0108, damping: 5) { setup in
            try placed.reduce(setup) { transaction, bubble in
                transaction.add(try CrowdScene.bubble(bubble.id, at: bubble.position, radius: bubble.radius, mass: bubble.radius * bubble.radius / 400))
            }.setGlobalForce([-40, -40])
        }
        var frame = await world.advance(by: CrowdScene.step)
        for index in 0..<4_000 {
            frame = await world.advance(by: CrowdScene.step)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue, "krok \(index): \(String(describing: world.diagnostics.lastRejectionReason))")
            if world.diagnostics.lastAdvanceIssue != nil { return }
        }
        let snapshot = world.debugContourSnapshot()
        XCTAssertEqual(snapshot.count, count)
        var deepestBetweenBubbles: Float = 0, deepestIntoWall: Float = 0, mostDented: Float = 0
        let half = CrowdScene.interiorHalfSize
        for first in placed {
            let contour = try XCTUnwrap(snapshot[CrowdScene.id(first.id)], "kontur bańki \(first.id)")
            let state = try XCTUnwrap(frame.objects[CrowdScene.id(first.id)])
            assertContourInvariants(contour, center: state.position, radius: first.radius, world: world, "tłok, bańka \(first.id)")
            mostDented = max(mostDented, deepestDent(contour, center: state.position, radius: first.radius))
            for point in contour { deepestIntoWall = max(deepestIntoWall, abs(point.x) - half.x, abs(point.y) - half.y) }
            for second in placed where second.id != first.id {
                let other = try XCTUnwrap(snapshot[CrowdScene.id(second.id)])
                guard length(try XCTUnwrap(frame.objects[CrowdScene.id(second.id)]).position - state.position) < first.radius + second.radius + 1
                else { continue }
                for point in contour { deepestBetweenBubbles = max(deepestBetweenBubbles, depth(of: point, in: other)) }
            }
        }
        // Po uspokojeniu: tłok prawie się nie rusza (szczyt prędkości w trakcie osiadania to ok. 180), a bańka najbliższa narożnika
        // (−x, −y) styka się z obiema ścianami (okrąg o promieniu docelowym sięga ściany albo ją przekracza).
        let maxSpeed = frame.objects.values.map { length($0.velocity) }.max() ?? .infinity
        XCTAssertLessThan(maxSpeed, 5, "tłok ma być uspokojony, największa prędkość w ostatniej klatce \(maxSpeed)")
        let corner = try XCTUnwrap(placed.min { length(try XCTUnwrap(frame.objects[CrowdScene.id($0.id)]).position + half)
                                                < length(try XCTUnwrap(frame.objects[CrowdScene.id($1.id)]).position + half) })
        let cornerPosition = try XCTUnwrap(frame.objects[CrowdScene.id(corner.id)]).position
        XCTAssertLessThanOrEqual(cornerPosition.x - corner.radius + half.x, 0.5, "bańka przy narożniku styka się z lewą ścianą")
        XCTAssertLessThanOrEqual(cornerPosition.y - corner.radius + half.y, 0.5, "bańka przy narożniku styka się z dolną ścianą")
        XCTAssertGreaterThan(mostDented, 1, "tłok ma być wyraźnie ściśnięty, najgłębsze wgniecenie \(mostDented)")
        XCTAssertLessThanOrEqual(deepestBetweenBubbles, 0.5, "kontury baniek się przenikają")
        XCTAssertLessThanOrEqual(deepestIntoWall, 0.5, "kontur przenika ścianę")
    }
}
