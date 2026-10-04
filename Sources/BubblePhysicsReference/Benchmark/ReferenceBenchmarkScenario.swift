import Foundation

public enum ReferenceBroadPhaseSelection: String, Sendable, Equatable {
    case sweepAndPrune
    case aabbTree
}

public struct ReferenceBenchmarkScenario: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case twoBubbles
        case chain
        case fastSegment
        case rotatingSegment
        case triangle
        case giantBubble
        case mixedSizes(count: Int)
        case filled(count: Int)
    }

    public var kind: Kind
    public var seed: UInt64
    public var broadPhase: ReferenceBroadPhaseSelection

    public init(kind: Kind, seed: UInt64, broadPhase: ReferenceBroadPhaseSelection = .sweepAndPrune) {
        self.kind = kind
        self.seed = seed
        self.broadPhase = broadPhase
    }

    public static let twoBubbles = ReferenceBenchmarkScenario(kind: .twoBubbles, seed: 1)
    public static let chain = ReferenceBenchmarkScenario(kind: .chain, seed: 2)
    public static let fastSegment = ReferenceBenchmarkScenario(kind: .fastSegment, seed: 3)
    public static let rotatingSegment = ReferenceBenchmarkScenario(kind: .rotatingSegment, seed: 4)
    public static let triangle = ReferenceBenchmarkScenario(kind: .triangle, seed: 5)
    public static let giantBubble = ReferenceBenchmarkScenario(kind: .giantBubble, seed: 6)

    public static func mixedSizes(
        count: Int,
        seed: UInt64 = 0x2B_BA_11,
        broadPhase: ReferenceBroadPhaseSelection = .sweepAndPrune
    ) -> Self {
        .init(kind: .mixedSizes(count: count), seed: seed, broadPhase: broadPhase)
    }

    public static func filled(
        count: Int,
        seed: UInt64 = 0x2B_20_48,
        broadPhase: ReferenceBroadPhaseSelection = .sweepAndPrune
    ) -> Self {
        .init(kind: .filled(count: count), seed: seed, broadPhase: broadPhase)
    }

    public var name: String {
        switch kind {
        case .twoBubbles: return "two-bubbles"
        case .chain: return "chain"
        case .fastSegment: return "fast-segment"
        case .rotatingSegment: return "rotating-segment"
        case .triangle: return "triangle"
        case .giantBubble: return "giant-bubble"
        case let .mixedSizes(count): return "mixed-\(count)"
        case let .filled(count): return "filled-\(count)"
        }
    }

    public func makeWorld(configuration: ReferenceConfiguration = .default) throws -> ReferenceWorld {
        var world: ReferenceWorld
        switch broadPhase {
        case .sweepAndPrune:
            world = ReferenceWorld(configuration: configuration, broadPhase: SweepAndPruneBroadPhase())
        case .aabbTree:
            world = ReferenceWorld(configuration: configuration, broadPhase: AABBTreeBroadPhase())
        }

        switch kind {
        case .twoBubbles:
            world.addBubble(try bubble(id: 1, x: 170, y: 350, radius: 24, vx: 20))
            world.addBubble(try bubble(id: 2, x: 205, y: 350, radius: 24, vx: -20))
        case .chain:
            for index in 0..<8 {
                world.addBubble(try bubble(id: index + 1, x: 60 + Float(index) * 34, y: 350, radius: 20, vx: index == 0 ? 30 : 0))
            }
        case .fastSegment:
            world.addBubble(try bubble(id: 1, x: 187.5, y: 350, radius: 30))
            world.addSegment(.kinematicSegment(
                id: .init(rawValue: 1),
                previousA: .init(x: 40, y: 350), previousB: .init(x: 100, y: 350),
                currentA: .init(x: 240, y: 350), currentB: .init(x: 300, y: 350),
                collisionMode: .oneSided(allowedSide: 1)
            ))
        case .rotatingSegment:
            world.addBubble(try bubble(id: 1, x: 187.5, y: 390, radius: 25))
            world.addSegment(.kinematicSegment(
                id: .init(rawValue: 1),
                previousA: .init(x: 120, y: 350), previousB: .init(x: 255, y: 350),
                currentA: .init(x: 187.5, y: 282.5), currentB: .init(x: 187.5, y: 417.5),
                angularVelocity: .pi * 0.5,
                collisionMode: .oneSided(allowedSide: 1)
            ))
        case .triangle:
            world = ReferenceWorld(configuration: configuration, broadPhase: selectedBroadPhase())
            for index in 0..<24 {
                let column = index % 6
                let row = index / 6
                world.addBubble(try bubble(id: index + 1, x: 70 + Float(column) * 47, y: 250 + Float(row) * 48, radius: 26))
            }
            world.addSegment(.staticSegment(id: .init(rawValue: 1), a: .init(x: 120, y: 430), b: .init(x: 255, y: 430)))
            world.addSegment(.staticSegment(id: .init(rawValue: 2), a: .init(x: 255, y: 430), b: .init(x: 187.5, y: 300)))
            world.addSegment(.staticSegment(id: .init(rawValue: 3), a: .init(x: 187.5, y: 300), b: .init(x: 120, y: 430)))
        case .giantBubble:
            world.addBubble(try bubble(id: 1, x: 187.5, y: 350, radius: 500))
            addWalls(to: &world)
        case let .mixedSizes(count):
            addWalls(to: &world)
            var random = LCG(seed: seed)
            for index in 0..<max(0, count) {
                let radius = 4 + random.nextUnit() * 42
                let x = 12 + random.nextUnit() * 351
                let y = 12 + random.nextUnit() * 676
                world.addBubble(try bubble(id: index + 1, x: x, y: y, radius: radius))
            }
        case let .filled(count):
            addWalls(to: &world)
            let count = max(0, count)
            guard count > 0 else { return world }
            let aspect = Float(375.0 / 700.0)
            let columns = max(1, Int(ceil(sqrt(Float(count) * aspect))))
            let rows = max(1, Int(ceil(Float(count) / Float(columns))))
            let spacing = min(351 / Float(columns), 676 / Float(rows))
            let radius = spacing * 0.56
            for index in 0..<count {
                let column = index % columns
                let row = index / columns
                world.addBubble(try bubble(
                    id: index + 1,
                    x: 12 + (Float(column) + 0.5) * 351 / Float(columns),
                    y: 12 + (Float(row) + 0.5) * 676 / Float(rows),
                    radius: radius
                ))
            }
        }
        return world
    }

    private func selectedBroadPhase() -> any ReferenceBroadPhase {
        switch broadPhase {
        case .sweepAndPrune: return SweepAndPruneBroadPhase()
        case .aabbTree: return AABBTreeBroadPhase()
        }
    }

    private func bubble(id: Int, x: Float, y: Float, radius: Float, vx: Float = 0) throws -> ReferenceBubble {
        try ReferenceBubble(
            id: .init(rawValue: id), center: .init(x: x, y: y),
            velocity: .init(x: vx, y: 0), mass: max(1, radius * radius), targetRadius: radius
        )
    }

    private func addWalls(to world: inout ReferenceWorld) {
        world.addSegment(.staticSegment(id: .init(rawValue: 1), a: .init(x: 0, y: 0), b: .init(x: 0, y: 700), collisionMode: .oneSided(allowedSide: -1)))
        world.addSegment(.staticSegment(id: .init(rawValue: 2), a: .init(x: 375, y: 0), b: .init(x: 375, y: 700), collisionMode: .oneSided(allowedSide: 1)))
        world.addSegment(.staticSegment(id: .init(rawValue: 3), a: .init(x: 0, y: 0), b: .init(x: 375, y: 0), collisionMode: .oneSided(allowedSide: 1)))
        world.addSegment(.staticSegment(id: .init(rawValue: 4), a: .init(x: 0, y: 700), b: .init(x: 375, y: 700), collisionMode: .oneSided(allowedSide: -1)))
    }
}

private struct LCG {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 1 : seed }
    mutating func nextUnit() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(state >> 40) / Float(1 << 24)
    }
}
