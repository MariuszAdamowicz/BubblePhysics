import XCTest
import Metal
import BubblePhysicsReference
@testable import BubblePhysicsNativeMetal

@MainActor
final class NativeMetalContactPipelineTests: XCTestCase {
    func testResidualAndIndirectCacheIncludeContactsBeyondFirstThreadgroup() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()),
            configuration: .init(solverIterationCount: 1), collectDispatchStatistics: true)
        var world = ReferenceWorld(configuration: .init(timeStep: 1, linearDamping: 0), broadPhase: BruteForceBroadPhase())
        for id in 0..<300 {
            world.addBubble(try .init(id: .init(rawValue: id),
                center: .init(x: id == 299 ? 2981.5 : Float(id) * 10, y: 0), mass: 1, targetRadius: 1))
        }
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        XCTAssertEqual(frame.contacts.count, 1)
        XCTAssertEqual(frame.bubbles[298].center.x, 2979.75)
        XCTAssertEqual(frame.bubbles[299].center.x, 2981.75)
        XCTAssertEqual(frame.report.solver.initialResidualNorm, 0.5)
        XCTAssertEqual(frame.report.solver.finalResidualNorm, 0)
        XCTAssertEqual(frame.report.solver.positionCorrectionCount, 2)
        XCTAssertEqual(frame.report.solver.iterations, 1)
        XCTAssertEqual(frame.profile.stageGPUWorkItemCounts["residualRecords"], 600)
        XCTAssertEqual(frame.profile.stageGPUWorkItemCounts["cacheDispatchThreads"], 32)
    }

    // Mały graf nie może dispatchować całej pojemności; pusty graf nadal sprawdza finite.
    func testIndirectDispatchTracksCompletedCacheInsteadOfCapacityIncludingEmptyWorld() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()),
            collectDispatchStatistics: true)
        var world = ReferenceWorld(configuration: .default, broadPhase: BruteForceBroadPhase())
        let empty = try await solver.executeFrame(world: world, scenarioStep: 0)
        XCTAssertEqual(empty.profile.stageGPUWorkItemCounts["cacheDispatchThreads"], 32)
        XCTAssertEqual(empty.profile.commandBufferCount, 1)
        for id in 1...17 {
            world.addBubble(try .init(id: .init(rawValue: id), center: .init(x: Float(id) * 1.5, y: 0),
                mass: 1, targetRadius: 1))
        }
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        XCTAssertEqual(frame.contacts.count, 16)
        XCTAssertEqual(frame.profile.stageGPUWorkItemCounts["cacheDispatchThreads"], 32)
        XCTAssertEqual(frame.profile.stageGPUWorkItemCounts["candidateDispatchThreads"], 32)
        XCTAssertGreaterThan(try XCTUnwrap(solver.persistentState).contactCapacity, 32)
        XCTAssertEqual(frame.profile.commandBufferCount, 1)
    }

    // Redukcja musi odwiedzać wszystkie bańki i zachować initial/final oraz liczbę korekcji.
    func testParallelResidualReductionPreservesIterationAccounting() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()),
            configuration: .init(solverIterationCount: 1), collectDispatchStatistics: true)
        var world = ReferenceWorld(configuration: .init(linearDamping: 0), broadPhase: BruteForceBroadPhase())
        for (id, x) in [(1, Float(0)), (2, 1.5), (3, 3)] {
            world.addBubble(try .init(id: .init(rawValue: id), center: .init(x: x, y: 0), mass: 1, targetRadius: 1))
        }
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        XCTAssertEqual(frame.report.solver.initialResidualNorm, 0.5, accuracy: 0.00001)
        XCTAssertEqual(frame.report.solver.finalResidualNorm, 0.375, accuracy: 0.00001)
        XCTAssertEqual(frame.report.solver.iterations, 1)
        XCTAssertEqual(frame.report.solver.positionCorrectionCount, 2)
        XCTAssertEqual(frame.profile.stageGPUWorkItemCounts["residualRecords"], 6)
    }

    // Emisja końców kontaktu musi zachować kolejność sąsiadów, stopnie i usuwanie krawędzi.
    func testParallelAdjacencyUsesOnlyCacheRecordsAndKeepsStableNeighborOrder() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()),
            configuration: .init(solverIterationCount: 4), collectDispatchStatistics: true)
        var world = ReferenceWorld(configuration: .init(linearDamping: 0), broadPhase: BruteForceBroadPhase())
        for (id, x) in [(1, Float(0)), (2, 1.5), (3, 3)] {
            world.addBubble(try .init(id: .init(rawValue: id), center: .init(x: x, y: 0), mass: 1, targetRadius: 1))
        }
        world.addSegment(.staticSegment(id: .init(rawValue: 7), a: .init(x: -5, y: -0.5), b: .init(x: 8, y: -0.5)))
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        let state = try XCTUnwrap(solver.persistentState)
        let degrees = state.adjacencyCounts.contents().bindMemory(to: UInt32.self, capacity: 3)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: degrees, count: 3)), [2, 3, 2])
        let edges = state.adjacency.contents().bindMemory(to: SIMD4<UInt32>.self, capacity: 12)
        // x = cache index, y = neighbor index, z = kind, w = normal sign.
        XCTAssertEqual((0..<2).map { edges[$0].y }, [1, 0])
        XCTAssertEqual((0..<3).map { edges[4 + $0].y }, [0, 2, 0])
        XCTAssertEqual((0..<2).map { edges[8 + $0].y }, [1, 0])
        XCTAssertEqual((0..<3).map { edges[4 + $0].z }, [0, 0, 1])
        XCTAssertEqual(frame.profile.stageGPUWorkItemCounts["adjacencyRecords"], 5)
        var moved = world.bubbles[1]
        moved.center.x = 100; moved.previousCenter.x = 100
        world.updateBubble(moved)
        world.updateSegment(.staticSegment(id: .init(rawValue: 7), a: .init(x: -5, y: -100), b: .init(x: 8, y: -100)))
        let cleared = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 2)
        XCTAssertTrue(cleared.contacts.isEmpty)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: degrees, count: 3)), [0, 0, 0])
    }
}
