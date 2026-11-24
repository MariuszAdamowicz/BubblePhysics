import XCTest
import Metal
import BubblePhysicsReference
@testable import BubblePhysicsNativeMetal
@testable import BubblePhysicsNativeMetalDiagnostics

@MainActor
final class NativeMetalBroadPhaseTests: XCTestCase {
    func testGridCandidatesMatchBruteForceForSparseAndDenseWorlds() async throws {
        for spacing: Float in [0.2, 1.9, 7] {
            var world = ReferenceWorld(configuration: .init(linearDamping: 0), broadPhase: BruteForceBroadPhase())
            for i in 0..<35 {
                world.addBubble(try .init(id: .init(rawValue: i == 34 ? Int.max : i - 17),
                    center: .init(x: Float(i % 7 - 3) * spacing, y: Float(i / 7 - 2) * spacing),
                    mass: 1, targetRadius: i % 3 == 0 ? 1.5 : 0.5))
            }
            let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
            // K_c = 0: bańki nie ruszają się w klatce, więc kandydaci pochodzą z położeń wejściowych (z K_c > 0 siatka przebudowuje się
            // w trakcie klatki, a kandydaci opisują już inny stan). Obwiednia bańki ma zapas r / 4 (bańka bez prędkości i sił, G5-AC3).
            let frame = try await solver.executeFrame(world: world, scenarioStep: 1, contactStiffness: 0)
            var expected: [NativeContactKey] = []
            for i in world.bubbles.indices {
                for j in world.bubbles.indices where j > i {
                    let a = world.bubbles[i], b = world.bubbles[j]
                    let radius = a.targetRadius * 1.25 + b.targetRadius * 1.25
                    if abs(a.center.x - b.center.x) <= radius && abs(a.center.y - b.center.y) <= radius {
                        expected.append(.bubblePair(Int64(a.id.rawValue), Int64(b.id.rawValue)))
                    }
                }
            }
            XCTAssertEqual(solver.candidateKeys, expected.sorted())
            XCTAssertEqual(frame.report.candidatePairCount, expected.count)
            XCTAssertEqual(Set(solver.candidateKeys).count, expected.count)
        }
    }

    // P-B-21: przepełnienie nie odrzuca klatki (dawniej `capacityOverflow`), tylko zwiększa licznik.
    func testCapacityOverflowRaisesCounterAndPublishesFrame() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()), candidateCapacity: 1)
        var world = ReferenceWorld(configuration: .default, broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 1), center: .zero, mass: 1, targetRadius: 1))
        let first = try await solver.executeFrame(world: world, scenarioStep: 1)
        XCTAssertEqual(first.contactCandidateOverflowCount, 0)
        // Środki rozsunięte o 0,1 j: nakładające się, ale nie wspólne (d = 0 to naruszenie asercji kontaktu silnika 4.0.0).
        for id in 2...3 {
            world.addBubble(try .init(id: .init(rawValue: id), center: .init(x: Float(id - 1) * 0.1, y: 0), mass: 1, targetRadius: 1))
        }
        let frame = try await solver.executeFrame(world: world, scenarioStep: 2)
        XCTAssertGreaterThan(frame.contactCandidateOverflowCount, 0, "3 pary przy pojemności 1 muszą zwiększyć licznik")
        XCTAssertEqual(solver.publishedFrame?.bubbles.count, 3, "klatka po przepełnieniu jest opublikowana")
        XCTAssertTrue(frame.bubbles.allSatisfy { $0.center.x.isFinite && $0.center.y.isFinite })
    }

    // Wiersz obiektu trzyma najwyżej k kandydatów; nadmiar odpada po kluczu, więc zostaje k najmniejszych kluczy na obiekt.
    func testDenseCandidatesMatchBruteForceTruncatedToSmallestKeysPerObject() async throws {
        let limit = NativeMetalSolver.candidateLimitPerObject
        var world = ReferenceWorld(configuration: .init(linearDamping: 0), broadPhase: BruteForceBroadPhase())
        let count = limit + 12
        for i in 0..<count {
            world.addBubble(try .init(id: .init(rawValue: i + 1),
                center: .init(x: Float(i % 8) * 0.1, y: Float(i / 8) * 0.1), mass: 1, targetRadius: 1))
        }
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1, contactStiffness: 0)
        var expected: [NativeContactKey] = []
        var dropped = 0
        for i in 0..<count {
            let row = ((i + 1)..<count).map { NativeContactKey.bubblePair(Int64(i + 1), Int64($0 + 1)) }.sorted()
            expected += row.prefix(limit)
            dropped += max(0, row.count - limit)
        }
        XCTAssertGreaterThan(dropped, 0, "scena musi przepełniać wiersze")
        XCTAssertEqual(solver.candidateKeys, expected.sorted())
        XCTAssertGreaterThan(frame.contactCandidateOverflowCount, 0)
        XCTAssertGreaterThanOrEqual(frame.maximumContactCandidatesPerObject, limit)
    }

    // Odcinek jednostronny przed bańką (strona dozwolona 1 to +y): kontakt ma normalną +y, a prawo kontaktu odpycha bańkę od odcinka.
    // Bańka po niedozwolonej stronie odcinka nie jest już scenariuszem kroku: w 4.0.0 jest to naruszenie asercji, a nie korekta strażnika.
    func testSegmentCandidatesAndNarrowPhaseUseGPUWorldGeometry() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var world = ReferenceWorld(configuration: .init(linearDamping: 0), broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: Int.max), center: .zero, mass: 1, targetRadius: 1))
        world.addSegment(.staticSegment(id: .init(rawValue: Int.min), a: .init(x: -2, y: -0.5), b: .init(x: 2, y: -0.5), collisionMode: .oneSided(allowedSide: 1)))
        world.addSegment(.staticSegment(id: .init(rawValue: 10), a: .init(x: 0.9, y: -0.9), b: .init(x: 2, y: -2)))
        world.addSegment(.staticSegment(id: .init(rawValue: 11), a: .init(x: 10, y: -10), b: .init(x: 12, y: -12)))
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        XCTAssertEqual(solver.candidateKeys, [.bubbleSegment(Int64.max, Int64.min), .bubbleSegment(Int64.max, 10)])
        XCTAssertEqual(frame.contacts.count, 1)
        XCTAssertEqual(frame.contacts[0].segment?.rawValue, Int.min)
        XCTAssertEqual(frame.contacts[0].normal.x, 0, accuracy: 1e-6)
        XCTAssertEqual(frame.contacts[0].normal.y, 1, accuracy: 1e-6)
        XCTAssertEqual(frame.contacts[0].allowedSide, 1)
        // Środek stoi 0,5 j nad odcinkiem (d = 0,5 < r): siła F = K · (r − d) · r / d² > 0 odpycha go w górę, bez przejścia przez odcinek.
        XCTAssertGreaterThan(frame.bubbles[0].center.y, 0)
        XCTAssertGreaterThan(frame.bubbles[0].velocity.y, 0)
    }
}
