import Foundation

public struct BenchmarkBubbleSeed: Equatable, Sendable {
    public let id: BubbleID
    public let value: Int
    public let center: Vector2
    public let restArea: Float

    public init(id: BubbleID, value: Int, center: Vector2, restArea: Float) {
        self.id = id
        self.value = value
        self.center = center
        self.restArea = restArea
    }
}

public struct BenchmarkScenario: Sendable {
    public let configuration: WorldConfiguration
    public let bounds: AABB
    public let seeds: [BenchmarkBubbleSeed]

    public static let iPhoneX: BenchmarkScenario = {
        let configuration = WorldConfiguration.default
        let bounds = AABB(minimum: .zero, maximum: Vector2(x: 375, y: 812))
        let values = Self.expandedValues([2: 163, 4: 64, 8: 32, 16: 16, 32: 8, 64: 6, 128: 4, 256: 3, 512: 2, 1024: 1, 2048: 1])
        let seeds = values.enumerated().map { index, value in
            let column = index % 15
            let row = index / 15
            let center = Vector2(x: 12.5 + Float(column) * 25, y: 20 + Float(row) * 40)
            return BenchmarkBubbleSeed(id: BubbleID(rawValue: index + 1), value: value, center: center, restArea: Self.restArea(for: value))
        }
        return BenchmarkScenario(configuration: configuration, bounds: bounds, seeds: seeds)
    }()

    public static func restArea(for value: Int) -> Float {
        precondition(value >= 2)
        let baseArea = Float.pi * 14 * 14
        return baseArea * Float(value) / 2
    }

    public static func expandedValues(_ counts: [Int: Int]) -> [Int] {
        counts.keys.sorted().flatMap { value in Array(repeating: value, count: counts[value] ?? 0) }
    }

    public func makeWorld() -> BubbleWorld {
        var world = BubbleWorld(configuration: configuration, bounds: bounds)
        for seed in seeds {
            let allocated = world.addBubble(center: seed.center, restArea: seed.restArea)
            precondition(allocated == seed.id)
        }
        return world
    }
}

public struct BenchmarkReport: Equatable, Sendable {
    public let stepCount: Int
    public let p50Milliseconds: Double
    public let p95Milliseconds: Double
    public let finalDiagnostics: WorldDiagnostics
    public let finalStepTimings: WorldStepTimings

    public static func measure(
        scenario: BenchmarkScenario = .iPhoneX,
        steps: Int,
        onProgress: ((BenchmarkProgress) -> Void)? = nil
    ) -> BenchmarkReport {
        precondition(steps > 0)
        var world = scenario.makeWorld()
        var samples: [Double] = []
        samples.reserveCapacity(steps)
        var lastStepReport: WorldStepReport?
        for index in 0..<steps {
            let start = Date()
            lastStepReport = world.step()
            samples.append(Date().timeIntervalSince(start) * 1_000)
            onProgress?(BenchmarkProgress(completedSteps: index + 1, totalSteps: steps))
        }
        let sorted = samples.sorted()
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
        let finalStepReport = lastStepReport!
        return BenchmarkReport(
            stepCount: steps,
            p50Milliseconds: p50,
            p95Milliseconds: p95,
            finalDiagnostics: finalStepReport.diagnostics,
            finalStepTimings: finalStepReport.timings
        )
    }
}

public struct BenchmarkProgress: Equatable, Sendable {
    public let completedSteps: Int
    public let totalSteps: Int

    public init(completedSteps: Int, totalSteps: Int) {
        self.completedSteps = completedSteps
        self.totalSteps = totalSteps
    }
}
