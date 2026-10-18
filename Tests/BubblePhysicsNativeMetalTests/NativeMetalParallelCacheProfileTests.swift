import XCTest
import Foundation
import Metal
import BubblePhysicsReference
@testable import BubblePhysicsNativeMetal

/// Reprodukowalny profil Maca: pełny command buffer oraz izolowany, rzeczywisty kernel cache.
/// Czasy są diagnostyką; bramka urządzeniowa pozostaje poza tym testem.
@MainActor
final class NativeMetalParallelCacheProfileTests: XCTestCase {
    func testProfileStressAndDenseThreeHundredBubbleCache() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shaders = root.appendingPathComponent("Sources/BubblePhysicsNativeMetal/Shaders")
        let source = try String(contentsOf: shaders.appendingPathComponent("NativeGeometryKernels.metal-source"), encoding: .utf8)
            + "\n" + String(contentsOf: shaders.appendingPathComponent("NativeXPBDKernels.metal-source"), encoding: .utf8)
        let library = try await device.makeLibrary(source: source, options: nil)
        let pipeline = try await device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "nativeMatchContactCache")))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        for dense in [false, true] {
            var world = try ReferenceConvergenceScenario(scene: .stress300, newtonIterationLimit: 8).makeWorld()
            if dense {
                // Profil przepustowości cache wymaga gęstego grafu, ale nie
                // wymusza pełnego zawarcia mniejszych kół w większych. Równe
                // promienie zachowują wszystkie 44 850 par i 600 kontaktów ścian.
                let radius = try XCTUnwrap(world.bubbles.map(\.targetRadius).max())
                for var bubble in world.bubbles {
                    bubble.center = .zero; bubble.previousCenter = .zero
                    bubble.targetRadius = radius
                    world.updateBubble(bubble)
                }
            }
            let solver = try NativeMetalSolver(device: device)
            var fullTimes: [Double] = []
            for step in 0..<35 {
                // Profil cache utrzymuje geometrię źródłową; dynamiczny przebieg jest w XPBDTests.
                let frame = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: step)
                if step >= 5 { fullTimes.append(frame.telemetry.gpuMilliseconds) }
            }
            XCTAssertEqual(solver.candidateKeys.count, dense ? 45_450 : 233)
            XCTAssertEqual(solver.cachedContacts.count, dense ? 45_450 : 219)
            let state = try XCTUnwrap(solver.persistentState)
            var matchTimes: [Double] = []
            for _ in 0..<8 {
                let command = try XCTUnwrap(queue.makeCommandBuffer())
                let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
                encoder.setComputePipelineState(pipeline)
                let buffers = [state.contactCache, state.activeContacts, state.mergedCache, state.contactControl,
                    state.invalidations, state.publishedBubbles, state.segments, state.control,
                    state.scanValues, state.dispatchStatistics]
                for (index, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: index) }
                encoder.dispatchThreads(.init(width: state.contactCapacity, height: 1, depth: 1),
                    threadsPerThreadgroup: .init(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
                encoder.endEncoding()
                let timing = try await NativeMetalCommandExecutor().complete(command)
                matchTimes.append(timing.gpuMilliseconds)
            }
            let result: [String: Any] = ["device": device.name, "scene": dense ? "stress-300-dense" : "stress-300",
                "candidates": solver.candidateKeys.count, "cache": solver.cachedContacts.count,
                "fullCommandP95Milliseconds": percentile(fullTimes, 0.95),
                "isolatedMatchMedianMilliseconds": percentile(matchTimes, 0.5),
                "warmup": 5, "measured": 30, "isolatedSamples": 8]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print("NATIVE_CACHE_PROFILE " + String(decoding: data, as: UTF8.self))
        }
    }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count) * fraction).rounded(.up)) - 1)]
    }
}
