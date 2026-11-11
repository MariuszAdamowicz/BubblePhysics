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
            let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
            var expected: [NativeContactKey] = []
            for i in world.bubbles.indices {
                for j in world.bubbles.indices where j > i {
                    let a = world.bubbles[i], b = world.bubbles[j]
                    let radius = a.targetRadius + b.targetRadius
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
        for id in 2...3 {
            world.addBubble(try .init(id: .init(rawValue: id), center: .zero, mass: 1, targetRadius: 1))
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
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
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

    func testSegmentCandidatesAndNarrowPhaseUseGPUWorldGeometry() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var world = ReferenceWorld(configuration: .init(linearDamping: 0), broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: Int.max), center: .zero, mass: 1, targetRadius: 1))
        world.addSegment(.staticSegment(id: .init(rawValue: Int.min), a: .init(x: -2, y: 0.5), b: .init(x: 2, y: 0.5), collisionMode: .oneSided(allowedSide: 1)))
        world.addSegment(.staticSegment(id: .init(rawValue: 10), a: .init(x: 0.9, y: 0.9), b: .init(x: 2, y: 2)))
        world.addSegment(.staticSegment(id: .init(rawValue: 11), a: .init(x: 10, y: 10), b: .init(x: 12, y: 12)))
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        XCTAssertEqual(solver.candidateKeys, [.bubbleSegment(Int64.max, Int64.min), .bubbleSegment(Int64.max, 10)])
        XCTAssertEqual(frame.contacts.count, 1)
        XCTAssertEqual(frame.contacts[0].segment?.rawValue, Int.min)
        XCTAssertEqual(frame.contacts[0].normal.x, 0, accuracy: 1e-6)
        XCTAssertEqual(frame.contacts[0].normal.y, 1, accuracy: 1e-6)
        XCTAssertEqual(frame.contacts[0].allowedSide, 1)
        XCTAssertEqual(frame.contacts[0].penetration, 0, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(frame.bubbles[0].center.y, 1.4999)
    }
}
