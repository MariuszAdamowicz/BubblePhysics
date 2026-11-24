import XCTest
import Metal
import BubblePhysicsReference
@testable import BubblePhysicsNativeMetal
@testable import BubblePhysicsNativeMetalDiagnostics

@MainActor
final class NativeMetalContactPipelineTests: XCTestCase {
    // Emisja końców kontaktu musi zachować kolejność sąsiadów, stopnie i usuwanie krawędzi.
    func testParallelAdjacencyUsesOnlyCacheRecordsAndKeepsStableNeighborOrder() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()),
            configuration: .init(), collectDispatchStatistics: true)
        var world = ReferenceWorld(configuration: .init(linearDamping: 0), broadPhase: BruteForceBroadPhase())
        for (id, x) in [(1, Float(0)), (2, 1.5), (3, 3)] {
            world.addBubble(try .init(id: .init(rawValue: id), center: .init(x: x, y: 0), mass: 1, targetRadius: 1))
        }
        world.addSegment(.staticSegment(id: .init(rawValue: 7), a: .init(x: -5, y: -0.5), b: .init(x: 8, y: -0.5)))
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        let state = try XCTUnwrap(solver.persistentState)
        let degrees = state.adjacencyCounts.contents().bindMemory(to: UInt32.self, capacity: 3)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: degrees, count: 3)), [2, 3, 2])
        // Wiersz obiektu ma stałą długość k (dawniej n + S slotów).
        let stride = NativeMetalSolver.candidateLimitPerObject
        let edges = state.adjacency.contents().bindMemory(to: SIMD4<UInt32>.self, capacity: 3 * stride)
        // x = cache index, y = neighbor index, z = kind, w = normal sign; wiersz posortowany po (rodzaj, sąsiad).
        XCTAssertEqual((0..<2).map { edges[$0].y }, [1, 0])
        XCTAssertEqual((0..<3).map { edges[stride + $0].y }, [0, 2, 0])
        XCTAssertEqual((0..<2).map { edges[2 * stride + $0].y }, [1, 0])
        XCTAssertEqual((0..<3).map { edges[stride + $0].z }, [0, 0, 1])
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
