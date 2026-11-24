import BubblePhysics
import simd
import XCTest

/// Jednostronne krawędzie statycznych wielokątów (audyt testów spec. 4: prawo kontaktu przeliczone): krawędź odpycha bańkę tylko od
/// zewnątrz, a wypukły wierzchołek raz, więc cienka ściana ugina się o r · ε (ε / (1 − ε)² = F / K_c) tak samo jak gruba, a wynik nie
/// zależy od obiegu wierzchołków. Sceny mają własny świat bez ram `CrowdScene` (jej pomocniki znają tylko ściany lewą i prawą grubości 48),
/// a siła w każdej ramce idzie przez `world.submit(…setMotorDrive…)` przed każdym `advance`, jak w `MotionDampingTests`.
/// Materiał baniek: K_c = 1852 (r_ref / c₀ dawnego modelu), opór γ = 5 (spoczynek wymaga oporu), krok stały 1/60.
@MainActor
final class StaticPolygonEdgeTests: XCTestCase {
    private let dt = CrowdScene.step
    private let stiffness: Float = 20 / 0.0108

    private func id(_ value: UInt64) -> ObjectID { CrowdScene.id(value) }

    /// Ugięcie r · ε z prawa kontaktu ε / (1 − ε)² = F / K_c (odniesienie w Double).
    private func deflection(_ radius: Float, force: Float) -> Float {
        radius * Float(ContactLawReference.epsilon(forForceRatio: Double(force) / Double(stiffness)))
    }

    private func material(damping: Float = 5) throws -> PhysicsMaterial {
        try PhysicsMaterial(kind: .bubble, contactStiffness: stiffness, damping: damping)
    }

    // MARK: sceny

    /// Świat o obszarze ±`extent` z podanymi statycznymi wielokątami (identyfikatory ścian 9 001, 9 002, …), po kroku przyjmującym scenę.
    /// `reversed` odwraca kolejność wierzchołków każdego wielokąta.
    private func world(extent: Float, bubble: PhysicsMaterial, polygons: [[WorldPoint]], reversed: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line,
                       _ build: (WorldTransaction) throws -> WorldTransaction) async throws -> BubbleWorld {
        let world = try BubbleWorld(configuration: WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-extent, -extent], max: [extent, extent]),
            fixedTimeStep: dt, eventBufferCapacity: 4096))
        var setup = try CrowdScene.resources(bubble: bubble)
        for (index, vertices) in polygons.enumerated() {
            setup = setup.add(.rigidBody(try RigidBodyDescriptor(id: ObjectID(rawValue: 9_001 + UInt64(index)),
                vertices: reversed ? vertices.reversed() : vertices, motionRole: .static,
                physicsMaterialID: CrowdScene.wallMaterial, renderMaterialID: CrowdScene.style)))
        }
        let token = world.submit(try build(setup))
        let frame = await world.advance(by: dt)
        XCTAssertNil(world.diagnostics.lastAdvanceIssue, "przygotowanie sceny", file: file, line: line)
        XCTAssertTrue(frame.transactionReceipts.contains { $0.token == token }, "przygotowanie sceny musi zostać przyjęte", file: file, line: line)
        return world
    }

    private func advance(_ world: BubbleWorld, file: StaticString = #filePath, line: UInt = #line) async throws -> WorldFrame {
        let frame = await world.advance(by: dt)
        XCTAssertNil(world.diagnostics.lastAdvanceIssue, String(describing: world.diagnostics.lastRejectionReason), file: file, line: line)
        return frame
    }

    /// Prostokąt-ściana z czołem w x = `faceX` (ściana po lewej od czoła), grubością `thickness` i y od `yMin` do `yMax`; obieg przeciwny do
    /// ruchu wskazówek zegara.
    private func rectangle(faceX: Float, thickness: Float, yMin: Float = -400, yMax: Float = 400) -> [WorldPoint] {
        [[faceX - thickness, yMin], [faceX, yMin], [faceX, yMax], [faceX - thickness, yMax]]
    }

    private func force(_ vector: WorldPoint) throws -> WorldTransaction {
        WorldTransaction().setMotorDrive(id(1), drive: try MotorDrive(force: vector))
    }

    // MARK: ugięcie przy ścianie (P-B-18, P-B-23)

    /// Ugięcie czoła po `steps` krokach: r − (x − faceX); rozrzut w ostatnich 60 krokach.
    private func settleAgainstFace(_ world: BubbleWorld, radius: Float, faceX: Float, steps: Int,
                                   file: StaticString = #filePath, line: UInt = #line) async throws -> (deflection: Float, spread: Float, position: WorldPoint) {
        var tail: [Float] = []
        var position = WorldPoint.zero
        for index in 0..<steps {
            let frame = try await advance(world, file: file, line: line)
            position = try XCTUnwrap(frame.objects[id(1)], file: file, line: line).position
            if index >= steps - 60 { tail.append(radius - (position.x - faceX)) }
        }
        return (tail.last ?? 0, (tail.max() ?? 0) - (tail.min() ?? 0), position)
    }

    /// Bańka r 148 (m 1, γ 5: przy m ≈ 55 z `CrowdScene` osiada w minutę) dociśnięta do środka długiej krawędzi ściany T 48 albo T 400:
    /// ugięcie r · ε dla pięciu sił, w tym dwóch z ugięciem większym niż T (F = 1500 daje 52, F = 2500 daje 77), i równe w obu grubościach.
    /// Dwustronne krawędzie dawały drugą sprężynę od tyłu.
    func testThinWallDeflectsByTheFrontEdgeOnlyAndTheSameAsAThickWall() async throws {
        let radius: Float = 148, faceX: Float = -100
        for pressure: Float in [300, 700, 1100, 1500, 2500] {
            let expected = deflection(radius, force: pressure)
            var deflections: [Float] = []
            for thickness: Float in [48, 400] {
                let world = try await world(extent: 1000, bubble: material(),
                                            polygons: [rectangle(faceX: faceX, thickness: thickness)]) {
                    try $0.add(CrowdScene.bubble(1, at: [faceX + radius, 0], radius: radius, mass: 1))
                        .setMotorDrive(id(1), drive: MotorDrive(force: [-pressure, 0]))
                }
                let rest = try await settleAgainstFace(world, radius: radius, faceX: faceX, steps: 1200)
                XCTAssertEqual(rest.deflection, expected, accuracy: 0.02 * expected,
                               "F = \(pressure), T = \(thickness): ugięcie \(rest.deflection), oczekiwane r · ε = \(expected)")
                XCTAssertLessThan(rest.spread, 0.005 * expected, "F = \(pressure), T = \(thickness): ugięcie ma być uspokojone")
                deflections.append(rest.deflection)
            }
            XCTAssertEqual(deflections[0], deflections[1], accuracy: 0.02 * expected,
                           "F = \(pressure): ściana T 48 daje \(deflections[0]), T 400 daje \(deflections[1])")
        }
    }

    /// Długa krawędź podana jako dwa współliniowe odcinki po 400: bańka dociśnięta dokładnie nad dodatkowym wierzchołkiem ugina się o c · F,
    /// a jej położenie zgadza się z tą samą sceną z krawędzią jako jednym odcinkiem (1e-2).
    func testCollinearVertexDoesNotChangeTheContact() async throws {
        let radius: Float = 24, faceX: Float = -100, pressure: Float = 600
        let expected = deflection(radius, force: pressure)
        let twoSegments: [WorldPoint] = [[faceX - 48, -400], [faceX, -400], [faceX, 0], [faceX, 400], [faceX - 48, 400]]
        var results: [(deflection: Float, spread: Float, position: WorldPoint)] = []
        for polygon in [twoSegments, rectangle(faceX: faceX, thickness: 48)] {
            let world = try await world(extent: 1000, bubble: material(), polygons: [polygon]) {
                try $0.add(CrowdScene.bubble(1, at: [faceX + radius, 0], radius: radius, mass: 1.36))
                    .setMotorDrive(id(1), drive: MotorDrive(force: [-pressure, 0]))
            }
            results.append(try await settleAgainstFace(world, radius: radius, faceX: faceX, steps: 600))
        }
        XCTAssertEqual(results[0].deflection, expected, accuracy: 0.02 * expected, "dwa odcinki: ugięcie \(results[0].deflection), oczekiwane r · ε = \(expected)")
        XCTAssertEqual(results[1].deflection, expected, accuracy: 0.02 * expected, "jeden odcinek: ugięcie \(results[1].deflection), oczekiwane r · ε = \(expected)")
        XCTAssertLessThan(results[0].spread, 0.005 * expected)
        XCTAssertEqual(results[0].position.x, results[1].position.x, accuracy: 1e-2, "położenie x")
        XCTAssertEqual(results[0].position.y, results[1].position.y, accuracy: 1e-2, "położenie y")
    }

    // MARK: wypukły wierzchołek (P-B-19, P-B-22)

    private static let apexAngles: [Float] = [30, 90, 120]

    /// Trójkąt równoramienny o wierzchołku V = (0, 0) skierowanym w −x, kącie wewnętrznym `degrees` i ramionach długości 300.
    /// Obieg zgodny z ruchem wskazówek zegara: V → górne ramię → dolne ramię.
    private func wedge(degrees: Float) -> [WorldPoint] {
        let half = degrees * .pi / 360, length: Float = 300
        return [[0, 0], [length * cos(half), length * sin(half)], [length * cos(half), -length * sin(half)]]
    }

    /// Odległość punktu od odcinka.
    private func distance(_ point: WorldPoint, toSegment a: WorldPoint, _ b: WorldPoint) -> Float {
        let edge = b - a, along = simd_dot(point - a, edge) / max(simd_dot(edge, edge), .leastNormalMagnitude)
        return simd_distance(point, a + min(max(along, 0), 1) * edge)
    }

    /// Najbliższy punkt brzegu wielokąta.
    private func nearestPoint(_ point: WorldPoint, on polygon: [WorldPoint]) -> WorldPoint {
        var best = polygon[0], bestDistance = Float.infinity
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            let edge = b - a, along = simd_dot(point - a, edge) / max(simd_dot(edge, edge), .leastNormalMagnitude)
            let candidate = a + min(max(along, 0), 1) * edge
            if simd_distance(point, candidate) < bestDistance { bestDistance = simd_distance(point, candidate); best = candidate }
        }
        return best
    }

    private func unit(_ vector: WorldPoint) -> WorldPoint { vector / max(simd_length(vector), .leastNormalMagnitude) }

    /// Bańka r 24 (m 1,36) w obszarze wierzchołka, dociskana siłą 600 ustawianą w każdej ramce od środka do wierzchołka: po uspokojeniu odległość
    /// od wierzchołka to r − r · ε. Podwójny kontakt dałby mniejsze ugięcie.
    func testConvexVertexIsOneSpringForEveryAngle() async throws {
        let radius: Float = 24, pressure: Float = 600
        let expected = deflection(radius, force: pressure)
        for degrees in Self.apexAngles {
            let apex: WorldPoint = .zero
            let world = try await world(extent: 1000, bubble: material(), polygons: [wedge(degrees: degrees)]) {
                try $0.add(CrowdScene.bubble(1, at: [-radius, 0], radius: radius, mass: 1.36))
            }
            var position = WorldPoint(-radius, 0)
            var tail: [Float] = []
            for index in 0..<420 {
                _ = world.submit(try force(unit(apex - position) * pressure))
                let frame = try await advance(world)
                position = try XCTUnwrap(frame.objects[id(1)]).position
                if index >= 360 { tail.append(radius - simd_distance(position, apex)) }
            }
            let deflection = try XCTUnwrap(tail.last)
            XCTAssertEqual(deflection, expected, accuracy: 0.02 * expected,
                           "\(degrees)°: odległość od wierzchołka \(radius - deflection), oczekiwana r − r · ε = \(radius - expected)")
            XCTAssertLessThan((tail.max() ?? 0) - (tail.min() ?? 0), 0.005 * expected, "\(degrees)°: ugięcie ma być uspokojone")
        }
    }

    /// Bańka r 24 (m 1,36, γ 4, tarcie 0) zsuwa się po brzegu przez wypukły wierzchołek: siła to 600 do najbliższego punktu wielokąta plus 30
    /// w kierunku stycznym, stale w jedną stronę, aż środek znajdzie się 40 jednostek za wierzchołkiem. W każdej ramce przejścia odległość
    /// środka od brzegu różni się od r − r · ε o najwyżej 10 % r · ε. Oba kierunki, czyli oba ramiona jako krawędź początkowa.
    func testSlideThroughAConvexVertexKeepsTheDistanceFromTheEdge() async throws {
        let radius: Float = 24, pressure: Float = 600, tangential: Float = 30
        let expected = deflection(radius, force: pressure)
        for degrees in Self.apexAngles {
            for side: Float in [1, -1] {
                let polygon = wedge(degrees: degrees)
                let half = degrees * .pi / 360
                let start = WorldPoint(cos(half), side * sin(half))   // wersor ramienia, na którym bańka startuje
                let finish = WorldPoint(cos(half), -side * sin(half)) // wersor ramienia, na które przechodzi
                let outward = WorldPoint(-sin(half), side * cos(half)) // normalna zewnętrzna ramienia startowego
                let name = "\(degrees)°, ramię \(side > 0 ? "górne" : "dolne")"
                let first = 40 * start + (radius - expected) * outward
                // Kierunek styczny to wersor do najbliższego punktu obrócony o 90°, ze znakiem ustalonym raz: na początku wskazuje wierzchołek.
                let initialToward = unit(nearestPoint(first, on: polygon) - first)
                let sense: Float = simd_dot(WorldPoint(-initialToward.y, initialToward.x), -start) >= 0 ? 1 : -1
                let world = try await world(extent: 1000, bubble: material(damping: 4), polygons: [polygon]) {
                    try $0.add(CrowdScene.bubble(1, at: first, radius: radius, mass: 1.36))
                }
                func push(_ position: WorldPoint, slide: Bool) throws -> WorldTransaction {
                    let toward = unit(nearestPoint(position, on: polygon) - position)
                    let perpendicular = WorldPoint(-toward.y, toward.x)
                    return try force(toward * pressure + (slide ? sense * perpendicular * tangential : .zero))
                }
                var position = first
                // Uspokojony docisk przed zsuwaniem.
                for _ in 0..<240 {
                    _ = world.submit(try push(position, slide: false))
                    let frame = try await advance(world)
                    position = try XCTUnwrap(frame.objects[id(1)]).position
                }
                var worst: (error: Float, frame: Int) = (0, 0)
                var reached = false
                for index in 0..<1500 {
                    _ = world.submit(try push(position, slide: true))
                    let frame = try await advance(world)
                    position = try XCTUnwrap(frame.objects[id(1)]).position
                    let error = abs(simd_distance(position, nearestPoint(position, on: polygon)) - (radius - expected))
                    if error > worst.error { worst = (error, index) }
                    if simd_dot(position, finish) >= 40 { reached = true; break }
                }
                XCTAssertTrue(reached, "\(name): bańka nie przeszła za wierzchołek w 1 500 krokach")
                XCTAssertLessThanOrEqual(worst.error, 0.1 * expected,
                                         "\(name): największe odchylenie odległości od r − r · ε to \(worst.error) w kroku \(worst.frame), dopuszczalne \(0.1 * expected)")
            }
        }
    }

    // MARK: obieg wierzchołków i szybka bańka (P-B-20, P-B-21)

    /// Cztery bańki r 24 (m 1,36, γ 2, tarcie 0) pchane siłą 600: na ścianę T 400, na ścianę T 48, na wypukły narożnik ściany T 48 pod kątem
    /// 30° do dwusiecznej (zsuwa się po długiej ścianie) i wzdłuż dwusiecznej w wewnętrzny narożnik litery L. Dwa światy różnią się
    /// tylko kolejnością wierzchołków; położenia w każdej z 600 ramek zgadzają się z tolerancją 1e-2.
    func testWindingOfTheVerticesDoesNotChangeTheTrajectories() async throws {
        let radius: Float = 24, pressure: Float = 600
        let thick = WorldPoint(-1200, 1200), thin = WorldPoint(1200, 1200), corner = WorldPoint(-1200, -1200), inner = WorldPoint(1200, -1200)
        let arm: Float = 400, width: Float = 48
        let polygons: [[WorldPoint]] = [
            rectangle(faceX: thick.x, thickness: 400, yMin: thick.y - 400, yMax: thick.y + 400),
            rectangle(faceX: thin.x, thickness: 48, yMin: thin.y - 400, yMax: thin.y + 400),
            rectangle(faceX: corner.x, thickness: 48, yMin: corner.y - 800, yMax: corner.y),
            [[0, 0], [arm, 0], [arm, width], [width, width], [width, arm], [0, arm]].map { $0 + inner - WorldPoint(width, width) }]
        let bisector = WorldPoint(1, 1) / Float(2).squareRoot()
        // Kierunek siły trzeciej bańki: 30° od dwusiecznej narożnika (225°) ku długiej ścianie, czyli 15° od normalnej jej czoła. Bańka
        // startuje 50 jednostek od narożnika na prostej siły, więc trafia w sam wierzchołek i stacza się na czoło długiej ściany.
        let angle: Float = 195 * .pi / 180, aim = WorldPoint(cos(angle), sin(angle))
        let pushes: [(start: WorldPoint, force: WorldPoint)] = [
            (thick + [radius, 0], [-pressure, 0]),
            (thin + [radius, 0], [-pressure, 0]),
            (corner - aim * 50, aim * pressure),
            (inner + bisector * 100, -bisector * pressure)]
        var worlds: [BubbleWorld] = []
        for reversed in [false, true] {
            worlds.append(try await world(extent: 2500, bubble: material(damping: 2), polygons: polygons, reversed: reversed) { setup in
                try pushes.enumerated().reduce(setup) { transaction, push in
                    let value = UInt64(push.offset + 1)
                    return transaction.add(try CrowdScene.bubble(value, at: push.element.start, radius: radius, mass: 1.36))
                        .setMotorDrive(id(value), drive: try MotorDrive(force: push.element.force))
                }
            })
        }
        var worst: (error: Float, bubble: Int, frame: Int) = (0, 0, 0)
        var slid = WorldPoint.zero
        for index in 0..<600 {
            let frames = [try await advance(worlds[0]), try await advance(worlds[1])]
            for bubble in 1...4 {
                let positions = try frames.map { try XCTUnwrap($0.objects[id(UInt64(bubble))]).position }
                let error = simd_distance(positions[0], positions[1])
                if error > worst.error { worst = (error, bubble, index) }
                if bubble == 3 { slid = positions[0] }
            }
        }
        XCTAssertLessThanOrEqual(worst.error, 1e-2, "obieg wierzchołków zmienił trajektorię bańki \(worst.bubble) w ramce \(worst.frame) o \(worst.error)")
        // Bańka 3 zsuwa się po ścianie: przejechała znaczną część długości, nie została na narożniku.
        XCTAssertLessThan(slid.y, corner.y - 300, "bańka 3 powinna zsunąć się po długiej ścianie, jest w \(slid)")
    }

    /// Bańka r 12 z prędkością 6 000 (100 jednostek na krok, więcej niż 2r + T = 72) prostopadle i pod kątem 30° na środek ściany T 48:
    /// żaden krok nie kończy się ze środkiem przebitym w głąb ściany ani za nią, żaden nie jest odrzucony. Od 3.0.2 (BF-D-5) krawędź
    /// wejścia odpycha liniowo także dla ε > 1, więc bańka wyhamowana przez CCD do ok. 270 j/s wgniata się przy uderzeniu na chwilę
    /// środkiem za czoło (probe: 0,2, czyli ε ≈ 1,02); dopuszczalne jest najwyżej r / 10 (ε ≤ 1,1).
    func testFastBubbleNeverEndsAStepInsideOrBehindTheWall() async throws {
        let radius: Float = 12, speed: Float = 6000
        for degrees: Float in [0, 30] {
            let heading = degrees * .pi / 180
            let velocity = WorldPoint(-cos(heading), sin(heading)) * speed
            let world = try await world(extent: 2500, bubble: material(),
                                        polygons: [rectangle(faceX: 0, thickness: 48)]) {
                try $0.add(CrowdScene.bubble(1, at: [200, 0], radius: radius, velocity: velocity))
            }
            for index in 0..<40 {
                let frame = try await advance(world)
                let position = try XCTUnwrap(frame.objects[id(1)]).position
                if abs(position.y) <= 400 {
                    XCTAssertGreaterThanOrEqual(position.x, -radius / 10, "\(degrees)°, krok \(index): środek w ścianie albo za nią: \(position)")
                }
            }
        }
    }

    /// Bańka r 12 (m 0,36, γ 5) z prędkością (1 200, −1 800) wchodzi skosem w cienką ścianę T 48 (x od −148 do −100, y do 400) nad jej
    /// tylnym górnym narożnikiem wypukłym i mija go o kilka jednostek nad krawędzią górną. Ściana jest jednostronna: odpycha od zewnątrz
    /// siłą z prawa kontaktu wzdłuż normalnej wierzchołka i krawędzi górnej, a tylna krawędź nie wciąga bańki w lewo, za ścianę. Żaden krok
    /// nie kończy się ze środkiem w ścianie, bańka odbija się w górę (vy zmienia znak), jej x rośnie w każdym kroku, a prędkość x zostaje
    /// bliska tej z oporu (1 200 · e^(−γ t)): zderzenie z wierzchołkiem odejmuje jej najwyżej 12 %, a tylna krawędź odjęłaby ją całą.
    func testObliqueEntryAcrossAConvexCornerIsPushedOutByTheCrossedEdgeOnly() async throws {
        let radius: Float = 12, velocity = WorldPoint(1200, -1800), damping: Float = 5
        let world = try await world(extent: 2500, bubble: material(damping: damping),
                                    polygons: [rectangle(faceX: -100, thickness: 48)]) {
            try $0.add(CrowdScene.bubble(1, at: [-220, 510], radius: radius, velocity: velocity))
        }
        var previousX = -Float.infinity, bounced = false
        for index in 0..<6 {
            let frame = try await advance(world)
            let state = try XCTUnwrap(frame.objects[id(1)])
            let position = state.position
            XCTAssertFalse(position.x > -148 && position.x < -100 && position.y < 400, "krok \(index): środek w ścianie: \(position)")
            XCTAssertGreaterThan(position.x, previousX, "krok \(index): tylna krawędź cofnęła bańkę: \(position)")
            previousX = position.x
            if state.velocity.y > 0 { bounced = true }
            // Do kroku `index` minęło index + 2 kroków (krok przyjęcia sceny to pierwszy).
            let dragged = velocity.x * exp(-damping * Float(CrowdScene.step) * Float(index + 2))
            XCTAssertGreaterThan(state.velocity.x, 0.88 * dragged, "krok \(index): prędkość x \(state.velocity.x), z oporu \(dragged)")
        }
        XCTAssertTrue(bounced, "bańka odbiła się od ściany")
    }
}
