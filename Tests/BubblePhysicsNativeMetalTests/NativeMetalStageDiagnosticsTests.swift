import XCTest
import Metal
import BubblePhysicsReference
@testable import BubblePhysicsNativeMetal

@MainActor
final class NativeMetalStageDiagnosticsTests: XCTestCase {
    func testDiagnosticsExposePositionsBeforeAndAfterPostSolveGuards() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let solver = try NativeMetalSolver(device: device, collectStageDiagnostics: true)
        let runner = NativeMetalWorldRunner(executor: solver)
        let cpu = try VisualSimulationDriver(backend: .cpu, density: .six)
        let gpu = try VisualSimulationDriver(backend: .nativeMetal, density: .six, nativeRunner: runner)
        _ = await cpu.advance(to: 0)
        _ = await gpu.advance(to: 0)
        var firstVisibleDivergence: (frame: Int, postSolver: Double, postGuard: Double, guardDisplacement: Double)?
        var maximumGuardDisplacement = 0.0

        for frame in 1...24 {
            let phase = 2 * Float.pi * Float(frame) / 24
            let command = ReferenceVector2(x: ReferenceVisualSceneFactory.initialPolygonCenter.x + 80 * sinf(phase),
                                           y: ReferenceVisualSceneFactory.initialPolygonCenter.y + 55 * cosf(phase * 2))
            cpu.movePolygon(to: command)
            gpu.movePolygon(to: command)
            _ = await cpu.advance(to: Double(frame) / 60)
            _ = await gpu.advance(to: Double(frame) / 60)
            let stages = try XCTUnwrap(solver.stageDiagnostics)
            let cpuByID = Dictionary(uniqueKeysWithValues: cpu.frame.snapshot.bubbles.map { ($0.id, $0) })
            let gpuBubbles = gpu.frame.snapshot.bubbles
            func normalizedDifference(_ positions: [ReferenceVector2]) -> Double {
                Double(zip(gpuBubbles, positions).reduce(Float.zero) { total, pair in
                    guard let cpuBubble = cpuByID[pair.0.id] else { return total }
                    return total + (cpuBubble.center - pair.1).length / pair.0.targetRadius
                }) / Double(gpuBubbles.count)
            }
            let postSolverDifference = normalizedDifference(stages.postSolverPositions)
            let postGuardDifference = normalizedDifference(stages.postGuardPositions)
            let guardDisplacement = Double(zip(stages.postSolverPositions, stages.postGuardPositions).reduce(Float.zero) {
                $0 + ($1.0 - $1.1).length
            }) / Double(gpuBubbles.count)
            maximumGuardDisplacement = max(maximumGuardDisplacement, guardDisplacement)
            if firstVisibleDivergence == nil, postGuardDifference > 0.05 {
                firstVisibleDivergence = (frame, postSolverDifference, postGuardDifference, guardDisplacement)
            }
        }

        let stages = try XCTUnwrap(solver.stageDiagnostics)
        XCTAssertEqual(stages.postSolverPositions.count, 6)
        XCTAssertEqual(stages.postGuardPositions.count, 6)
        XCTAssertTrue(stages.postSolverPositions.allSatisfy(\.isFinite))
        XCTAssertTrue(stages.postGuardPositions.allSatisfy(\.isFinite))

        let divergence = try XCTUnwrap(firstVisibleDivergence)
        print("stage_diagnostics density=6 first_visible_divergence_frame=\(divergence.frame) post_solver_center_mean=\(divergence.postSolver) post_guard_center_mean=\(divergence.postGuard) guard_displacement_world_mean=\(divergence.guardDisplacement) maximum_guard_displacement_world_mean=\(maximumGuardDisplacement)")
        XCTAssertTrue([divergence.postSolver, divergence.postGuard, divergence.guardDisplacement,
                       maximumGuardDisplacement].allSatisfy(\.isFinite))
    }
}
