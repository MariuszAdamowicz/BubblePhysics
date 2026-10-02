public struct ReferenceVisualSnapshot: Sendable, Equatable {
    public var bubbles: [ReferenceBubble]
    public var contours: [ReferenceBubbleID: [ReferenceVector2]]
    public var triangleVertices: [ReferenceVector2]
    public var lastReport: ReferenceWorldStepReport
    public var simulationTime: Double
    public var stepsExecuted: Int
}

public struct ReferenceVisualRunner {
    public static let fixedTimeStep = 1.0 / 60.0
    public static let maximumCatchUpSteps = 3

    private var scene: ReferenceVisualScene
    private var lastPresentationTime: Double?
    private var accumulator: Double = 0
    private var simulationTime: Double = 0
    private var lastReport = ReferenceWorldStepReport.empty

    public init() throws {
        scene = try ReferenceVisualSceneFactory.make()
    }

    public mutating func reset() {
        scene = try! ReferenceVisualSceneFactory.make()
        lastPresentationTime = nil
        accumulator = 0
        simulationTime = 0
        lastReport = .empty
    }

    public mutating func advance(to presentationTime: Double) -> ReferenceVisualSnapshot {
        guard presentationTime.isFinite else { return snapshot(stepsExecuted: 0) }
        guard let previousPresentationTime = lastPresentationTime else {
            lastPresentationTime = presentationTime
            return snapshot(stepsExecuted: 0)
        }

        let elapsed = max(0, presentationTime - previousPresentationTime)
        lastPresentationTime = presentationTime
        accumulator += min(elapsed, Self.fixedTimeStep * Double(Self.maximumCatchUpSteps))

        var steps = 0
        while accumulator + 1e-12 >= Self.fixedTimeStep && steps < Self.maximumCatchUpSteps {
            stepOnce()
            accumulator -= Self.fixedTimeStep
            steps += 1
        }
        return snapshot(stepsExecuted: steps)
    }

    private mutating func stepOnce() {
        let nextTime = simulationTime + Self.fixedTimeStep
        let nextVertices = ReferenceVisualSceneFactory.triangleVertices(
            localVertices: scene.triangleLocalVertices,
            at: nextTime
        )
        for edgeIndex in 0..<3 {
            let id = scene.triangleSegmentIDs[edgeIndex]
            guard let previous = scene.world.segments.first(where: { $0.id == id }) else { continue }
            scene.world.updateSegment(.kinematicSegment(
                id: id,
                previousA: previous.currentA,
                previousB: previous.currentB,
                currentA: nextVertices[edgeIndex],
                currentB: nextVertices[(edgeIndex + 1) % 3],
                timeStep: Float(Self.fixedTimeStep),
                angularVelocity: 0.82,
                ownerID: scene.triangleOwnerID,
                collisionMode: .twoSided
            ))
        }
        lastReport = scene.world.step()
        simulationTime = nextTime
    }

    private func snapshot(stepsExecuted: Int) -> ReferenceVisualSnapshot {
        let contours = Dictionary(uniqueKeysWithValues: scene.world.bubbles.map { bubble in
            (bubble.id, scene.world.contour(for: bubble.id))
        })
        let triangleSegments = scene.triangleSegmentIDs.compactMap { id in
            scene.world.segments.first(where: { $0.id == id })
        }
        let vertices = triangleSegments.map(\.currentA)
        return ReferenceVisualSnapshot(
            bubbles: scene.world.bubbles,
            contours: contours,
            triangleVertices: vertices,
            lastReport: lastReport,
            simulationTime: simulationTime,
            stepsExecuted: stepsExecuted
        )
    }
}

private extension ReferenceWorldStepReport {
    static let empty = ReferenceWorldStepReport(
        solver: .init(
            iterations: 0,
            maximumPenetration: 0,
            converged: true,
            didReachIterationLimit: false,
            positionCorrectionCount: 0,
            deformationCount: 0
        ),
        candidatePairCount: 0,
        generatedContactCount: 0,
        persistentContactCount: 0,
        toiTestCount: 0,
        sideCorrectionCount: 0,
        ccdBudgetExhaustionCount: 0,
        predictionMilliseconds: 0,
        broadPhaseMilliseconds: 0,
        contactMilliseconds: 0,
        solverMilliseconds: 0,
        totalMilliseconds: 0,
        hasNonFiniteState: false
    )
}
