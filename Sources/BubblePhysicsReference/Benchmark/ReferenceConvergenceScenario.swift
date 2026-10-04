public enum ReferenceConvergenceScene: String, Sendable, CaseIterable {
    case interactive24 = "interactive-24"
    case stress300 = "stress-300"
}

public struct ReferenceConvergenceScenario: Sendable, Equatable {
    public static let polygonOwnerID = 10_000

    public var scene: ReferenceConvergenceScene
    public var seed: UInt64
    public var newtonIterationLimit: Int
    public var broadPhase: ReferenceBroadPhaseSelection

    public init(
        scene: ReferenceConvergenceScene,
        seed: UInt64 = 0x2B_60_F5,
        newtonIterationLimit: Int,
        broadPhase: ReferenceBroadPhaseSelection = .sweepAndPrune
    ) {
        self.scene = scene
        self.seed = seed
        self.newtonIterationLimit = max(1, newtonIterationLimit)
        self.broadPhase = broadPhase
    }

    public func makeWorld() throws -> ReferenceWorld {
        var configuration = ReferenceConfiguration.default
        configuration.solverIterations = newtonIterationLimit
        var world = ReferenceWorld(configuration: configuration, broadPhase: selectedBroadPhase())
        addWalls(to: &world)
        try addBubbles(to: &world)
        addPolygon(to: &world, fromStep: 0, toStep: 0)
        return world
    }

    public func polygonCenter(atStep step: Int) -> ReferenceVector2 {
        let waypoints: [ReferenceVector2] = [
            .init(x: 187.5, y: 350),
            .init(x: 65, y: 105),
            .init(x: 310, y: 595),
            .init(x: 310, y: 105),
            .init(x: 65, y: 595),
        ]
        let stepsPerLeg = 40
        let nonnegativeStep = max(0, step)
        let leg = (nonnegativeStep / stepsPerLeg) % waypoints.count
        let next = (leg + 1) % waypoints.count
        let fraction = Float(nonnegativeStep % stepsPerLeg) / Float(stepsPerLeg)
        return waypoints[leg] + (waypoints[next] - waypoints[leg]) * fraction
    }

    public func updatePolygon(in world: inout ReferenceWorld, fromStep: Int, toStep: Int) {
        for segment in polygonSegments(fromStep: fromStep, toStep: toStep) {
            world.updateSegment(segment)
        }
    }

    private func selectedBroadPhase() -> any ReferenceBroadPhase {
        switch broadPhase {
        case .sweepAndPrune: SweepAndPruneBroadPhase()
        case .aabbTree: AABBTreeBroadPhase()
        }
    }

    private func addBubbles(to world: inout ReferenceWorld) throws {
        var random = ConvergenceLCG(seed: seed)
        let count = scene == .interactive24 ? 24 : 300
        let columns = scene == .interactive24 ? 5 : 15
        let rows = Int((Float(count) / Float(columns)).rounded(.up))
        let horizontalSpacing = 345 / Float(columns)
        let verticalSpacing = 670 / Float(rows)
        let baseRadius = min(horizontalSpacing, verticalSpacing) * (scene == .interactive24 ? 0.43 : 0.54)

        for index in 0..<count {
            let column = index % columns
            let row = index / columns
            let jitterX = (random.nextUnit() - 0.5) * horizontalSpacing * 0.12
            let jitterY = (random.nextUnit() - 0.5) * verticalSpacing * 0.12
            let radius = baseRadius * (0.78 + random.nextUnit() * 0.44)
            let center = ReferenceVector2(
                x: 15 + (Float(column) + 0.5) * horizontalSpacing + jitterX,
                y: 15 + (Float(row) + 0.5) * verticalSpacing + jitterY
            )
            world.addBubble(try ReferenceBubble(
                id: .init(rawValue: index + 1),
                center: center,
                mass: max(1, radius * radius * 0.02),
                targetRadius: radius
            ))
        }
    }

    private func addWalls(to world: inout ReferenceWorld) {
        world.addSegment(.staticSegment(id: .init(rawValue: 1), a: .init(x: 0, y: 0), b: .init(x: 0, y: 700), collisionMode: .oneSided(allowedSide: -1)))
        world.addSegment(.staticSegment(id: .init(rawValue: 2), a: .init(x: 375, y: 0), b: .init(x: 375, y: 700), collisionMode: .oneSided(allowedSide: 1)))
        world.addSegment(.staticSegment(id: .init(rawValue: 3), a: .init(x: 0, y: 0), b: .init(x: 375, y: 0), collisionMode: .oneSided(allowedSide: 1)))
        world.addSegment(.staticSegment(id: .init(rawValue: 4), a: .init(x: 0, y: 700), b: .init(x: 375, y: 700), collisionMode: .oneSided(allowedSide: -1)))
    }

    private func addPolygon(to world: inout ReferenceWorld, fromStep: Int, toStep: Int) {
        for segment in polygonSegments(fromStep: fromStep, toStep: toStep) {
            world.addSegment(segment)
        }
    }

    private func polygonSegments(fromStep: Int, toStep: Int) -> [ReferenceSegment] {
        let local = [
            ReferenceVector2(x: -46, y: 34),
            ReferenceVector2(x: 46, y: 34),
            ReferenceVector2(x: 0, y: -52),
        ]
        let previousCenter = polygonCenter(atStep: fromStep)
        let currentCenter = polygonCenter(atStep: toStep)
        return local.indices.map { index in
            let next = (index + 1) % local.count
            return .kinematicSegment(
                id: .init(rawValue: 5 + index),
                previousA: previousCenter + local[index],
                previousB: previousCenter + local[next],
                currentA: currentCenter + local[index],
                currentB: currentCenter + local[next],
                ownerID: Self.polygonOwnerID,
                collisionMode: .twoSided
            )
        }
    }
}

private struct ConvergenceLCG {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 1 : seed }

    mutating func nextUnit() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(state >> 40) / Float(1 << 24)
    }
}
