import BubblePhysics
import BubblePhysicsMetalRender
import Metal
import XCTest
import simd

/// P-B-28 (G11-AC5): limity prędkości liniowej i kątowej z materiału; żaden obiekt nie przekracza ich pod silną siłą globalną.
@MainActor
final class VelocityLimitTests: XCTestCase {
    private typealias B = SceneBuilders
    private let linearLimit: Float = 50
    private let angularLimit: Float = 3
    private let limitedBubbleMaterial = PhysicsMaterialID(rawValue: 11)
    private let limitedRigidMaterial = PhysicsMaterialID(rawValue: 12)

    private func transaction() throws -> WorldTransaction {
        try B.baseTransaction()
            .updatePhysicsMaterial(limitedBubbleMaterial, material: PhysicsMaterial(kind: .bubble,
                maximumLinearSpeed: linearLimit, maximumAngularSpeed: angularLimit))
            .updatePhysicsMaterial(limitedRigidMaterial, material: PhysicsMaterial(kind: .rigid,
                maximumLinearSpeed: linearLimit, maximumAngularSpeed: angularLimit))
    }

    private func bubble(_ id: UInt64, at position: WorldPoint) throws -> WorldObject {
        .bubble(try BubbleDescriptor(id: ObjectID(rawValue: id), position: position, targetRadius: 8,
            physicsMaterialID: limitedBubbleMaterial, renderStyleID: B.style))
    }

    // Silna siła globalna (1e5) rozpędziłaby każde ciało do ponad 1600 jednostek na sekundę już w pierwszym kroku.
    func testNoObjectExceedsMaterialSpeedLimitsUnderStrongGlobalForce() async throws {
        let world = try B.makeWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()),
                                    region: WorldRectangle(min: [-5000, -5000], max: [5000, 5000]), gravity: [0, -100_000])
        world.submit(try transaction()
            .add(bubble(1, at: [100, 100]))
            .add(B.box(2, at: [200, 100], half: [10, 7], role: .dynamic, materialID: limitedRigidMaterial))
            .add(B.circle(3, at: [300, 100], radius: 9, angularVelocity: 100, materialID: limitedRigidMaterial))
            .add(B.capsule(4, at: [400, 100], halfLength: 8, radius: 5, angularVelocity: -100, materialID: limitedRigidMaterial)))
        var worstLinear: [UInt64: Float] = [:], worstAngular: [UInt64: Float] = [:]
        _ = await B.advance(world, steps: 30) { _, frame in
            for (id, object) in frame.objects {
                worstLinear[id.rawValue] = max(worstLinear[id.rawValue] ?? 0, simd_length(object.velocity))
                worstAngular[id.rawValue] = max(worstAngular[id.rawValue] ?? 0, abs(object.angularVelocity))
            }
        }
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
        XCTAssertEqual(worstLinear.count, 4)
        for (id, speed) in worstLinear { XCTAssertLessThanOrEqual(speed, linearLimit * 1.001, "obiekt \(id): prędkość liniowa") }
        for (id, speed) in worstAngular { XCTAssertLessThanOrEqual(speed, angularLimit * 1.001, "obiekt \(id): prędkość kątowa") }
        // Limit działa, a nie zeruje ruchu: ciała spadają z prędkością bliską limitu.
        XCTAssertGreaterThan(try XCTUnwrap(worstLinear[2]), linearLimit * 0.9)
        XCTAssertGreaterThan(try XCTUnwrap(worstLinear[1]), linearLimit * 0.9)
        XCTAssertGreaterThan(try XCTUnwrap(worstAngular[3]), angularLimit * 0.9, "koło zachowuje obrót do limitu")
    }

    // G11-AC5: limit dotyczy też bryły kinematycznej; napęd szybszy niż limit materiału jest przycinany do limitu.
    func testKinematicBodyDrivenAboveMaterialLimitMovesAtTheLimit() async throws {
        let world = try B.makeWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()),
                                    region: WorldRectangle(min: [-5000, -5000], max: [5000, 5000]))
        world.submit(try transaction()
            .add(B.box(1, at: [0, 100], half: [10, 7], role: .kinematic, materialID: limitedRigidMaterial))
            .setKinematicDrive(ObjectID(rawValue: 1), drive: .velocity(linear: [linearLimit * 2.4, 0], angular: 0)))
        var worst: Float = 0
        let result = await B.advance(world, steps: 60) { _, frame in
            if let box = frame.objects[ObjectID(rawValue: 1)] { worst = max(worst, simd_length(box.velocity)) }
        }
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
        XCTAssertLessThanOrEqual(worst, linearLimit * 1.001, "prędkość kinematycznej bryły")
        let box = try XCTUnwrap(result.frame.objects[ObjectID(rawValue: 1)])
        let expected = linearLimit * Float(result.frame.simulationTime)
        XCTAssertEqual(box.position.x, expected, accuracy: expected * 0.02, "bryła jedzie z prędkością limitu, a nie stoi")
    }

    // Materiał bez limitu nie zmienia zachowania: ten sam scenariusz osiąga dużo większą prędkość.
    func testMaterialWithoutLimitsIsNotClamped() async throws {
        let world = try B.makeWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()),
                                    region: WorldRectangle(min: [-5000, -5000], max: [5000, 5000]), gravity: [0, -100_000])
        world.submit(try B.baseTransaction()
            .add(B.box(1, at: [200, 100], half: [10, 7], role: .dynamic)))
        let result = await B.advance(world, steps: 5)
        XCTAssertGreaterThan(simd_length(try XCTUnwrap(result.frame.objects[ObjectID(rawValue: 1)]).velocity), 1000)
    }
}
