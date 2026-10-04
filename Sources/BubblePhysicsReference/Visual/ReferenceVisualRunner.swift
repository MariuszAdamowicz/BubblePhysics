public struct ReferenceVisualSnapshot: Sendable, Equatable {
    public var bubbles: [ReferenceBubble]
    public var contours: [ReferenceBubbleID: [ReferenceVector2]]
    public var triangleVertices: [ReferenceVector2]
    public var contacts: [ReferenceContact]
    public var lastReport: ReferenceWorldStepReport
    public var simulationTime: Double
    public var stepsExecuted: Int
    public var valuesByBubbleID: [ReferenceBubbleID: Int]
}

public struct ReferenceVisualRunner {
    public static let fixedTimeStep = 1.0 / 60.0
    public static let maximumCatchUpSteps = 3
    private var scene: ReferenceVisualScene
    private var lastPresentationTime: Double?
    private var accumulator = 0.0
    private var simulationTime = 0.0
    private var lastReport = ReferenceWorldStepReport.empty
    private var polygonCenter = ReferenceVisualSceneFactory.initialPolygonCenter
    private var requestedPolygonCenter = ReferenceVisualSceneFactory.initialPolygonCenter
    private var density: ReferenceVisualDensity

    public init(density: ReferenceVisualDensity = .six) throws {
        self.density = density
        scene = try ReferenceVisualSceneFactory.make(density: density)
    }
    public mutating func reset() { scene = try! ReferenceVisualSceneFactory.make(density: density); lastPresentationTime = nil; accumulator = 0; simulationTime = 0; polygonCenter = ReferenceVisualSceneFactory.initialPolygonCenter; requestedPolygonCenter = polygonCenter; lastReport = .empty }
    public mutating func setDensity(_ density: ReferenceVisualDensity) {
        self.density = density
        reset()
    }
    public mutating func movePolygon(to point: ReferenceVector2) { requestedPolygonCenter = .init(x: min(330, max(45, point.x)), y: min(650, max(50, point.y))) }

    public mutating func advance(to presentationTime: Double) -> ReferenceVisualSnapshot {
        guard presentationTime.isFinite else { return snapshot(stepsExecuted: 0) }
        guard let previous = lastPresentationTime else { lastPresentationTime = presentationTime; return snapshot(stepsExecuted: 0) }
        accumulator += min(max(0, presentationTime - previous), Self.fixedTimeStep * Double(Self.maximumCatchUpSteps)); lastPresentationTime = presentationTime
        var steps = 0
        while accumulator + 1e-12 >= Self.fixedTimeStep && steps < Self.maximumCatchUpSteps { stepOnce(); accumulator -= Self.fixedTimeStep; steps += 1 }
        return snapshot(stepsExecuted: steps)
    }

    private mutating func stepOnce() {
        let previous = ReferenceVisualSceneFactory.polygonVertices(localVertices: scene.polygonLocalVertices, center: polygonCenter)
        let delta = requestedPolygonCenter - polygonCenter
        let boundedDelta: ReferenceVector2 = delta.length > 18 ? delta * (Float(18) / delta.length) : delta
        polygonCenter = polygonCenter + boundedDelta
        let current = ReferenceVisualSceneFactory.polygonVertices(localVertices: scene.polygonLocalVertices, center: polygonCenter)
        for index in current.indices {
            scene.world.updateSegment(.kinematicSegment(id: scene.polygonSegmentIDs[index], previousA: previous[index], previousB: previous[(index + 1) % 3], currentA: current[index], currentB: current[(index + 1) % 3], timeStep: Float(Self.fixedTimeStep), ownerID: scene.polygonOwnerID, collisionMode: .twoSided))
        }
        lastReport = scene.world.step(); simulationTime += Self.fixedTimeStep
    }

    private func snapshot(stepsExecuted: Int) -> ReferenceVisualSnapshot {
        let contours = Dictionary(uniqueKeysWithValues: scene.world.bubbles.map { ($0.id, scene.world.contour(for: $0.id)) })
        let vertices = scene.polygonSegmentIDs.compactMap { id in scene.world.segments.first { $0.id == id }?.currentA }
        return .init(bubbles: scene.world.bubbles, contours: contours, triangleVertices: vertices, contacts: scene.world.contacts.contacts, lastReport: lastReport, simulationTime: simulationTime, stepsExecuted: stepsExecuted, valuesByBubbleID: scene.valuesByBubbleID)
    }
}

extension ReferenceWorldStepReport {
    static let empty = ReferenceWorldStepReport(solver: .init(iterations: 0, maximumPenetration: 0, converged: true, didReachIterationLimit: false, positionCorrectionCount: 0, deformationCount: 0), candidatePairCount: 0, generatedContactCount: 0, persistentContactCount: 0, toiTestCount: 0, sideCorrectionCount: 0, ccdBudgetExhaustionCount: 0, predictionMilliseconds: 0, broadPhaseMilliseconds: 0, contactMilliseconds: 0, solverMilliseconds: 0, totalMilliseconds: 0, hasNonFiniteState: false)
}
