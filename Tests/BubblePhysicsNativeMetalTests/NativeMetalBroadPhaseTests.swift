import XCTest
import Metal
import BubblePhysicsReference
@testable import BubblePhysicsNativeMetal

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

    func testCapacityOverflowRejectsFrameBeforePublication() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()), candidateCapacity: 1)
        var world = ReferenceWorld(configuration: .default, broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 1), center: .zero, mass: 1, targetRadius: 1))
        _ = try await solver.executeFrame(world: world, scenarioStep: 1)
        let state = try XCTUnwrap(solver.persistentState)
        let published = state.publishedBubbles
        for id in 2...3 {
            world.addBubble(try .init(id: .init(rawValue: id), center: .zero, mass: 1, targetRadius: 1))
        }
        do {
            _ = try await solver.executeFrame(world: world, scenarioStep: 2)
            XCTFail("Overflow musi odrzucić całą klatkę")
        } catch NativeMetalSolverError.capacityOverflow {}
        XCTAssertTrue(state.publishedBubbles === published)
        XCTAssertEqual(solver.publishedFrame?.bubbles.count, 1)
        XCTAssertEqual(solver.cachedContacts.count, 0)
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
        XCTAssertEqual(frame.contacts[0].penetration, 0.5, accuracy: 1e-6)
    }
}
