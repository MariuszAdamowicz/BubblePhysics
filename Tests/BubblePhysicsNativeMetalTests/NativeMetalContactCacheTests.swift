import XCTest
import Metal
import BubblePhysicsReference
@testable import BubblePhysicsNativeMetal

@MainActor
final class NativeMetalContactCacheTests: XCTestCase {
    func testBubblePairKeyIsOrderIndependent() {
        let a = NativeContactKey.bubblePair(Int64.min, Int64.max)
        XCTAssertEqual(a, .bubblePair(Int64.max, Int64.min))
        XCTAssertNotEqual(a, .bubblePair(Int64.min + (1 << 32), Int64.max))
        XCTAssertNotEqual(a, .bubbleSegment(Int64.min, Int64.max))
        XCTAssertNotEqual(NativeContactKey.bubbleSegment(1, 2), .bubbleSegment(2, 1))
    }

    func testContactExpiresAfterConfiguredMisses() async throws {
        let solver = try makeSolver(expiry: 2)
        var world = try cacheWorld()
        _ = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 1)
        XCTAssertEqual(solver.cachedContacts.count, 2)
        var b = world.bubbles[1]; b.center.x = 8; world.updateBubble(b)
        _ = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 2)
        XCTAssertEqual(solver.cachedContacts.first { $0.key == .bubblePair(1, 2) }?.lastSeenFrame, 1)
        _ = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 3)
        XCTAssertNotNil(solver.cachedContacts.first { $0.key == .bubblePair(1, 2) })
        _ = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 4)
        XCTAssertNil(solver.cachedContacts.first { $0.key == .bubblePair(1, 2) })
        XCTAssertEqual(solver.cachedContacts.first?.key, .bubblePair(3, 4))
    }

    func testTeleportInvalidatesOnlyIncidentContactCache() async throws {
        let solver = try makeSolver()
        var world = try cacheWorld()
        _ = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 1)
        _ = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 2)
        var b = world.bubbles[0]; b.center.x = -100; world.updateBubble(b)
        let frame = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 3)
        XCTAssertNil(solver.cachedContacts.first { $0.key == .bubblePair(1, 2) })
        XCTAssertEqual(solver.cachedContacts.first?.key, .bubblePair(3, 4))
        XCTAssertEqual(solver.cachedContacts.first?.age, 3)
        XCTAssertEqual(frame.telemetry.cacheResetCount, 1)
    }

    func testSegmentRevisionInvalidatesItsContacts() async throws {
        let solver = try makeSolver()
        var world = try cacheWorld()
        world.addSegment(.staticSegment(id: .init(rawValue: Int.max), a: .init(x: -2, y: 0.5), b: .init(x: 4, y: 0.5)))
        _ = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 1)
        _ = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 2)
        world.updateSegment(.staticSegment(id: .init(rawValue: Int.max), a: .init(x: -3, y: 0.6), b: .init(x: 4, y: 0.6)))
        let frame = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 3)
        let segments = solver.cachedContacts.filter { $0.key.kind == 1 }
        XCTAssertEqual(segments.count, 2)
        // Reset dotyczy wejścia warm-start; zatwierdzony solver wylicza już nową lambdę.
        XCTAssertTrue(segments.allSatisfy { $0.age == 1 && $0.lambda > 0 && $0.flags != 0 })
        XCTAssertEqual(solver.cachedContacts.first { $0.key == .bubblePair(3, 4) }?.age, 3)
        XCTAssertEqual(frame.telemetry.cacheResetCount, 2)
    }

    func testWarmStartMatchesFullIDsAfterLowerIDInsertion() async throws {
        let solver = try makeSolver()
        var world = try cacheWorld()
        _ = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 1)
        let state = try XCTUnwrap(solver.persistentState)
        let cache = state.contactCache.contents().bindMemory(to: NativeContactCacheRecord.self, capacity: state.contactCapacity)
        cache[0].lambda = 0.75
        cache[1].lambda = 1.25
        world.addBubble(try .init(id: .init(rawValue: Int.min), center: .init(x: 100, y: 0), mass: 1, targetRadius: 1))
        let frame = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 2)
        XCTAssertEqual(solver.cachedContacts.map(\.key), [.bubblePair(1, 2), .bubblePair(3, 4)])
        for record in solver.cachedContacts { XCTAssertEqual(record.lambda, 0.25, accuracy: 0.000001) }
        XCTAssertEqual(frame.bubbles.first { $0.id.rawValue == 1 }?.center.x, -0.25)
        XCTAssertEqual(frame.bubbles.first { $0.id.rawValue == 3 }?.center.x, 19.75)
        XCTAssertEqual(frame.telemetry.cacheHitCount, 2)
        XCTAssertEqual(frame.telemetry.cacheResetCount, 0)
    }

    func testCacheOverflowPreservesPreviouslyPublishedRecords() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()),
            configuration: .init(teleportDistanceMultiplier: 100), candidateCapacity: 1)
        var world = try cacheWorld()
        var fourth = world.bubbles[3]; fourth.center.x = 25; world.updateBubble(fourth)
        _ = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 1)
        let state = try XCTUnwrap(solver.persistentState)
        let publishedCache = state.contactCache
        let originalRecords = solver.cachedContacts
        var second = world.bubbles[1]; second.center.x = 5; world.updateBubble(second)
        fourth.center.x = 21.5; world.updateBubble(fourth)
        do {
            _ = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 2)
            XCTFail("Zachowany stary kontakt i nowy kontakt przekraczają cache")
        } catch NativeMetalSolverError.capacityOverflow {}
        XCTAssertTrue(state.contactCache === publishedCache)
        XCTAssertEqual(solver.cachedContacts, originalRecords)
        XCTAssertEqual(state.contactCache.contents().load(as: NativeContactCacheRecord.self), originalRecords[0])
        // Ponowienie identycznego wejścia po błędzie ma identyczny wynik i nie publikuje scratcha.
        do {
            _ = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 3)
            XCTFail("Ponowienie overflow musi ponownie odrzucić klatkę")
        } catch NativeMetalSolverError.capacityOverflow {}
        XCTAssertEqual(solver.cachedContacts, originalRecords)
    }

    func testReturningContactWithinExpiryRetainsLambda() async throws {
        let solver = try makeSolver(expiry: 2)
        var world = try cacheWorld()
        _ = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 1)
        let state = try XCTUnwrap(solver.persistentState)
        state.contactCache.contents().bindMemory(to: NativeContactCacheRecord.self, capacity: state.contactCapacity)[0].lambda = 0.5
        var b = world.bubbles[1]; b.center.x = 8; world.updateBubble(b)
        _ = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 2)
        _ = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 3)
        XCTAssertEqual(solver.cachedContacts.first { $0.key == .bubblePair(1, 2) }?.lambda, 0.5)
        b.center.x = 1.5; world.updateBubble(b)
        _ = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 4)
        let record = try XCTUnwrap(solver.cachedContacts.first { $0.key == .bubblePair(1, 2) })
        XCTAssertEqual(record.lambda, 0.25)
        XCTAssertEqual(record.age, 2)
        XCTAssertEqual(record.lastSeenFrame, 4)
    }

    func testMaximumExpiryDoesNotOverflowWarmStartValidity() async throws {
        let solver = try makeSolver(expiry: Int.max)
        let world = try cacheWorld()
        _ = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 1)
        let state = try XCTUnwrap(solver.persistentState)
        state.contactCache.contents().bindMemory(to: NativeContactCacheRecord.self, capacity: state.contactCapacity)[0].lambda = 0.5
        let frame = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 2)
        XCTAssertEqual(solver.cachedContacts[0].lambda, 0.25)
        XCTAssertEqual(frame.telemetry.cacheHitCount, 2)
        XCTAssertEqual(frame.telemetry.cacheResetCount, 0)
    }

    func testDenseThreeHundredBubbleCacheUsesOneWorkItemPerContact() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()), collectDispatchStatistics: true)
        var world = ReferenceWorld(configuration: .init(linearDamping: 0), broadPhase: BruteForceBroadPhase())
        for id in 0..<300 {
            world.addBubble(try .init(id: .init(rawValue: id), center: .zero, mass: 1, targetRadius: 1))
        }
        _ = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 1)
        let frame = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 2)
        XCTAssertEqual(solver.cachedContacts.count, 44_850)
        XCTAssertEqual(frame.telemetry.cacheHitCount, 44_850)
        XCTAssertEqual(frame.profile.stageGPUWorkItemCounts["cacheMatch"], 44_850)
        XCTAssertEqual(frame.profile.stageGPUWorkItemCounts["cacheRetain"], 44_850)
        XCTAssertEqual(frame.profile.stageGPUWorkItemCounts["cacheCompaction"], 44_850)
        XCTAssertEqual(frame.profile.stageGPUWorkItemCounts["candidateCompaction"], 44_850)
        XCTAssertEqual(solver.cachedContacts.map(\.key), solver.cachedContacts.map(\.key).sorted())
        XCTAssertTrue(solver.cachedContacts.allSatisfy { $0.age == 2 })
    }

    func testParallelMergeKeepsMissesHitsAndNewContactsInKeyOrder() async throws {
        let solver = try makeSolver()
        var world = try cacheWorld()
        _ = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 1)
        let state = try XCTUnwrap(solver.persistentState)
        let cache = state.contactCache.contents().bindMemory(to: NativeContactCacheRecord.self, capacity: state.contactCapacity)
        cache[0].lambda = 0.75; cache[1].lambda = 1.25
        var b = world.bubbles[1]; b.center.x = 8; world.updateBubble(b)
        world.addBubble(try .init(id: .init(rawValue: 5), center: .init(x: 21.6, y: 0), mass: 1, targetRadius: 1))
        let frame = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 2)
        XCTAssertEqual(solver.cachedContacts.map(\.key), [.bubblePair(1, 2), .bubblePair(3, 4), .bubblePair(3, 5), .bubblePair(4, 5)])
        XCTAssertEqual(solver.cachedContacts[0].lambda, 0.75)
        XCTAssertTrue(solver.cachedContacts.dropFirst().allSatisfy { $0.lambda >= 0 && $0.lambda.isFinite })
        XCTAssertEqual(solver.cachedContacts.map(\.age), [1, 2, 1, 1])
        XCTAssertEqual(frame.contacts.count, 3)
        XCTAssertEqual(frame.telemetry.cacheHitCount, 1)
    }

    private func makeSolver(expiry: Int = 30) throws -> NativeMetalSolver {
        try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()),
            configuration: .init(cacheExpiryFrames: expiry, teleportDistanceMultiplier: 10))
    }

    private func cacheWorld() throws -> ReferenceWorld {
        var world = ReferenceWorld(configuration: .init(linearDamping: 0), broadPhase: BruteForceBroadPhase())
        for (id, x) in [(1, Float(0)), (2, 1.5), (3, 20), (4, 21.5)] {
            world.addBubble(try .init(id: .init(rawValue: id), center: .init(x: x, y: 0), mass: 1, targetRadius: 1))
        }
        return world
    }
}
