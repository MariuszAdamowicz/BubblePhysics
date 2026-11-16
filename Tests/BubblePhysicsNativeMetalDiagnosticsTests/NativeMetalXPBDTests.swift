import XCTest
import Metal
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
        let first = try makeSolver(iterations: 32)
        let second = try makeSolver(iterations: 32)
        let world = try makeWorld(centers: [0, 1.5, 3])
        for step in 1...60 {
            let a = try await first.executeFrame(world: world, scenarioStep: step)
            let b = try await second.executeFrame(world: world, scenarioStep: step)
            assertFinite(a)
            XCTAssertEqual(stateHash(a), stateHash(b), "Klatka \(step)")
            for index in 0..<2 {
                let gap = (a.bubbles[index + 1].center - a.bubbles[index].center).length
                // Pierwsza klatka: dokładnie 1,75; potem bańki rozchodzą się z nabytą prędkością (bez tłumienia).
                if step == 1 { XCTAssertEqual(gap, 1.75, accuracy: 0.0001) } else { XCTAssertGreaterThanOrEqual(gap, 1.75 - 0.0001, "Klatka \(step)") }
            }
        }
    }

    // Bliźniak (CD-D-20): bez limitu pary oczekiwanie z v2.1.0, pełne rozdzielenie w jednym kroku.
    func testThreeBubbleChainIsRepeatableAndRaceFreeWithoutPairCorrectionLimit() async throws {
        let first = try makeSolver(iterations: 32, pairCorrectionLimit: false)
        let second = try makeSolver(iterations: 32, pairCorrectionLimit: false)
        let world = try makeWorld(centers: [0, 1.5, 3])
        for step in 1...60 {
            let a = try await first.executeFrame(world: world, scenarioStep: step)
            let b = try await second.executeFrame(world: world, scenarioStep: step)
            assertFinite(a)
            XCTAssertEqual(stateHash(a), stateHash(b), "Klatka \(step)")
            for index in 0..<2 {
                XCTAssertGreaterThanOrEqual((a.bubbles[index + 1].center - a.bubbles[index].center).length, 1.9999)
            }
        }
    }

    // Usunięcie applyWarmStart albo zerowanie poprawnie dopasowanej lambda daje koszt cold-startu.
    // Z limitem λ pary (CD-D-9) para nie dochodzi do zbieżności w jednym kroku (λ ≤ 0,25·min r / max invMass), więc
    // kolejne klatki tego samego wejścia zużywają cały budżet: zostaje „nie więcej niż cold start” (bliźniak: ...WithoutPairCorrectionLimit).
    func testWarmStartNeedsNoMoreIterationsThanColdStartAfterFirstFrame() async throws {
        let warm = try makeSolver(iterations: 64)
        let world = try makeWorld(centers: [0, 1.5, 3])
        let initial = try await warm.executeFrame(snapshot: .init(world: world), scenarioStep: 1)
        XCTAssertGreaterThan(initial.report.solver.iterations, 0)
        for step in 2...5 {
            let warmed = try await warm.executeFrame(snapshot: .init(world: world), scenarioStep: step)
            let cold = try makeSolver(iterations: 64)
            let coldFrame = try await cold.executeFrame(snapshot: .init(world: world), scenarioStep: step)
            XCTAssertEqual(warmed.telemetry.cacheHitCount, 2)
            XCTAssertLessThanOrEqual(warmed.report.solver.iterations, coldFrame.report.solver.iterations)
            XCTAssertLessThanOrEqual(warmed.report.solver.iterations, initial.report.solver.iterations)
            assertFinite(warmed)
        }
    }

    // Bliźniak (CD-D-20): bez limitu pary oczekiwanie z v2.1.0, warm start zbiega szybciej niż pierwsza klatka.
    func testWarmStartNeedsNoMoreIterationsThanColdStartAfterFirstFrameWithoutPairCorrectionLimit() async throws {
        let warm = try makeSolver(iterations: 64, pairCorrectionLimit: false)
        let world = try makeWorld(centers: [0, 1.5, 3])
        let initial = try await warm.executeFrame(snapshot: .init(world: world), scenarioStep: 1)
        XCTAssertGreaterThan(initial.report.solver.iterations, 0)
        for step in 2...5 {
            // Pełny snapshot jawnie ponawia kontrolowane wejście, zachowując cache solvera.
            let warmed = try await warm.executeFrame(snapshot: .init(world: world), scenarioStep: step)
            let cold = try makeSolver(iterations: 64, pairCorrectionLimit: false)
            let coldFrame = try await cold.executeFrame(snapshot: .init(world: world), scenarioStep: step)
            XCTAssertEqual(warmed.telemetry.cacheHitCount, 2)
            XCTAssertLessThanOrEqual(warmed.report.solver.iterations, coldFrame.report.solver.iterations)
            XCTAssertLessThan(warmed.report.solver.iterations, initial.report.solver.iterations)
            XCTAssertTrue(warmed.report.solver.converged)
            assertFinite(warmed)
        }
    }

    // Limit λ pary (CD-D-9): odstęp pierwszej pary po jednym kroku to 1,4 + 0,25 = 1,65 (środkowa bańka stoi w miejscu).
    func testSameInputProducesSamePublishedStateHash() async throws {
        let world = try makeWorld(centers: [0, 1.4, 2.9])
        var hashes: [UInt64] = []
        for _ in 0..<4 {
            let solver = try makeSolver(iterations: 32)
            let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
            XCTAssertEqual((frame.bubbles[1].center - frame.bubbles[0].center).length, 1.65, accuracy: 0.0001)
            hashes.append(stateHash(frame))
            XCTAssertEqual(stateHash(try XCTUnwrap(solver.publishedFrame)), hashes.last)
        }
        XCTAssertTrue(hashes.allSatisfy { $0 == hashes[0] })
    }

    // Bliźniak (CD-D-20): bez limitu pary oczekiwanie z v2.1.0.
    func testSameInputProducesSamePublishedStateHashWithoutPairCorrectionLimit() async throws {
        let world = try makeWorld(centers: [0, 1.4, 2.9])
        var hashes: [UInt64] = []
        for _ in 0..<4 {
            let solver = try makeSolver(iterations: 32, pairCorrectionLimit: false)
            let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
            XCTAssertGreaterThanOrEqual((frame.bubbles[1].center - frame.bubbles[0].center).length, 1.9999)
            hashes.append(stateHash(frame))
            XCTAssertEqual(stateHash(try XCTUnwrap(solver.publishedFrame)), hashes.last)
        }
        XCTAssertTrue(hashes.allSatisfy { $0 == hashes[0] })
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
        let solver = try makeSolver(iterations: 3)
        let world = try makeInverseMassWorld()
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        XCTAssertEqual(frame.bubbles[0].center.x, -1.0 / 12, accuracy: 0.00001)
        XCTAssertEqual(frame.bubbles[1].center.x, 1.75, accuracy: 0.00001)
        XCTAssertEqual(3 * frame.bubbles[0].velocity.x + frame.bubbles[1].velocity.x, 0, accuracy: 0.0001)
    }

    // Bliźniak (CD-D-20): bez limitu pary oczekiwanie z v2.1.0.
    func testInverseMassWeightsCorrectionsAndPreservesCenterOfMassWithoutPairCorrectionLimit() async throws {
        let solver = try makeSolver(iterations: 3, pairCorrectionLimit: false)
        let world = try makeInverseMassWorld()
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        XCTAssertEqual(frame.bubbles[0].center.x, -0.125, accuracy: 0.00001)
        XCTAssertEqual(frame.bubbles[1].center.x, 1.875, accuracy: 0.00001)
        XCTAssertEqual(3 * frame.bubbles[0].velocity.x + frame.bubbles[1].velocity.x, 0, accuracy: 0.0001)
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
        let solver = try makeSolver(iterations: 1)
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

    // Bliźniak (CD-D-20): bez limitu pary warm-start ogranicza dopiero dawny próg r / (invMass · stopień).
    func testWarmStartBoundsAnOversizedMatchedMultiplierByBubbleRadiusWithoutPairCorrectionLimit() async throws {
        let solver = try makeSolver(iterations: 1, pairCorrectionLimit: false)
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
