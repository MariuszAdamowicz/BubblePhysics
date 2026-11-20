import XCTest
import Metal
import BubblePhysicsModel
import BubblePhysicsReference
@testable import BubblePhysicsNativeMetal
@testable import BubblePhysicsNativeMetalDiagnostics

@MainActor
final class NativeMetalXPBDTests: XCTestCase {
    // Brak korekcji pozycji lub publikacja prędkości sprzed solvera łamie ten kontrakt.
    func testTwoOverlappingBubblesSeparateWithoutNonFiniteState() async throws {
        let solver = try makeSolver(iterations: 32)
        let world = try makeWorld(centers: [0, 1.5])
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        assertFinite(frame)
        XCTAssertGreaterThanOrEqual((frame.bubbles[1].center - frame.bubbles[0].center).length, 1.9999)
        XCTAssertGreaterThan(frame.report.solver.iterations, 0)
        XCTAssertTrue(frame.report.solver.converged)
        XCTAssertLessThanOrEqual(frame.report.solver.maximumPenetration, 0.0001)
        XCTAssertGreaterThan(frame.contacts[0].accumulatedCompression, 0)
        // Natychmiastowa korekta pozycji PBD nie jest fizycznym impulsem
        // prędkości. Rekonstrukcja ogranicza ją do skali sprężyny kontaktu.
        XCTAssertLessThan(abs(frame.bubbles[0].velocity.x), 1)
        XCTAssertLessThan(frame.bubbles[0].velocity.x, 0)
        XCTAssertEqual(frame.profile.commandBufferCount, 1)
    }

    // Wspólny zapis pozycji przez kontakt lub odczyt częściowo zapisanej iteracji zmienia hash.
    // Limit λ pary (CD-D-9) tnie przesunięcie pary do 0,25·min r na krok: skrajne bańki łańcucha idą o 0,25, środkowa
    // zostaje (dwa równe, przeciwne przyrosty), więc po pierwszej klatce odstępy rosną z 1,5 do 1,75 zamiast do 2 (bliźniak: ...WithoutPairCorrectionLimit).
    func testThreeBubbleChainIsRepeatableAndRaceFree() async throws {
        try await assertThreeBubbleChainIsRepeatableAndRaceFree(pairCorrectionLimit: true)
    }

    // Bliźniak (CD-D-20): bez limitu pary oczekiwanie z v2.1.0, pełne rozdzielenie w jednym kroku.
    func testThreeBubbleChainIsRepeatableAndRaceFreeWithoutPairCorrectionLimit() async throws {
        try await assertThreeBubbleChainIsRepeatableAndRaceFree(pairCorrectionLimit: false)
    }

    // Usunięcie applyWarmStart albo zerowanie poprawnie dopasowanej lambda daje koszt cold-startu.
    // Z limitem λ pary (CD-D-9) para nie dochodzi do zbieżności w jednym kroku (λ ≤ 0,25·min r / max invMass), więc
    // kolejne klatki tego samego wejścia zużywają cały budżet: zostaje „nie więcej niż cold start”, a warm start widać w residuum
    // przed pierwszą iteracją, mniejszym niż w klatce zimnej (bliźniak: ...WithoutPairCorrectionLimit).
    func testWarmStartNeedsNoMoreIterationsThanColdStartAfterFirstFrame() async throws {
        try await assertWarmStartNeedsNoMoreIterationsThanColdStartAfterFirstFrame(pairCorrectionLimit: true)
    }

    // Bliźniak (CD-D-20): bez limitu pary oczekiwanie z v2.1.0, warm start zbiega szybciej niż pierwsza klatka.
    func testWarmStartNeedsNoMoreIterationsThanColdStartAfterFirstFrameWithoutPairCorrectionLimit() async throws {
        try await assertWarmStartNeedsNoMoreIterationsThanColdStartAfterFirstFrame(pairCorrectionLimit: false)
    }

    // Limit λ pary (CD-D-9): odstęp pierwszej pary po jednym kroku to 1,4 + 0,25 = 1,65 (środkowa bańka stoi w miejscu).
    func testSameInputProducesSamePublishedStateHash() async throws {
        try await assertSameInputProducesSamePublishedStateHash(pairCorrectionLimit: true)
    }

    // Bliźniak (CD-D-20): bez limitu pary oczekiwanie z v2.1.0.
    func testSameInputProducesSamePublishedStateHashWithoutPairCorrectionLimit() async throws {
        try await assertSameInputProducesSamePublishedStateHash(pairCorrectionLimit: false)
    }

    func testSegmentContactSeparatesAndIterationBudgetIsReported() async throws {
        let solver = try makeSolver(iterations: 3)
        var world = try makeWorld(centers: [0])
        world.addSegment(.staticSegment(id: .init(rawValue: 7), a: .init(x: -2, y: -0.5), b: .init(x: 2, y: -0.5)))
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        XCTAssertGreaterThanOrEqual(frame.bubbles[0].center.y, 0.4999)
        XCTAssertEqual(frame.telemetry.solverIterationCount, 3)
        XCTAssertEqual(frame.report.solver.iterations, 1)
        XCTAssertTrue(frame.report.solver.converged)
        assertFinite(frame)
    }

    func testXPBDComplianceConvergesToTheCompliantConstraint() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()),
            configuration: .init(solverIterationCount: 8, contactCompliance: 0.1))
        let world = try makeWorld(centers: [0, 1.5], timeStep: 1)
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        // C = 0.5, wA+wB = 2, alpha/dt² = 0.1: lambda = 0.5 / 2.1.
        XCTAssertEqual(frame.contacts[0].accumulatedCompression, 0.23809524, accuracy: 0.00001)
        XCTAssertEqual(frame.bubbles[0].center.x, -0.23809524, accuracy: 0.00001)
        XCTAssertEqual(frame.report.solver.maximumPenetration, 0.02380952, accuracy: 0.00001)
        XCTAssertLessThanOrEqual(frame.report.solver.finalResidualNorm, 0.0001)
        XCTAssertTrue(frame.report.solver.converged)
    }

    // Limit λ pary (CD-D-9) = 0,25·min r / max invMass = 0,25, jedno λ dla obu końców: przesunięcia to invMass·λ,
    // czyli 0,25/3 i 0,25 (zamiast 0,125 i 0,375 bez limitu), a pęd pary nadal się zeruje.
    func testInverseMassWeightsCorrectionsAndPreservesCenterOfMass() async throws {
        try await assertInverseMassWeightsCorrections(pairCorrectionLimit: true, expectedCenters: (-1.0 / 12, 1.75))
    }

    // Bliźniak (CD-D-20): bez limitu pary oczekiwanie z v2.1.0.
    func testInverseMassWeightsCorrectionsAndPreservesCenterOfMassWithoutPairCorrectionLimit() async throws {
        try await assertInverseMassWeightsCorrections(pairCorrectionLimit: false, expectedCenters: (-0.125, 1.875))
    }

    func testUnsatisfiedConstraintReportsIterationLimit() async throws {
        let solver = try makeSolver(iterations: 1)
        let frame = try await solver.executeFrame(world: makeWorld(centers: [0, 1.5, 3]), scenarioStep: 1)
        XCTAssertEqual(frame.report.solver.iterations, 1)
        XCTAssertEqual(frame.telemetry.solverIterationCount, 1)
        XCTAssertFalse(frame.report.solver.converged)
        XCTAssertTrue(frame.report.solver.didReachIterationLimit)
        XCTAssertEqual(frame.report.solver.maximumPenetration, 0.375, accuracy: 0.00001)
        XCTAssertEqual(frame.report.solver.positionCorrectionCount, 2)
        XCTAssertTrue(frame.isComplete)
        assertFinite(frame)
    }

    func testTeleportResetDoesNotApplyTheOldMultiplier() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()),
            configuration: .init(solverIterationCount: 8, teleportDistanceMultiplier: 0.1))
        var world = try makeWorld(centers: [0, 1.5])
        _ = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 1)
        var moved = world.bubbles[1]; moved.center.x = 1.9; world.updateBubble(moved)
        let frame = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 2)
        XCTAssertEqual(frame.telemetry.cacheResetCount, 1)
        XCTAssertEqual(frame.telemetry.cacheHitCount, 0)
        XCTAssertEqual(frame.report.solver.initialResidualNorm, 0.1, accuracy: 0.00001)
        XCTAssertEqual(frame.contacts[0].accumulatedCompression, 0.05, accuracy: 0.00001)
        XCTAssertEqual(frame.contacts[0].age, 1)
    }

    func testWarmStartBoundsAnOversizedMatchedMultiplierByBubbleRadius() async throws {
        try await assertWarmStartBoundsAnOversizedMatchedMultiplier(pairCorrectionLimit: true)
    }

    // Bliźniak (CD-D-20): bez limitu pary warm-start ogranicza dopiero dawny próg r / (invMass · stopień).
    func testWarmStartBoundsAnOversizedMatchedMultiplierByBubbleRadiusWithoutPairCorrectionLimit() async throws {
        try await assertWarmStartBoundsAnOversizedMatchedMultiplier(pairCorrectionLimit: false)
    }

    // LD-D-1: przy limicie pary warm start nie ma limitu na bańkę. Każda para ma własny limit λ (0,25·min r / max invMass plus ruch
    // w stronę kontaktu), a korekty bańki się sumują, więc bańka z k kontaktami bez ruchu przesuwa się o co najwyżej k·0,25·min r:
    // suma nie jest ograniczona promieniem i może go przekroczyć. Tu 4 sąsiadów r = 0,5 po jednej
    // stronie bańki r = 2: przesunięcie środkowej bańki to suma wektorowa limitów par (|·| ≈ 0,385) i zostaje poniżej promienia.
    func testWarmStartOfBubbleWithFourContactsAddsUpThePairLimits() async throws {
        let solver = try makeSolver(iterations: 1)
        var world = ReferenceWorld(configuration: .init(linearDamping: 0), broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 1), center: .zero, mass: 1, targetRadius: 2))
        // Co 36°: sąsiedzi nachodzą na środkową bańkę o 0,7, a na siebie nie (cięciwa 3,6·sin 18° ≈ 1,11 > 1).
        let angles: [Float] = [126, 162, 198, 234].map { $0 * .pi / 180 }
        for (offset, angle) in angles.enumerated() {
            world.addBubble(try .init(id: .init(rawValue: offset + 2), center: .init(x: 1.8 * cos(angle), y: 1.8 * sin(angle)),
                                      mass: 1, targetRadius: 0.5))
        }
        _ = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 1)
        let state = try XCTUnwrap(solver.persistentState)
        XCTAssertEqual(solver.cachedContacts.count, 4)
        let records = state.contactCache.contents().bindMemory(to: NativeContactCacheRecord.self, capacity: state.contactCapacity)
        for index in 0..<solver.cachedContacts.count { records[index].lambda = 100_000_000 }
        let frame = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 2)
        XCTAssertEqual(frame.telemetry.cacheHitCount, 4)
        // Limit pary bez ruchu: 0,25 · min(2; 0,5) / 1 = 0,125. Każda para odpycha środkową bańkę od sąsiada o 0,125, a po warm
        // starcie wszystkie pary dalej nachodzą na siebie, więc jedyna iteracja Jacobiego nie zmienia λ ponad limit.
        let pairLimit: Float = 0.125
        let expectedX = angles.reduce(0) { $0 - pairLimit * cos($1) }
        let expectedY = angles.reduce(0) { $0 - pairLimit * sin($1) }
        XCTAssertEqual(frame.bubbles[0].center.x, expectedX, accuracy: 0.00001)
        XCTAssertEqual(frame.bubbles[0].center.y, expectedY, accuracy: 0.00001)
        let displacement = frame.bubbles[0].center.length
        XCTAssertGreaterThan(displacement, 3 * pairLimit, "korekty par się sumują, nie ma limitu na bańkę")
        XCTAssertLessThan(displacement, 2, "przy 4 kontaktach bez ruchu przesunięcie zostaje poniżej promienia")
        for (offset, angle) in angles.enumerated() {
            let center = frame.bubbles[offset + 1].center
            XCTAssertEqual(center.x, (1.8 + pairLimit) * cos(angle), accuracy: 0.00001, "sąsiad \(offset + 2)")
            XCTAssertEqual(center.y, (1.8 + pairLimit) * sin(angle), accuracy: 0.00001, "sąsiad \(offset + 2)")
        }
        assertFinite(frame)
    }

    func testRejectedSolvedFramePreservesPublishedPositionsAndMultipliersForBothBufferParities() async throws {
        for budget in [3, 4] {
            let executor = XPBDRejectingExecutor()
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            let solver = try NativeMetalSolver(device: device, commandExecutor: executor,
                configuration: .init(solverIterationCount: budget))
            let control = try makeSolver(iterations: budget)
            let world = try makeWorld(centers: [0, 1.5])
            let first = try await solver.executeFrame(world: world, scenarioStep: 1)
            _ = try await control.executeFrame(world: world, scenarioStep: 1)
            let state = try XCTUnwrap(solver.persistentState)
            let positions = state.publishedBubbles
            let multipliers = state.contactCache
            let cache = solver.cachedContacts
            executor.rejectNext = true
            do {
                _ = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 2)
                XCTFail("Wykonany, lecz odrzucony wynik nie może zostać opublikowany")
            } catch XPBDRejectingExecutor.Failure.injected {}
            XCTAssertTrue(state.publishedBubbles === positions)
            XCTAssertTrue(state.contactCache === multipliers)
            XCTAssertEqual(state.publishedBubbles.contents().load(as: NativeMetalBubble.self).position.x, first.bubbles[0].center.x)
            XCTAssertEqual(state.contactCache.contents().load(as: NativeContactCacheRecord.self), cache[0])
            XCTAssertEqual(solver.cachedContacts, cache)
            XCTAssertEqual(stateHash(try XCTUnwrap(solver.publishedFrame)), stateHash(first))
            let recovered = try await solver.executeFrame(world: world, scenarioStep: 3)
            let expected = try await control.executeFrame(world: world, scenarioStep: 3)
            XCTAssertEqual(stateHash(recovered), stateHash(expected))
        }
    }

    // MARK: wspólne ciała bliźniaków (CD-D-20): `pairCorrectionLimit: false` daje oczekiwanie z v2.1.0

    private func assertThreeBubbleChainIsRepeatableAndRaceFree(pairCorrectionLimit: Bool) async throws {
        let first = try makeSolver(iterations: 32, pairCorrectionLimit: pairCorrectionLimit)
        let second = try makeSolver(iterations: 32, pairCorrectionLimit: pairCorrectionLimit)
        let world = try makeWorld(centers: [0, 1.5, 3])
        for step in 1...60 {
            let a = try await first.executeFrame(world: world, scenarioStep: step)
            let b = try await second.executeFrame(world: world, scenarioStep: step)
            assertFinite(a)
            XCTAssertEqual(stateHash(a), stateHash(b), "Klatka \(step)")
            for index in 0..<2 {
                let gap = (a.bubbles[index + 1].center - a.bubbles[index].center).length
                if !pairCorrectionLimit {
                    XCTAssertGreaterThanOrEqual(gap, 1.9999)
                } else if step == 1 {
                    // Pierwsza klatka: dokładnie 1,75; potem bańki rozchodzą się z nabytą prędkością (bez tłumienia).
                    XCTAssertEqual(gap, 1.75, accuracy: 0.0001)
                } else {
                    XCTAssertGreaterThanOrEqual(gap, 1.75 - 0.0001, "Klatka \(step)")
                }
            }
        }
    }

    private func assertWarmStartNeedsNoMoreIterationsThanColdStartAfterFirstFrame(pairCorrectionLimit: Bool) async throws {
        let warm = try makeSolver(iterations: 64, pairCorrectionLimit: pairCorrectionLimit)
        let world = try makeWorld(centers: [0, 1.5, 3])
        let initial = try await warm.executeFrame(snapshot: .init(world: world), scenarioStep: 1)
        XCTAssertGreaterThan(initial.report.solver.iterations, 0)
        for step in 2...5 {
            // Pełny snapshot jawnie ponawia kontrolowane wejście, zachowując cache solvera.
            let warmed = try await warm.executeFrame(snapshot: .init(world: world), scenarioStep: step)
            let cold = try makeSolver(iterations: 64, pairCorrectionLimit: pairCorrectionLimit)
            let coldFrame = try await cold.executeFrame(snapshot: .init(world: world), scenarioStep: step)
            XCTAssertEqual(warmed.telemetry.cacheHitCount, 2)
            XCTAssertLessThanOrEqual(warmed.report.solver.iterations, coldFrame.report.solver.iterations)
            if pairCorrectionLimit {
                XCTAssertLessThanOrEqual(warmed.report.solver.iterations, initial.report.solver.iterations)
                // Limit pary trzyma obie klatki na tym samym końcowym residuum (0,25) przy pełnym budżecie, więc warm start widać
                // w residuum przed pierwszą iteracją: zapamiętane mnożniki przesuwają pary, zanim ruszy Jacobi (0,25 wobec 0,5).
                XCTAssertLessThan(warmed.report.solver.initialResidualNorm, coldFrame.report.solver.initialResidualNorm, "Klatka \(step)")
            } else {
                XCTAssertLessThan(warmed.report.solver.iterations, initial.report.solver.iterations)
                XCTAssertTrue(warmed.report.solver.converged)
            }
            assertFinite(warmed)
        }
    }

    private func assertSameInputProducesSamePublishedStateHash(pairCorrectionLimit: Bool) async throws {
        let world = try makeWorld(centers: [0, 1.4, 2.9])
        var hashes: [UInt64] = []
        for _ in 0..<4 {
            let solver = try makeSolver(iterations: 32, pairCorrectionLimit: pairCorrectionLimit)
            let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
            let gap = (frame.bubbles[1].center - frame.bubbles[0].center).length
            if pairCorrectionLimit { XCTAssertEqual(gap, 1.65, accuracy: 0.0001) } else { XCTAssertGreaterThanOrEqual(gap, 1.9999) }
            hashes.append(stateHash(frame))
            XCTAssertEqual(stateHash(try XCTUnwrap(solver.publishedFrame)), hashes.last)
        }
        XCTAssertTrue(hashes.allSatisfy { $0 == hashes[0] })
    }

    private func assertInverseMassWeightsCorrections(pairCorrectionLimit: Bool, expectedCenters: (Float, Float)) async throws {
        let solver = try makeSolver(iterations: 3, pairCorrectionLimit: pairCorrectionLimit)
        let world = try makeInverseMassWorld()
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        XCTAssertEqual(frame.bubbles[0].center.x, expectedCenters.0, accuracy: 0.00001)
        XCTAssertEqual(frame.bubbles[1].center.x, expectedCenters.1, accuracy: 0.00001)
        XCTAssertEqual(3 * frame.bubbles[0].velocity.x + frame.bubbles[1].velocity.x, 0, accuracy: 0.0001)
    }

    private func assertWarmStartBoundsAnOversizedMatchedMultiplier(pairCorrectionLimit: Bool) async throws {
        let solver = try makeSolver(iterations: 1, pairCorrectionLimit: pairCorrectionLimit)
        let world = try makeWorld(centers: [0, 1.5])
        _ = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 1)
        let state = try XCTUnwrap(solver.persistentState)
        state.contactCache.contents().bindMemory(to: NativeContactCacheRecord.self, capacity: state.contactCapacity)[0].lambda = 100_000_000
        let frame = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 2)
        // Każda bańka ma promień 1: warm-start przesuwa co najwyżej o promień,
        // więc rezyduum przed pierwszą iteracją nie przekracza 1.5.
        XCTAssertLessThanOrEqual(frame.report.solver.initialResidualNorm, 1.50001)
        XCTAssertEqual(frame.bubbles[0].center.x, -0.25, accuracy: 0.00001)
        XCTAssertEqual(frame.bubbles[1].center.x, 1.75, accuracy: 0.00001)
        XCTAssertEqual(frame.telemetry.cacheHitCount, 1)
        assertFinite(frame)
    }

    /// Wejście solvera z własnościami `contact` (c = c₀·r/r_ref, wolna lane, ζ_c) dla każdej bańki; `damping` = 0 i bez sił, więc
    /// pozycja przewidziana to center + velocity · dt.
    private func contactInput(_ bubbles: [(id: Int, center: SIMD2<Float>, velocity: SIMD2<Float>, radius: Float, contact: SIMD4<Float>)],
                              segments: [NativeSolverSegment] = []) throws -> NativeSolverInput {
        var properties: [NativeSolverBubbleID: NativePublicProperties] = [:]
        for bubble in bubbles {
            var property = NativePublicProperties(flags: SIMD4(1, 0, 0, 0), material: SIMD4(0, 0.5, 0, 0), restitution: 0,
                resources: .zero, eventData: .zero)
            property.contact = bubble.contact
            properties[.init(rawValue: bubble.id)] = property
        }
        var input = NativeSolverInput(configuration: .init(linearDamping: 0), bubbles: bubbles.map {
            NativeSolverBubble(id: .init(rawValue: $0.id), center: $0.center, velocity: $0.velocity, mass: 1, targetRadius: $0.radius)
        }, segments: segments, publicSettings: NativePublicSettings(properties: properties,
            region: try WorldRectangle(min: [-100, -100], max: [100, 100])))
        input.hitTests = []
        return input
    }

    private func pairRecord(_ solver: NativeMetalSolver) throws -> NativeContactCacheRecord {
        let record = try XCTUnwrap(solver.cachedContacts.first { $0.metadata.x == 0 })
        XCTAssertEqual(record.participants, SIMD2<Int64>(1, 2), "koniec a to bańka 1")
        return record
    }

    // F-6 (LD-D-6): `nativePrepareSolverContacts` zapisuje w `compliance.x` sumę podatności końców c_a + c_b (c = `contact.x`
    // bańki, bez ρ), a `nativeContactAlpha` czyta ją w każdej iteracji. Para miękkich baniek o różnych c.
    func testPreparedContactCarriesTheSumOfEndComplianceInComplianceX() async throws {
        let solver = try makeSolver(iterations: 8)
        let contact: [SIMD4<Float>] = [SIMD4(0.002, 0, 1, 0), SIMD4(0.0005, 0, 1, 0)]
        let input = try contactInput([(1, SIMD2(0, 0), .zero, 1, contact[0]), (2, SIMD2(1.5, 0), .zero, 1, contact[1])])
        for step in 1...3 { _ = try await solver.executeFrame(input: input, scenarioStep: step) }
        let record = try pairRecord(solver)
        XCTAssertEqual(record.metadata.y, 3, "rekord dopasowany przez trzy kroki: podatność przeżywa trafienie w cache")
        XCTAssertEqual(record.compliance.x, 0.0025, accuracy: 0.0025 * 1e-5, "compliance.x = c_a + c_b")
    }

    // Kontakt z odcinkiem niesie tylko c_a, para twarda 0, a para miękka–twarda tylko podatność końca miękkiego.
    func testPreparedContactComplianceOfWallHardPairAndSoftHardPair() async throws {
        let wallSolver = try makeSolver(iterations: 8)
        let wall = NativeSolverSegment(id: 7, previousA: SIMD2(0, -10), previousB: SIMD2(0, 10),
            currentA: SIMD2(0, -10), currentB: SIMD2(0, 10))
        let wallInput = try contactInput([(1, SIMD2(-0.95, 0), .zero, 1, SIMD4(0.002, 0, 1, 0))], segments: [wall])
        _ = try await wallSolver.executeFrame(input: wallInput, scenarioStep: 1)
        let wallRecord = try XCTUnwrap(wallSolver.cachedContacts.first { $0.metadata.x == 1 })
        XCTAssertEqual(wallRecord.compliance.x, 0.002, accuracy: 0.002 * 1e-5)

        let hard = try makeSolver(iterations: 8)
        let hardInput = try contactInput([(1, SIMD2(0, 0), .zero, 1, SIMD4(0, 0, 1, 0)), (2, SIMD2(1.5, 0), .zero, 1, SIMD4(0, 0, 1, 0))])
        _ = try await hard.executeFrame(input: hardInput, scenarioStep: 1)
        XCTAssertEqual(try pairRecord(hard).compliance.x, 0)

        let mixed = try makeSolver(iterations: 8)
        let mixedInput = try contactInput([(1, SIMD2(0, 0), .zero, 1, SIMD4(0.002, 0, 1, 0)), (2, SIMD2(1.5, 0), .zero, 1, SIMD4(0, 0, 1, 0))])
        _ = try await mixed.executeFrame(input: mixedInput, scenarioStep: 1)
        XCTAssertEqual(try pairRecord(mixed).compliance.x, 0.002, accuracy: 0.002 * 1e-5)
    }

    /// `pairCorrectionLimit: false` daje bliźniaki z oczekiwaniem z v2.1.0 (CD-D-20).
    private func makeSolver(iterations: Int, pairCorrectionLimit: Bool = true) throws -> NativeMetalSolver {
        var configuration = NativeMetalConfiguration(solverIterationCount: iterations)
        configuration.pairCorrectionLimit = pairCorrectionLimit
        return try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()), configuration: configuration)
    }

    private func makeInverseMassWorld() throws -> ReferenceWorld {
        var world = ReferenceWorld(configuration: .init(linearDamping: 0), broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 1), center: .zero, mass: 3, targetRadius: 1))
        world.addBubble(try .init(id: .init(rawValue: 2), center: .init(x: 1.5, y: 0), mass: 1, targetRadius: 1))
        return world
    }

    private func makeWorld(centers: [Float], timeStep: Float = 1 / 60) throws -> ReferenceWorld {
        var world = ReferenceWorld(configuration: .init(timeStep: timeStep, linearDamping: 0), broadPhase: BruteForceBroadPhase())
        for (id, x) in centers.enumerated() {
            world.addBubble(try .init(id: .init(rawValue: id + 1), center: .init(x: x, y: 0), mass: 1, targetRadius: 1))
        }
        return world
    }

    private func assertFinite(_ frame: NativeMetalWorldFrame, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(frame.report.hasNonFiniteState, file: file, line: line)
        XCTAssertTrue(frame.bubbles.allSatisfy { $0.center.isFinite && $0.previousCenter.isFinite && $0.velocity.isFinite }, file: file, line: line)
        XCTAssertTrue(frame.contacts.allSatisfy { $0.normal.isFinite && $0.accumulatedCompression.isFinite && $0.accumulatedCompression >= 0 }, file: file, line: line)
    }

    private func stateHash(_ frame: NativeMetalWorldFrame) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        func append(_ value: UInt64) { hash = (hash ^ value) &* 1099511628211 }
        for b in frame.bubbles {
            append(UInt64(bitPattern: Int64(b.id.rawValue)))
            for value in [b.center.x, b.center.y, b.previousCenter.x, b.previousCenter.y, b.velocity.x, b.velocity.y] { append(UInt64(value.bitPattern)) }
        }
        for c in frame.contacts { append(c.id.rawValue); append(UInt64(c.accumulatedCompression.bitPattern)) }
        return hash
    }
}

@MainActor
private final class XPBDRejectingExecutor: NativeMetalCommandExecuting {
    enum Failure: Error { case injected }
    var rejectNext = false

    func complete(_ command: MTLCommandBuffer) async throws -> NativeMetalCommandTiming {
        let timing = try await NativeMetalCommandExecutor().complete(command)
        if rejectNext {
            rejectNext = false
            throw Failure.injected
        }
        return timing
    }
}
