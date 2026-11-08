import BubblePhysics
import BubblePhysicsMetalRender
import Metal
import XCTest

/// Sonda determinizmu (G10-AC5, P-B-9): ta sama scena z tymi samymi transakcjami, dwa razy na tym samym
/// urządzeniu, daje identyczny opublikowany stan. Hashuje bity liczb, więc różnica o 1 ULP zostaje wykryta.
@MainActor
final class PublishedStateDeterminismTests: XCTestCase {
    private struct Run {
        let hash: UInt64
        let completedSteps: UInt64
        let bubbleCount: Int
    }

    private func fnv1a(_ values: some Sequence<UInt32>, into hash: inout UInt64) {
        for value in values {
            for shift in stride(from: 0, to: 32, by: 8) {
                hash = (hash ^ UInt64((value >> UInt32(shift)) & 0xFF)) &* 0x100_0000_01B3
            }
        }
    }

    private func run(steps: Int, device: MTLDevice) async throws -> Run {
        let world = try BubbleWorld.makeBenchmarkWorld(configuration: try Stress300Scene.configuration(),
            device: device, solverIterationLimit: 4)
        world.submit(try Stress300Scene.initialTransaction())
        var completed: UInt64 = 0
        for index in 0..<steps {
            if index > 0 { world.submit(try Stress300Scene.triangleReplacement(step: index)) }
            completed = await world.advance(by: 1.0 / 60).stepIndex
        }
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        let contours = world.debugContourSnapshot()
        for id in contours.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            fnv1a([UInt32(truncatingIfNeeded: id.rawValue)], into: &hash)
            for point in contours[id] ?? [] { fnv1a([point.x.bitPattern, point.y.bitPattern], into: &hash) }
        }
        return Run(hash: hash, completedSteps: completed, bubbleCount: contours.count)
    }

    func testStress300PublishedStateIsIdenticalAcrossTwoRunsOf300Steps() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let first = try await run(steps: 300, device: device)
        let second = try await run(steps: 300, device: device)
        XCTAssertEqual(first.completedSteps, 300)
        XCTAssertEqual(first.bubbleCount, 300)
        XCTAssertEqual(first.hash, second.hash, "stan po 300 krokach różni się między przebiegami")
    }

    func testHashReactsToStateChange() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let early = try await run(steps: 1, device: device)
        let late = try await run(steps: 300, device: device)
        XCTAssertNotEqual(early.hash, late.hash)
    }
}
