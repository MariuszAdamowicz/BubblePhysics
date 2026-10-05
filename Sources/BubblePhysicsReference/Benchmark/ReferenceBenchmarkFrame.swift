public struct ReferencePreparedBubble: Sendable, Equatable {
    public var id: ReferenceBubbleID
    public var center: ReferenceVector2
    public var rotation: Float
    public var contour: [ReferenceVector2]

    public init(id: ReferenceBubbleID, center: ReferenceVector2, rotation: Float, contour: [ReferenceVector2]) {
        self.id = id
        self.center = center
        self.rotation = rotation
        self.contour = contour
    }
}

public struct ReferenceBenchmarkFrameResult: Sendable, Equatable {
    public var worldReport: ReferenceWorldStepReport
    public var simulationMilliseconds: Double
    public var contourMilliseconds: Double
    public var renderPreparationMilliseconds: Double
    public var fullFrameMilliseconds: Double
    public var contourPointCount: Int
    public var preparedBubbles: [ReferencePreparedBubble]
    public var backend: ReferenceSimulationBackend = .cpu
    public var fallbackReason: String? = nil

    public init(worldReport: ReferenceWorldStepReport, simulationMilliseconds: Double,
                contourMilliseconds: Double, renderPreparationMilliseconds: Double,
                fullFrameMilliseconds: Double, contourPointCount: Int,
                preparedBubbles: [ReferencePreparedBubble], backend: ReferenceSimulationBackend = .cpu,
                fallbackReason: String? = nil) {
        self.worldReport = worldReport
        self.simulationMilliseconds = simulationMilliseconds
        self.contourMilliseconds = contourMilliseconds
        self.renderPreparationMilliseconds = renderPreparationMilliseconds
        self.fullFrameMilliseconds = fullFrameMilliseconds
        self.contourPointCount = contourPointCount
        self.preparedBubbles = preparedBubbles
        self.backend = backend
        self.fallbackReason = fallbackReason
    }
}

public enum ReferenceBenchmarkFrame {
    public static func run(
        world: inout ReferenceWorld,
        scenario: ReferenceConvergenceScenario,
        step: Int
    ) -> ReferenceBenchmarkFrameResult {
        let clock = ContinuousClock()
        let fullStart = clock.now
        scenario.updatePolygon(in: &world, fromStep: step, toStep: step + 1)

        let simulationStart = clock.now
        let worldReport = world.step()
        let simulationEnd = clock.now

        let contourStart = clock.now
        let geometry = world.bubbles.map { bubble in
            (bubble, world.contour(for: bubble.id))
        }
        let contourEnd = clock.now

        let preparationStart = clock.now
        let prepared = geometry.map { bubble, contour in
            ReferencePreparedBubble(
                id: bubble.id,
                center: bubble.center,
                rotation: bubble.rotation,
                contour: contour
            )
        }
        let preparationEnd = clock.now

        return .init(
            worldReport: worldReport,
            simulationMilliseconds: milliseconds(simulationStart.duration(to: simulationEnd)),
            contourMilliseconds: milliseconds(contourStart.duration(to: contourEnd)),
            renderPreparationMilliseconds: milliseconds(preparationStart.duration(to: preparationEnd)),
            fullFrameMilliseconds: milliseconds(fullStart.duration(to: preparationEnd)),
            contourPointCount: prepared.reduce(0) { $0 + $1.contour.count },
            preparedBubbles: prepared
        )
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
