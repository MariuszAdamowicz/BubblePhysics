import Foundation
import BubblePhysicsReference

/// Krótki, deterministyczny probe porównujący odbiór ruchu CPU i native Metal.
/// Nie jest częścią pętli gry ani nie wybiera backendu produkcyjnego.
public struct NativeMetalVisualReplayFrame: Sendable {
    public let gpuBackend: ReferenceSimulationBackend
    public let cpuBubbleCount: Int
    public let gpuBubbleCount: Int
    /// Średnia różnica położeń środków, znormalizowana promieniem baniek.
    public let centerDifferenceMean: Double
    /// Średnia różnica promieni konturu w 32 równomiernych kierunkach, znormalizowana promieniem.
    public let contourRadialDifferenceMean: Double
    public let contactCountDifference: Int
}

public struct NativeMetalVisualReplayReport: Sendable {
    public let frames: [NativeMetalVisualReplayFrame]
    public let centerDifferenceP95: Double
    public let contourRadialDifferenceP95: Double
    public let cpuContourStepMaximum: Double
    public let gpuContourStepMaximum: Double
    public let contactCountDifferenceMean: Double
}

public enum NativeMetalVisualReplayError: Error, Equatable {
    case unavailable
    case gpuFallback(String?)
}

/// Uruchamia oba backendy od identycznego stanu i podaje im tę samą trajektorię przeszkody.
@MainActor
public enum NativeMetalVisualReplay {
    public static func compare(density: ReferenceVisualDensity, frameCount: Int,
                               solverIterationCount: Int = 4) async throws -> NativeMetalVisualReplayReport {
        guard frameCount > 0,
              let nativeRunner = NativeMetalWorldRunner(configuration: .init(solverIterationCount: solverIterationCount))
        else { throw NativeMetalVisualReplayError.unavailable }

        let cpu = try VisualSimulationDriver(backend: .cpu, density: density)
        let gpu = try VisualSimulationDriver(backend: .nativeMetal, density: density, nativeRunner: nativeRunner)
        _ = await cpu.advance(to: 0)
        _ = await gpu.advance(to: 0)

        var frames: [NativeMetalVisualReplayFrame] = []
        var cpuPreviousRadii: [ReferenceBubbleID: [Float]] = [:]
        var gpuPreviousRadii: [ReferenceBubbleID: [Float]] = [:]
        var cpuContourStepMaximum = 0.0
        var gpuContourStepMaximum = 0.0

        for index in 1...frameCount {
            let command = scriptedPolygonCenter(frame: index, totalFrames: frameCount)
            cpu.movePolygon(to: command)
            gpu.movePolygon(to: command)
            let time = Double(index) * ReferenceVisualRunner.fixedTimeStep
            let cpuFrame = await cpu.advance(to: time)
            let gpuFrame = await gpu.advance(to: time)
            guard gpuFrame.actualBackend == .nativeMetal else {
                throw NativeMetalVisualReplayError.gpuFallback(gpuFrame.fallbackReason)
            }

            let cpuRadii = radialProfiles(snapshot: cpuFrame.snapshot)
            let gpuRadii = radialProfiles(snapshot: gpuFrame.snapshot)
            cpuContourStepMaximum = max(cpuContourStepMaximum,
                                        maximumProfileStep(from: cpuPreviousRadii, to: cpuRadii))
            gpuContourStepMaximum = max(gpuContourStepMaximum,
                                        maximumProfileStep(from: gpuPreviousRadii, to: gpuRadii))
            cpuPreviousRadii = cpuRadii
            gpuPreviousRadii = gpuRadii

            frames.append(.init(gpuBackend: gpuFrame.actualBackend,
                                cpuBubbleCount: cpuFrame.snapshot.bubbles.count,
                                gpuBubbleCount: gpuFrame.snapshot.bubbles.count,
                                centerDifferenceMean: meanCenterDifference(cpu: cpuFrame.snapshot, gpu: gpuFrame.snapshot),
                                contourRadialDifferenceMean: meanProfileDifference(cpuRadii, gpuRadii),
                                contactCountDifference: abs(cpuFrame.snapshot.contacts.count - gpuFrame.snapshot.contacts.count)))
        }

        return .init(frames: frames,
                     centerDifferenceP95: percentile(frames.map(\.centerDifferenceMean), percentile: 0.95),
                     contourRadialDifferenceP95: percentile(frames.map(\.contourRadialDifferenceMean), percentile: 0.95),
                     cpuContourStepMaximum: cpuContourStepMaximum,
                     gpuContourStepMaximum: gpuContourStepMaximum,
                     contactCountDifferenceMean: frames.isEmpty ? 0 : Double(frames.map(\.contactCountDifference).reduce(0, +)) / Double(frames.count))
    }

    private static func scriptedPolygonCenter(frame: Int, totalFrames: Int) -> ReferenceVector2 {
        let phase = 2 * Float.pi * Float(frame) / Float(max(1, totalFrames))
        return .init(x: ReferenceVisualSceneFactory.initialPolygonCenter.x + 80 * sinf(phase),
                     y: ReferenceVisualSceneFactory.initialPolygonCenter.y + 55 * cosf(phase * 2))
    }

    private static func meanCenterDifference(cpu: ReferenceVisualSnapshot,
                                             gpu: ReferenceVisualSnapshot) -> Double {
        let gpuByID = Dictionary(uniqueKeysWithValues: gpu.bubbles.map { ($0.id, $0) })
        let differences = cpu.bubbles.compactMap { bubble -> Double? in
            guard let other = gpuByID[bubble.id] else { return nil }
            return Double((bubble.center - other.center).length / max(bubble.targetRadius, Float.ulpOfOne))
        }
        return differences.isEmpty ? 0 : differences.reduce(0, +) / Double(differences.count)
    }

    private static func radialProfiles(snapshot: ReferenceVisualSnapshot) -> [ReferenceBubbleID: [Float]] {
        let bubbles = Dictionary(uniqueKeysWithValues: snapshot.bubbles.map { ($0.id, $0) })
        return Dictionary(uniqueKeysWithValues: snapshot.contours.compactMap { id, contour -> (ReferenceBubbleID, [Float])? in
            guard let bubble = bubbles[id], contour.count >= 3 else { return nil }
            let samples = (0..<32).map { index -> Float in
                let point = contour[index * contour.count / 32]
                return (point - bubble.center).length / max(bubble.targetRadius, Float.ulpOfOne)
            }
            return (id, samples)
        })
    }

    private static func meanProfileDifference(_ cpu: [ReferenceBubbleID: [Float]],
                                              _ gpu: [ReferenceBubbleID: [Float]]) -> Double {
        let values = cpu.compactMap { id, left -> Double? in
            guard let right = gpu[id], left.count == right.count else { return nil }
            return Double(zip(left, right).map { abs($0 - $1) }.reduce(0, +)) / Double(left.count)
        }
        return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private static func maximumProfileStep(from previous: [ReferenceBubbleID: [Float]],
                                           to current: [ReferenceBubbleID: [Float]]) -> Double {
        current.reduce(0) { maximum, pair in
            guard let before = previous[pair.key], before.count == pair.value.count else { return maximum }
            return max(maximum, Double(zip(before, pair.value).map { abs($0 - $1) }.max() ?? 0))
        }
    }

    private static func percentile(_ values: [Double], percentile: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[Int((Double(sorted.count - 1) * percentile).rounded(.up))]
    }
}
