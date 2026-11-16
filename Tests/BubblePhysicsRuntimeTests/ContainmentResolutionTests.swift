import BubblePhysics
import simd
import XCTest

/// Bańka w bańce, prawie wspólny środek i scalenie w zajętym miejscu przy kontakcie twardym (P-B-9 – P-B-12, P-B-38):
/// silnik rozsuwa je ograniczoną korekcją (≤ 0,25·r na krok), bez odrzucenia kroku, a gra widzi licznik par.
/// Plansza jest pusta, bez ram; wszystko idzie przez publiczny `BubbleWorld` na urządzeniu Metal.
@MainActor
final class ContainmentResolutionTests: XCTestCase {
    private let material = PhysicsMaterialID(rawValue: 1)
    private let style = RenderMaterialID(rawValue: 1)
    private let step = 1.0 / 60
    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }

    /// `maximumLinearSpeed` = 100 i tłumienie 5: pojedyncza bańka puszczona z prędkością 100 zwalnia poniżej 2 jedn./s
    /// w ciągu 1 s (exp(−5) · 100 ≈ 0,67), co sprawdza `testDampingSlowsAFastBubbleBelowTwoWithinOneSecond`.
    private let damping: Float = 5
    private func world(maximumLinearSpeed: Float? = 100, damping: Float? = nil,
                       contactCompliance: BubbleContactCompliance = .hard) async throws -> BubbleWorld {
        let world = try BubbleWorld(configuration: WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-300, -300], max: [300, 300]), fixedTimeStep: step))
        _ = world.submit(WorldTransaction()
            .updatePhysicsMaterial(material, material: try PhysicsMaterial(kind: .bubble, damping: damping ?? self.damping,
                                                                         maximumLinearSpeed: maximumLinearSpeed,
                                                                         contactCompliance: contactCompliance))
            .updateRenderMaterial(style, material: try RenderMaterial()))
        _ = await world.advance(by: step)
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
        return world
    }
    private func bubble(_ value: UInt64, at position: WorldPoint, radius: Float, velocity: WorldPoint = .zero,
                        mass: Float? = nil) throws -> WorldObject {
        .bubble(try BubbleDescriptor(id: id(value), position: position, velocity: velocity, targetRadius: radius,
                                     mass: mass ?? radius * radius / 400, physicsMaterialID: material, renderMaterialID: style,
                                     eventInterest: [.didAdd]))
    }

    /// Przebieg kroków z rejestrem tego, co każe sprawdzić P-B-9 – P-B-12.
    private struct Run {
        var frames: [WorldFrame] = []
        var counts: [Int] = []
        var rejectedStep: (index: Int, reason: WorldRejectionReason?)?
        var rejectedTransactions: [TransactionRejection] = []
        /// Przesunięcie środka każdej bańki w kroku, od pozycji przed transakcją.
        var displacements: [(step: Int, id: ObjectID, distance: Float)] = []
    }
    private func run(_ world: BubbleWorld, _ transaction: WorldTransaction? = nil, steps: Int,
                     startingAt positions: [ObjectID: WorldPoint]) async -> Run {
        var result = Run()
        var previous = positions
        if let transaction { _ = world.submit(transaction) }
        for index in 0..<steps {
            let frame = await world.advance(by: step)
            let diagnostics = world.diagnostics
            if let issue = diagnostics.lastAdvanceIssue {
                XCTAssertEqual(issue, .stepFailed, "krok \(index)")
                result.rejectedStep = (index, diagnostics.lastRejectionReason)
                return result
            }
            for case .transactionRejected(_, let rejection) in frame.events { result.rejectedTransactions.append(rejection) }
            result.frames.append(frame)
            result.counts.append(diagnostics.containedBubblePairCount)
            for (identifier, state) in frame.objects {
                if let before = previous[identifier] {
                    result.displacements.append((index, identifier, simd.distance(before, state.position)))
                }
                previous[identifier] = state.position
            }
        }
        return result
    }
    private func assertNoRejection(_ run: Run, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(run.rejectedStep?.reason, "krok odrzucony przez strażnika \(message)", file: file, line: line)
        XCTAssertNil(run.rejectedStep, "krok odrzucony \(message)", file: file, line: line)
        XCTAssertTrue(run.rejectedTransactions.isEmpty, "transakcja odrzucona \(message)", file: file, line: line)
    }
    private func assertStepDisplacementIsLimited(_ run: Run, radii: [ObjectID: Float],
                                                 file: StaticString = #filePath, line: UInt = #line) {
        let ruchZPredkosci = Float(100 * step)
        for entry in run.displacements {
            let limit = 0.25 * (radii[entry.id] ?? 0) + ruchZPredkosci
            XCTAssertLessThanOrEqual(entry.distance, limit + 1e-3,
                "krok \(entry.step), bańka \(entry.id.rawValue): przesunięcie \(entry.distance) > \(limit)", file: file, line: line)
        }
    }
    private func assertSettled(_ run: Run, file: StaticString = #filePath, line: UInt = #line) throws {
        let last = try XCTUnwrap(run.frames.last, file: file, line: line)
        for (identifier, state) in last.objects {
            XCTAssertLessThan(simd.length(state.velocity), 2, "bańka \(identifier.rawValue) po 2 s", file: file, line: line)
        }
    }

    // Założenie G2-AC2: tłumienie dobrane tak, że bańka puszczona z prędkością 100 zwalnia poniżej 2 w ciągu 1 s.
    func testDampingSlowsAFastBubbleBelowTwoWithinOneSecond() async throws {
        let world = try await world()
        _ = world.submit(WorldTransaction().add(try bubble(1, at: .zero, radius: 20, velocity: [100, 0])))
        var frame = await world.advance(by: step)
        for _ in 1..<60 { frame = await world.advance(by: step) }
        XCTAssertLessThan(try XCTUnwrap(frame.objects[id(1)]).velocity.x, 2)
    }

    // P-B-9
    func testContainedPairResolvesWithoutRejectionAndCounterGoesToZero() async throws {
        let world = try await world()
        _ = world.submit(WorldTransaction().add(try bubble(1, at: .zero, radius: 60)))
        _ = await world.advance(by: step)
        let result = await run(world, WorldTransaction().add(try bubble(2, at: [5, 0], radius: 20)), steps: 120,
                               startingAt: [id(1): .zero, id(2): [5, 0]])
        assertNoRejection(result)
        XCTAssertEqual(result.counts.first, 1, "licznik par w pierwszej klatce po dodaniu")
        XCTAssertEqual(result.counts.last, 0, "po 2 s bańka wyszła z większej")
        let last = try XCTUnwrap(result.frames.last)
        let distance = simd.distance(try XCTUnwrap(last.objects[id(1)]).position, try XCTUnwrap(last.objects[id(2)]).position)
        XCTAssertGreaterThanOrEqual(distance, 40 - 0.01, "mniejsza bańka (r = 20) nie mieści się już w większej (r = 60)")
    }

    // P-B-9: pusta plansza i bańki, które się tylko nakładają, nie dają par „bańka w bańce”.
    func testEmptyBoardAndOverlappingBubblesHaveNoContainedPairs() async throws {
        let empty = try await world()
        let emptyFrames = await run(empty, steps: 5, startingAt: [:])
        assertNoRejection(emptyFrames)
        XCTAssertEqual(emptyFrames.counts, Array(repeating: 0, count: 5))
        XCTAssertEqual(empty.diagnostics.containedBubblePairCount, 0)

        let overlapping = try await world()
        // Środki 30 od siebie przy promieniach 20 i 20: nakładają się częściowo, żadna nie mieści się w drugiej.
        let result = await run(overlapping, WorldTransaction().add(try bubble(1, at: [-15, 0], radius: 20))
            .add(try bubble(2, at: [15, 0], radius: 20)).add(try bubble(3, at: [200, 200], radius: 10)),
            steps: 30, startingAt: [id(1): [-15, 0], id(2): [15, 0], id(3): [200, 200]])
        assertNoRejection(result)
        XCTAssertEqual(result.counts, Array(repeating: 0, count: 30))
    }

    // P-B-11
    func testCoincidentPairSeparatesWithoutRejection() async throws {
        let world = try await world()
        let result = await run(world, WorldTransaction().add(try bubble(1, at: [0, 0], radius: 20))
            .add(try bubble(2, at: [0.01, 0], radius: 20)), steps: 120, startingAt: [id(1): [0, 0], id(2): [0.01, 0]])
        assertNoRejection(result)
        XCTAssertEqual(result.frames.count, 120)
        let last = try XCTUnwrap(result.frames.last)
        let distance = simd.distance(try XCTUnwrap(last.objects[id(1)]).position, try XCTUnwrap(last.objects[id(2)]).position)
        XCTAssertGreaterThanOrEqual(distance, 20, "po 2 s środki oddalone o co najmniej 20")
    }

    // P-B-12
    func testMergeIntoOccupiedPlaceKeepsTheWorldRunning() async throws {
        let world = try await world()
        // Źródła A i B stykają się w (0, 0), a ten punkt leży wewnątrz trzeciej, dużej bańki C.
        let transaction = WorldTransaction().add(try bubble(3, at: [0, 3], radius: 30))
            .add(try bubble(1, at: [-5, 0], radius: 5)).add(try bubble(2, at: [5, 0], radius: 5))
            .mergeBubbles([id(1), id(2)], result: BubbleResult(id: id(100), physicsMaterialID: material,
                                                               renderMaterialID: style, eventInterest: [.didAdd]))
        let result = await run(world, transaction, steps: 120, startingAt: [:])
        assertNoRejection(result)
        XCTAssertEqual(result.frames.count, 120)
        let events = result.frames.flatMap(\.events)
        XCTAssertTrue(events.contains(.didAdd(id(100))), "wynik scalenia pojawił się mimo zajętego miejsca")
        XCTAssertNotNil(result.frames.last?.objects[id(100)])
    }

    // P-B-30 (G2-AC3): para z P-B-11 z materiałem miękkim rozsuwa się bez odrzucenia, ale w pierwszym kroku mniej niż przy c₀ = 0.
    // c = 4e-3 (r = 20, r_ref = 20, s = 1) daje α pary rzędu 29 przy sumie odwrotności mas 2, więc λ pary w pierwszym kroku mieści się
    // pod limitem 0,25·r i para rusza wolniej niż przy kontakcie twardym, który limit przycina.
    func testSoftCoincidentPairSeparatesWithoutRejectionAndMovesLessInTheFirstStep() async throws {
        func firstStepDistanceAndFinal(_ compliance: BubbleContactCompliance) async throws -> (first: Float, final: Float) {
            let world = try await world(contactCompliance: compliance)
            let result = await run(world, WorldTransaction().add(try bubble(1, at: [0, 0], radius: 20))
                .add(try bubble(2, at: [0.01, 0], radius: 20)), steps: 120, startingAt: [id(1): [0, 0], id(2): [0.01, 0]])
            assertNoRejection(result, "(\(compliance.base))")
            XCTAssertEqual(result.frames.count, 120)
            func distance(_ frame: WorldFrame) throws -> Float {
                simd.distance(try XCTUnwrap(frame.objects[id(1)]).position, try XCTUnwrap(frame.objects[id(2)]).position)
            }
            return (try distance(try XCTUnwrap(result.frames.first)), try distance(try XCTUnwrap(result.frames.last)))
        }
        let hard = try await firstStepDistanceAndFinal(.hard)
        let soft = try await firstStepDistanceAndFinal(BubbleContactCompliance(base: 4e-3, referenceRadius: 20, radiusExponent: 1))
        XCTAssertGreaterThanOrEqual(soft.final, 20, "po 2 s środki oddalone o co najmniej 20")
        XCTAssertLessThan(soft.first, hard.first, "po pierwszym kroku miękka para (\(soft.first)) bliżej niż twarda (\(hard.first))")
    }

    // P-B-10, scena z P-B-11
    func testStepDisplacementCoincidentPairIsLimitedAndSettles() async throws {
        let world = try await world()
        let result = await run(world, WorldTransaction().add(try bubble(1, at: [0, 0], radius: 20))
            .add(try bubble(2, at: [0.01, 0], radius: 20)), steps: 120, startingAt: [id(1): [0, 0], id(2): [0.01, 0]])
        assertNoRejection(result)
        assertStepDisplacementIsLimited(result, radii: [id(1): 20, id(2): 20])
        try assertSettled(result)
    }

    // P-B-10, scena z P-B-9
    func testStepDisplacementContainedPairIsLimitedAndSettles() async throws {
        let world = try await world()
        _ = world.submit(WorldTransaction().add(try bubble(1, at: .zero, radius: 60)))
        _ = await world.advance(by: step)
        let result = await run(world, WorldTransaction().add(try bubble(2, at: [5, 0], radius: 20)), steps: 120,
                               startingAt: [id(1): .zero, id(2): [5, 0]])
        assertNoRejection(result)
        assertStepDisplacementIsLimited(result, radii: [id(1): 60, id(2): 20])
        try assertSettled(result)
    }

    // P-B-38: limit działa na parę, więc akcja równa się reakcji także wtedy, gdy lżejsza bańka trafia w limit.
    func testLimitedPairKeepsMomentum() async throws {
        let world = try await world(maximumLinearSpeed: nil, damping: 0)
        let result = await run(world, WorldTransaction().add(try bubble(1, at: [0, 0], radius: 20))
            .add(try bubble(2, at: [0.01, 0], radius: 40)), steps: 1, startingAt: [id(1): [0, 0], id(2): [0.01, 0]])
        assertNoRejection(result)
        let frame = try XCTUnwrap(result.frames.first)
        let light = try XCTUnwrap(frame.objects[id(1)]), heavy = try XCTUnwrap(frame.objects[id(2)])
        let massLight: Float = 1, massHeavy: Float = 4
        let momentum = massLight * light.velocity + massHeavy * heavy.velocity
        let scale = massLight * simd.length(light.velocity) + massHeavy * simd.length(heavy.velocity)
        XCTAssertGreaterThan(scale, 0.1, "bańki zostały rozsunięte")
        XCTAssertLessThanOrEqual(simd.length(momentum), 1e-3 * scale + 1e-3, "pęd pary po kroku: \(momentum)")
        // Limit rzeczywiście zadziałał: lżejsza bańka przesunęła się najwyżej o 0,25 · r.
        assertStepDisplacementIsLimited(result, radii: [id(1): 20, id(2): 40])
    }

    // P-B-39 (G2-AC6): limit pary nie zapada stosu pod stałym naciskiem. Scena z `ContactEventTests.testBeganBubbleAndBubble`:
    // materiały domyślne, dwie bańki r = 8 (masa 1 jak w tamtej scenie) jedna nad drugą na statycznej podłodze, grawitacja −400, 600 kroków.
    func testTwoBubbleStackUnderGravityHoldsFor600Steps() async throws {
        let floorMaterial = PhysicsMaterialID(rawValue: 2)
        let world = try BubbleWorld(configuration: WorldConfiguration(
            simulationRegion: WorldRectangle(min: [0, 0], max: [600, 300]), fixedTimeStep: step, globalForce: [0, -400]))
        let floor = WorldObject.rigidBody(try RigidBodyDescriptor(
            id: id(100), vertices: [[0, 0], [600, 0], [600, 10], [0, 10]], motionRole: .static,
            physicsMaterialID: floorMaterial, renderMaterialID: style))
        _ = world.submit(WorldTransaction()
            .updatePhysicsMaterial(material, material: try PhysicsMaterial(kind: .bubble))
            .updatePhysicsMaterial(floorMaterial, material: try PhysicsMaterial(kind: .rigid))
            .updateRenderMaterial(style, material: try RenderMaterial())
            .add(floor)
            .add(try bubble(2, at: [150, 18.3], radius: 8, mass: 1))
            .add(try bubble(1, at: [150, 34.6], radius: 8, mass: 1)))
        for index in 0..<600 {
            let frame = await world.advance(by: step)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue, "krok \(index)")
            let upper = try XCTUnwrap(frame.objects[id(1)], "krok \(index): górna bańka zniknęła").position
            let lower = try XCTUnwrap(frame.objects[id(2)], "krok \(index): dolna bańka zniknęła").position
            XCTAssertGreaterThan(upper.y, lower.y, "krok \(index): górna bańka nie leży nad dolną")
            XCTAssertGreaterThanOrEqual(simd.distance(upper, lower), 0.95 * 16,
                                        "krok \(index): stos zapadł się, odległość środków \(simd.distance(upper, lower))")
        }
    }
}
