import BubblePhysics
import BubblePhysicsMetalRender
import Metal
import XCTest
import simd

/// P-B-24..P-B-26, P-B-66..P-B-68 (G11-AC3): więzy w świecie GPU. Fizyka jest deterministyczna, więc progi to
/// tolerancje z kryteriów, a nie szum pomiarowy.
@MainActor
final class JointWorldTests: XCTestCase {
    private typealias B = SceneBuilders
    private let g: Float = 400

    private func makeWorld(gravity: WorldPoint = .zero, region: WorldRectangle? = nil) throws -> BubbleWorld {
        try B.makeWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()),
                        region: region ?? WorldRectangle(min: [-1000, -1000], max: [2000, 2000]), gravity: gravity)
    }

    private func state(_ frame: WorldFrame, _ id: UInt64) throws -> ObjectState {
        try XCTUnwrap(frame.objects[ObjectID(rawValue: id)], "brak obiektu \(id)")
    }

    private func healthy(_ world: BubbleWorld, _ context: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(world.diagnostics.lastAdvanceIssue, "\(context): klatka nie może się nie udać", file: file, line: line)
    }

    // MARK: Dystans

    // P-B-24: wahadło na więzie dystansowym ze światem; okres w granicach 2% wzoru T = 2π·sqrt(L/g).
    func testPendulumPeriodMatchesFormulaWithinTwoPercent() async throws {
        let world = try makeWorld(gravity: [0, -g])
        let pivot = WorldPoint(300, 400), length: Float = 100, theta: Float = 0.1
        let start = pivot + WorldPoint(length * sin(theta), -length * cos(theta))
        world.submit(try B.baseTransaction()
            .add(B.circle(1, at: start, radius: 5))
            .addJoint(B.distanceJoint(1, 1, nil, anchorB: pivot, length: length)))
        var crossings: [Double] = []
        var previous: Float?
        _ = await B.advance(world, steps: 420) { _, frame in
            guard let bob = frame.objects[ObjectID(rawValue: 1)] else { return }
            let x = bob.position.x - pivot.x
            if let previous, previous < 0, x >= 0 { crossings.append(frame.simulationTime - Double(x / max(bob.velocity.x, 1e-3)) / 60) }
            previous = x
        }
        healthy(world, "wahadło")
        guard crossings.count >= 2 else { return XCTFail("co najmniej dwa kolejne przejścia przez dół w tym samym kierunku") }
        let period = crossings[1] - crossings[0]
        let expected = 2 * Double.pi * Double(sqrt(length / g))
        XCTAssertEqual(period, expected, accuracy: expected * 0.02)
    }

    // P-B-68: sztywny dystans trzyma długość w granicach 1% także przy dużym wychyleniu.
    func testRigidDistanceKeepsLengthWithinOnePercent() async throws {
        let world = try makeWorld(gravity: [0, -g])
        let pivot = WorldPoint(300, 400), length: Float = 100
        world.submit(try B.baseTransaction()
            .add(B.circle(1, at: pivot + [length, 0], radius: 5))
            .addJoint(B.distanceJoint(1, 1, nil, anchorB: pivot, length: length)))
        var worst: Float = 0
        _ = await B.advance(world, steps: 240) { _, frame in
            guard let bob = frame.objects[ObjectID(rawValue: 1)] else { return }
            worst = max(worst, abs(simd_distance(bob.position, pivot) - length))
        }
        healthy(world, "sztywny dystans")
        XCTAssertLessThanOrEqual(worst, length * 0.01)
    }

    // P-B-68: więz wiotki i tłumiony, rozciągnięty i puszczony: oscyluje wokół długości spoczynkowej, amplituda maleje.
    func testSoftDampedDistanceOscillatesAroundRestLengthAndDecays() async throws {
        let world = try makeWorld()
        let pivot = WorldPoint(300, 400), length: Float = 100
        world.submit(try B.baseTransaction()
            .add(B.circle(1, at: pivot + [130, 0], radius: 5))
            .addJoint(B.distanceJoint(1, 1, nil, anchorB: pivot, length: length, softness: 0.01, damping: 2)))
        var distances: [Float] = []
        _ = await B.advance(world, steps: 150) { _, frame in
            guard let bob = frame.objects[ObjectID(rawValue: 1)] else { return }
            distances.append(simd_distance(bob.position, pivot))
        }
        healthy(world, "więz wiotki")
        guard distances.count == 150 else { return XCTFail("zabrakło klatek: \(distances.count)") }
        let early = distances[0..<45].map { abs($0 - length) }.max() ?? 0
        let late = distances[105...].map { abs($0 - length) }.max() ?? 0
        XCTAssertGreaterThan(early, 15, "w pierwszym okresie rozciągnięcie jest widoczne")
        XCTAssertTrue(distances.contains { $0 < length - 3 }, "przechodzi przez długość spoczynkową na drugą stronę")
        XCTAssertLessThan(late, early * 0.5, "amplituda maleje")
        XCTAssertGreaterThan(distances.max() ?? 0, length + 15)
    }

    // MARK: Zawias i spaw

    // P-B-24: zawias z zakresem kąta; ramię opada pod grawitacją i zatrzymuje się na dolnej granicy.
    func testHingeLimitsKeepAngleWithinRange() async throws {
        let world = try makeWorld(gravity: [0, -g])
        let pivot = WorldPoint(200, 300)
        let limits = try HingeLimits(lower: -0.5, upper: 0.5)
        world.submit(try B.baseTransaction()
            .add(B.box(1, at: pivot + [20, 0], half: [20, 2], role: .dynamic))
            .addJoint(B.hingeJoint(1, 1, nil, anchorA: [-20, 0], anchorB: pivot, limits: limits)))
        var lowest: Float = 0, highest: Float = 0
        let result = await B.advance(world, steps: 240) { _, frame in
            guard let arm = frame.objects[ObjectID(rawValue: 1)] else { return }
            lowest = min(lowest, arm.rotation); highest = max(highest, arm.rotation)
        }
        healthy(world, "zawias z zakresem")
        XCTAssertGreaterThanOrEqual(lowest, -0.5 - 0.05, "kąt nie schodzi poniżej dolnej granicy")
        XCTAssertLessThanOrEqual(highest, 0.5 + 0.05)
        XCTAssertLessThanOrEqual(try state(result.frame, 1).rotation, -0.45, "ramię opadło do granicy")
        // Zaczep zostaje w punkcie obrotu.
        let arm = try state(result.frame, 1)
        let anchor = arm.position + WorldPoint(-20 * cos(arm.rotation), -20 * sin(arm.rotation))
        XCTAssertLessThan(simd_distance(anchor, pivot), 1.0)
    }

    // P-B-24: silnik zawiasu bez obciążenia osiąga prędkość względną w granicach 5% celu.
    func testHingeMotorWithoutLoadReachesTargetVelocity() async throws {
        let world = try makeWorld()
        let pivot = WorldPoint(200, 300)
        world.submit(try B.baseTransaction()
            .add(B.box(1, at: pivot, half: [20, 4], role: .dynamic))
            .addJoint(B.hingeJoint(1, 1, nil, anchorA: .zero, anchorB: pivot,
                motor: HingeMotor(targetAngularVelocity: 2, maximumTorque: 100_000))))
        let result = await B.advance(world, steps: 90)
        healthy(world, "silnik bez obciążenia")
        XCTAssertEqual(try state(result.frame, 1).angularVelocity, 2, accuracy: 0.1)
    }

    // P-B-24: prędkość silnika to prędkość B względem A, więc kolejność końców decyduje o kierunku obrotu ciała ruchomego.
    func testHingeMotorDrivesSecondBodyRelativeToFirst() async throws {
        func spin(movableIsFirst: Bool) async throws -> Float {
            let world = try makeWorld()
            let pivot = WorldPoint(200, 300)
            let motor = try HingeMotor(targetAngularVelocity: 2, maximumTorque: 100_000)
            world.submit(try B.baseTransaction()
                .add(B.box(1, at: pivot, half: [30, 30], role: .static))
                .add(B.box(2, at: pivot, half: [20, 4], role: .dynamic))
                .addJoint(B.hingeJoint(1, movableIsFirst ? 2 : 1, movableIsFirst ? 1 : 2, motor: motor)))
            let result = await B.advance(world, steps: 60)
            healthy(world, "silnik między ciałami")
            return try state(result.frame, 2).angularVelocity
        }
        let asSecond = try await spin(movableIsFirst: false)
        let asFirst = try await spin(movableIsFirst: true)
        XCTAssertEqual(asSecond, 2, accuracy: 0.1, "ciało ruchome jako B obraca się z prędkością docelową")
        XCTAssertEqual(asFirst, -2, accuracy: 0.1, "ciało ruchome jako A obraca się przeciwnie")
    }

    // P-B-24: z obciążeniem ponad maksymalny moment silnik nie osiąga celu; z mocniejszym silnikiem osiąga.
    func testHingeMotorUnderLoadBeyondMaximumTorqueCannotReachTarget() async throws {
        func finalVelocity(maximumTorque: Float) async throws -> Float {
            let world = try makeWorld(gravity: [0, -g])
            let pivot = WorldPoint(200, 300)
            // Ramię o masie 1 i połowie długości 30: moment grawitacji m·g·30 = 12000.
            world.submit(try B.baseTransaction()
                .add(B.box(1, at: pivot + [30, 0], half: [30, 2], role: .dynamic))
                .addJoint(B.hingeJoint(1, 1, nil, anchorA: [-30, 0], anchorB: pivot,
                    motor: HingeMotor(targetAngularVelocity: 1, maximumTorque: maximumTorque))))
            let result = await B.advance(world, steps: 60)
            healthy(world, "silnik pod obciążeniem")
            return try state(result.frame, 1).angularVelocity
        }
        let weak = try await finalVelocity(maximumTorque: 6_000)
        XCTAssertLessThan(weak, 0.5, "moment silnika poniżej momentu grawitacji: ramię opada, cel nieosiągnięty")
        let strong = try await finalVelocity(maximumTorque: 30_000)
        XCTAssertEqual(strong, 1, accuracy: 0.05, "silnik silniejszy niż obciążenie osiąga cel")
    }

    // P-B-24: spaw trzyma względną pozę dwóch brył (położenie i kąt) mimo obrotu i grawitacji.
    func testWeldKeepsRelativePose() async throws {
        // Region szeroki w dół: para spada przez 3 s i przy domyślnym regionie wypadałaby z niego tuż przed końcem testu.
        let world = try makeWorld(gravity: [0, -g], region: WorldRectangle(min: [-5000, -5000], max: [5000, 5000]))
        world.submit(try B.baseTransaction()
            .add(B.box(1, at: [200, 300], half: [20, 5], role: .dynamic))
            .add(B.box(2, at: [240, 300], half: [20, 5], role: .dynamic))
            .addJoint(B.weldJoint(1, 1, 2, anchorA: [20, 0], anchorB: [-20, 0])))
        // Impuls w górę na ciele 2 skręca parę wokół środka masy i obraca ją względem świata.
        world.submit(WorldTransaction().applyImpulse(to: ObjectID(rawValue: 2), impulse: [0, 150]))
        var worstOffset: Float = 0, worstAngle: Float = 0
        let result = await B.advance(world, steps: 180) { _, frame in
            guard let a = frame.objects[ObjectID(rawValue: 1)], let b = frame.objects[ObjectID(rawValue: 2)] else { return }
            let c = cos(-a.rotation), s = sin(-a.rotation)
            let delta = b.position - a.position
            let local = WorldPoint(delta.x * c - delta.y * s, delta.x * s + delta.y * c)
            worstOffset = max(worstOffset, simd_distance(local, [40, 0]))
            worstAngle = max(worstAngle, abs(b.rotation - a.rotation))
        }
        healthy(world, "spaw")
        XCTAssertLessThanOrEqual(worstOffset, 0.8, "położenie względne")
        XCTAssertLessThanOrEqual(worstAngle, 0.03, "kąt względny")
        XCTAssertGreaterThan(abs(try state(result.frame, 1).rotation), 0.05, "para rzeczywiście się obróciła")
    }

    // MARK: Bańki na więzie dystansowym

    // P-B-25: bańka na więzie ze światem, z bryłą i z inną bańką: odległość środka w granicach 1%,
    // a kształt konturu nie zmienia się od korekty więzu.
    func testBubbleOnDistanceJointHoldsLengthAndKeepsContour() async throws {
        let world = try makeWorld(gravity: [0, -g])
        let pivot = WorldPoint(300, 500)
        world.submit(try B.baseTransaction()
            .add(B.bubble(1, at: pivot + [60, 0], radius: 8))
            .addJoint(B.distanceJoint(1, 1, nil, anchorB: pivot, length: 60))
            .add(B.circle(2, at: [600, 500], radius: 8))
            .add(B.bubble(3, at: [650, 500], radius: 8, velocity: [0, 40]))
            .addJoint(B.distanceJoint(2, 3, 2, length: 50))
            .add(B.bubble(4, at: [900, 500], radius: 8))
            .add(B.bubble(5, at: [940, 500], radius: 8, velocity: [30, 30]))
            .addJoint(B.distanceJoint(3, 4, 5, length: 40)))
        var worst: [Float] = [0, 0, 0], widths: [[Float]] = [[], [], []]
        _ = await B.advance(world, steps: 180) { _, frame in
            guard let b1 = frame.objects[ObjectID(rawValue: 1)], let c2 = frame.objects[ObjectID(rawValue: 2)],
                  let b3 = frame.objects[ObjectID(rawValue: 3)], let b4 = frame.objects[ObjectID(rawValue: 4)],
                  let b5 = frame.objects[ObjectID(rawValue: 5)] else { return }
            worst[0] = max(worst[0], abs(simd_distance(b1.position, pivot) - 60) / 60)
            worst[1] = max(worst[1], abs(simd_distance(b3.position, c2.position) - 50) / 50)
            worst[2] = max(worst[2], abs(simd_distance(b4.position, b5.position) - 40) / 40)
            widths[0].append(b1.bounds.max.x - b1.bounds.min.x)
            widths[1].append(b3.bounds.max.x - b3.bounds.min.x)
            widths[2].append(b5.bounds.max.x - b5.bounds.min.x)
        }
        healthy(world, "bańki na więzie")
        XCTAssertLessThanOrEqual(worst[0], 0.01, "bańka–świat")
        XCTAssertLessThanOrEqual(worst[1], 0.01, "bańka–bryła")
        XCTAssertLessThanOrEqual(worst[2], 0.01, "bańka–bańka")
        for series in widths {
            let spread = (series.max() ?? 0) - (series.min() ?? 0)
            XCTAssertLessThan(spread, 0.5, "kontur bańki nie zmienia się od więzu")
        }
    }

    // MARK: Kolizje ciał połączonych

    // P-B-66: nakładające się ciała połączone więzem domyślnie nie kolidują; z `collideConnected` się rozpychają.
    func testConnectedBodiesDoNotCollideUnlessEnabled() async throws {
        func run(collide: Bool) async throws -> (hinge: Float, mixed: Float, bubbles: Float, events: Int, hingeEvents: Int, hingeTurn: Float) {
            let world = try makeWorld()
            world.submit(try B.baseTransaction()
                // Dwie bryły na zawiasie.
                .add(B.box(1, at: [200, 200], half: [20, 20], role: .dynamic, interest: .contact))
                .add(B.box(2, at: [220, 200], half: [20, 20], role: .dynamic))
                .addJoint(B.hingeJoint(1, 1, 2, anchorA: [10, 0], anchorB: [-10, 0], collideConnected: collide))
                // Bańka z bryłą.
                .add(B.bubble(3, at: [500, 200], radius: 8))
                .add(B.circle(4, at: [505, 200], radius: 10))
                .addJoint(B.distanceJoint(2, 3, 4, length: 5, softness: 0.1, collideConnected: collide))
                // Dwie bańki.
                .add(B.bubble(5, at: [800, 200], radius: 8))
                .add(B.bubble(6, at: [804, 200], radius: 8))
                .addJoint(B.distanceJoint(3, 5, 6, length: 4, softness: 0.1, collideConnected: collide)))
            var events = 0, hingeEvents = 0
            let result = await B.advance(world, steps: 90) { _, frame in
                events += B.began(frame.events).count
                hingeEvents += B.began(frame.events).filter { B.isPair($0.a, $0.b, 1, 2) }.count
            }
            healthy(world, "collideConnected=\(collide)")
            let s = { (id: UInt64) in try self.state(result.frame, id) }
            return (simd_distance(try s(1).position, try s(2).position), simd_distance(try s(3).position, try s(4).position),
                    simd_distance(try s(5).position, try s(6).position), events, hingeEvents,
                    abs(try s(1).rotation) + abs(try s(2).rotation))
        }
        let off = try await run(collide: false)
        XCTAssertEqual(off.hinge, 20, accuracy: 1.5, "zawias: ciała się nie rozpychają")
        XCTAssertEqual(off.mixed, 5, accuracy: 1.0, "bańka–bryła: odległość z więzu")
        XCTAssertEqual(off.bubbles, 4, accuracy: 1.0, "bańka–bańka: odległość z więzu")
        XCTAssertEqual(off.events, 0, "bez kolizji nie ma kontaktu")
        XCTAssertEqual(off.hingeEvents, 0, "zawias bez kolizji: brak kontaktu między ciałami")
        XCTAssertEqual(off.hingeTurn, 0, accuracy: 0.05, "zawias bez kolizji: ciała zostają w miejscu")
        let on = try await run(collide: true)
        XCTAssertGreaterThan(on.mixed, 12, "bańka–bryła rozepchnięte")
        XCTAssertGreaterThan(on.bubbles, 10, "bańka–bańka rozepchnięte")
        XCTAssertGreaterThan(on.events, 0, "z przełącznikiem powstaje kontakt")
        // Kotwice zawiasu leżą w obu bryłach, więc nakładanie nie znika; kontakt między nimi jednak działa i je obraca.
        XCTAssertGreaterThan(on.hingeEvents, 0, "zawias: kontakt rigid–rigid z przełącznikiem")
        XCTAssertGreaterThan(on.hingeTurn, 0.5, "zawias: kontakt rozpycha ciała (obracają się wokół osi)")
        XCTAssertEqual(on.hinge, 20, accuracy: 1.5, "zawias nadal trzyma kotwice")
    }

    // MARK: Determinizm

    // G10-AC5: więzy nie używają redukcji atomowych, więc ta sama scena daje bit w bit ten sam stan.
    func testJointSceneIsBitIdenticalAcrossTwoRuns() async throws {
        func run() async throws -> [UInt32] {
            let world = try makeWorld(gravity: [0, -g])
            let pivot = WorldPoint(300, 500)
            world.submit(try B.baseTransaction()
                .add(B.box(1, at: [200, 300], half: [20, 5], role: .dynamic))
                .add(B.box(2, at: [240, 300], half: [20, 5], role: .dynamic))
                .addJoint(B.weldJoint(1, 1, 2, anchorA: [20, 0], anchorB: [-20, 0]))
                .add(B.circle(3, at: pivot + [80, 0], radius: 6))
                .addJoint(B.distanceJoint(2, 3, nil, anchorB: pivot, length: 80))
                .add(B.bubble(4, at: pivot + [80, -30], radius: 8))
                .addJoint(B.distanceJoint(3, 4, 3, length: 30, softness: 0.02, damping: 1))
                .add(B.box(5, at: [600, 200], half: [30, 3], role: .static))
                .add(B.box(6, at: [600, 230], half: [20, 5], role: .dynamic))
                .addJoint(B.hingeJoint(4, 6, nil, anchorA: [-20, 0], anchorB: [580, 230],
                    motor: HingeMotor(targetAngularVelocity: 1, maximumTorque: 50_000))))
            let result = await B.advance(world, steps: 120)
            healthy(world, "determinizm")
            return result.frame.objects.keys.sorted { $0.rawValue < $1.rawValue }.flatMap { id -> [UInt32] in
                let o = result.frame.objects[id]!
                return [o.position.x, o.position.y, o.velocity.x, o.velocity.y, o.rotation, o.angularVelocity].map(\.bitPattern)
            }
        }
        let first = try await run(), second = try await run()
        XCTAssertEqual(first.count, 36)
        XCTAssertEqual(first, second)
    }

    // MARK: Usuwanie więzów

    // P-B-26: scalenie baniek usuwa ich więzy, wymienia je w potwierdzeniu, a wynik nie dziedziczy więzu.
    func testMergingBubblesRemovesTheirJointsAndResultMovesFreely() async throws {
        let world = try makeWorld()
        let pivot = WorldPoint(300, 300)
        let group = MergeGroupSet(rawValue: 1)
        world.submit(try B.baseTransaction()
            .add(B.bubble(1, at: pivot + [50, 0], radius: 8, velocity: [0, 120], mergeGroups: group))
            .add(B.bubble(2, at: pivot + [50, 16], radius: 8, mergeGroups: group))
            .addJoint(B.distanceJoint(1, 1, nil, anchorB: pivot, length: 50)))
        _ = await B.advance(world, steps: 5)
        world.submit(WorldTransaction().mergeBubbles([ObjectID(rawValue: 1), ObjectID(rawValue: 2)],
            result: BubbleResult(id: ObjectID(rawValue: 9), physicsMaterialID: B.bubbleMaterial, renderStyleID: B.style)))
        var removed: [JointID] = []
        let result = await B.advance(world, steps: 90) { _, frame in
            for receipt in frame.transactionReceipts { removed += receipt.removedJointIDs }
        }
        healthy(world, "scalenie")
        XCTAssertEqual(removed, [JointID(rawValue: 1)])
        let merged = try state(result.frame, 9)
        XCTAssertGreaterThan(simd_distance(merged.position, pivot), 90, "wynik poruszył się swobodnie, bez więzu")
    }

    // P-B-67: bryła z więzem opuszcza region z polityką `remove`: więz znika bez potwierdzenia, partner porusza się swobodnie.
    func testJointDisappearsWhenBodyLeavesRegionAndPartnerMovesFreely() async throws {
        let world = try makeWorld(region: WorldRectangle(min: [0, 0], max: [400, 400]))
        world.submit(try B.baseTransaction()
            .add(B.circle(1, at: [350, 200], radius: 5, velocity: [200, 0], regionExitPolicy: .remove))
            .add(B.circle(2, at: [320, 200], radius: 5))
            // Wiotki więz: sztywny ciągnąłby partnera za odlatującą bryłą i ten też opuściłby region.
            .addJoint(B.distanceJoint(1, 1, 2, length: 30, softness: 1)))
        var gone = false, receiptsAfterExit = 0
        var velocities: [Float] = []
        _ = await B.advance(world, steps: 120) { _, frame in
            if frame.objects[ObjectID(rawValue: 1)] == nil {
                if gone { receiptsAfterExit += frame.transactionReceipts.count }
                gone = true
                if let partner = frame.objects[ObjectID(rawValue: 2)] { velocities.append(partner.velocity.x) }
            }
        }
        healthy(world, "wyjście z regionu")
        XCTAssertTrue(gone, "bryła opuściła region")
        XCTAssertEqual(receiptsAfterExit, 0, "usunięcie po wyjściu z regionu nie jest transakcją")
        XCTAssertGreaterThan(velocities.count, 20)
        let tail = velocities.suffix(20)
        XCTAssertEqual((tail.max() ?? 0) - (tail.min() ?? 0), 0, accuracy: 1e-3, "partner leci swobodnie, nic go nie ciągnie")
    }
}
