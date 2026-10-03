import XCTest
@testable import BubblePhysicsReference

final class ReferenceDynamicAcceptanceTests: XCTestCase {
    func testSingleAndOpposingContactsRemainFiniteAndDeterministic() throws {
        let first = try runChain(count: 2, velocity: 90, steps: 20)
        let second = try runChain(count: 2, velocity: 90, steps: 20)
        XCTAssertEqual(first.bubbles, second.bubbles)
        XCTAssertFalse(first.report.hasNonFiniteState)
        XCTAssertGreaterThan(first.bubbles[1].velocity.x, 0)

        let opposed = try runOpposed()
        XCTAssertFalse(opposed.report.hasNonFiniteState)
        XCTAssertLessThan(abs(opposed.bubble.velocity.x), 25)
    }

    func testThreeBubbleChainTransfersMotionWithoutCenterOverlap() throws {
        let result = try runChain(count: 3, velocity: 120, steps: 30)
        XCTAssertGreaterThan(result.bubbles[2].velocity.x, 0)
        for pair in zip(result.bubbles, result.bubbles.dropFirst()) {
            XCTAssertGreaterThan((pair.1.center - pair.0.center).length, 0.01)
        }
    }

    func testCornerWallAndFastPolygonDoNotSwallowCenters() throws {
        var world = makeWorld()
        world.addBubble(try bubble(1, x: 26, y: 26, vx: -80, vy: -70))
        addBox(to: &world)
        for _ in 0..<40 { _ = world.step() }
        let corner = try XCTUnwrap(world.bubbles.first)
        XCTAssertGreaterThanOrEqual(corner.center.x, -0.001)
        XCTAssertGreaterThanOrEqual(corner.center.y, -0.001)

        var runner = try ReferenceVisualRunner()
        _ = runner.advance(to: 0)
        runner.movePolygon(to: .init(x: 65, y: 350))
        var snapshot = runner.advance(to: 1.0 / 60.0)
        for frame in 2...45 { snapshot = runner.advance(to: Double(frame) / 60.0) }
        XCTAssertFalse(snapshot.lastReport.hasNonFiniteState)
        for bubble in snapshot.bubbles {
            XCTAssertFalse(pointInTriangle(bubble.center, snapshot.triangleVertices))
        }
    }

    func testTimeSubdivisionConverges() throws {
        let coarse = try integratedPosition(dt: 1 / 30)
        let medium = try integratedPosition(dt: 1 / 60)
        let fine = try integratedPosition(dt: 1 / 120)
        XCTAssertGreaterThan(abs(coarse - medium), abs(medium - fine) * 0.8)
    }

    private func runChain(count: Int, velocity: Float, steps: Int) throws -> (bubbles: [ReferenceBubble], report: ReferenceWorldStepReport) {
        var world = makeWorld()
        for index in 0..<count { world.addBubble(try bubble(index + 1, x: 70 + Float(index) * 42, y: 100, vx: index == 0 ? velocity : 0)) }
        var report = ReferenceWorldStepReport.empty
        for _ in 0..<steps { report = world.step() }
        return (world.bubbles, report)
    }

    private func runOpposed() throws -> (bubble: ReferenceBubble, report: ReferenceWorldStepReport) {
        var world = makeWorld()
        world.addBubble(try bubble(1, x: 100, y: 100))
        world.addBubble(try bubble(2, x: 61, y: 100, vx: 35))
        world.addBubble(try bubble(3, x: 139, y: 100, vx: -35))
        var report = ReferenceWorldStepReport.empty
        for _ in 0..<20 { report = world.step() }
        return (world.bubbles.first!, report)
    }

    private func integratedPosition(dt: Float) throws -> Float {
        var position: Float = 0
        var velocity: Float = 80
        let drag: Float = ReferenceConfiguration.default.linearDamping
        let count = Int(round(0.5 / dt))
        for _ in 0..<count {
            let nextVelocity = velocity * (2 - drag * dt) / (2 + drag * dt)
            position += dt * (velocity + nextVelocity) * 0.5
            velocity = nextVelocity
        }
        return position
    }

    private func makeWorld() -> ReferenceWorld { ReferenceWorld(configuration: .default, broadPhase: SweepAndPruneBroadPhase()) }
    private func bubble(_ id: Int, x: Float, y: Float, vx: Float = 0, vy: Float = 0) throws -> ReferenceBubble { try .init(id: .init(rawValue: id), center: .init(x: x, y: y), velocity: .init(x: vx, y: vy), mass: 1, targetRadius: 20) }
    private func addBox(to world: inout ReferenceWorld) {
        world.addSegment(.staticSegment(id: .init(rawValue: 1), a: .init(x: 0, y: 0), b: .init(x: 0, y: 200), collisionMode: .oneSided(allowedSide: -1)))
        world.addSegment(.staticSegment(id: .init(rawValue: 2), a: .init(x: 0, y: 0), b: .init(x: 200, y: 0), collisionMode: .oneSided(allowedSide: 1)))
    }
    private func pointInTriangle(_ p: ReferenceVector2, _ v: [ReferenceVector2]) -> Bool {
        guard v.count == 3 else { return false }
        let signs = v.indices.map { (v[($0 + 1) % 3] - v[$0]).cross(p - v[$0]) }
        return signs.allSatisfy { $0 >= 0 } || signs.allSatisfy { $0 <= 0 }
    }
}
