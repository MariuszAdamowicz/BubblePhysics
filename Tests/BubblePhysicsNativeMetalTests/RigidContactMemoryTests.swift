import BubblePhysicsModel
import Metal
@testable import BubblePhysicsNativeMetal
import XCTest

/// P-B-20: kontakty brył idą po liście kandydatów z kluczem pary (O(P·k)), nie po slotach P·n + P².
@MainActor
final class RigidContactMemoryTests: XCTestCase {
    private let bubbleMaterial = PhysicsMaterialID(rawValue: 1)
    private let polygonMaterial = PhysicsMaterialID(rawValue: 2)
    private let style = RenderStyleID(rawValue: 1)
    private var limit: Int { NativeMetalSolver.candidateLimitPerObject }

    /// 300 baniek na siatce co 30 i P dynamicznych brył w środkach komórek (bez kontaktów).
    private func scene(bodies: Int) throws -> [NativePublicObject] {
        var objects: [NativePublicObject] = []
        for index in 0..<300 {
            objects.append(NativePublicObject(descriptor: .bubble(try BubbleDescriptor(id: ObjectID(rawValue: UInt64(index + 1)),
                position: [Float(index % 20) * 30 + 15, Float(index / 20) * 30 + 15], targetRadius: 5,
                physicsMaterialID: bubbleMaterial, renderStyleID: style))))
        }
        for index in 0..<bodies {
            objects.append(NativePublicObject(descriptor: .rigidBody(try RigidBodyDescriptor(id: ObjectID(rawValue: UInt64(10_000 + index)),
                vertices: [[-2, -2], [2, -2], [2, 2], [-2, 2]],
                position: [Float(index % 20) * 30 + 30, Float(index / 20) * 30 + 30], motionRole: .dynamic,
                physicsMaterialID: polygonMaterial, renderStyleID: style))))
        }
        return objects
    }

    private func measure(bodies: Int) async throws -> (rigid: Int, total: Int) {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        _ = try await world.step(objects: scene(bodies: bodies),
            materials: [bubbleMaterial: try PhysicsMaterial(kind: .bubble), polygonMaterial: try PhysicsMaterial(kind: .rigid)],
            styles: [style: try RenderStyle()], region: WorldRectangle(min: [0, 0], max: [700, 700]), duration: 1.0 / 60)
        return (world.rigidContactMemoryBytes, world.rigidContactMemoryBytes + world.contactMemoryBytes)
    }

    // 30 i 120 brył przy 300 bańkach: P·n + P² daje 9 900 i 50 400 slotów po 64 B, a O(P·k) najwyżej 128 B na (bryła, slot).
    func testRigidContactMemoryIsBoundedByBodiesTimesCandidateLimit() async throws {
        for bodies in [30, 120] {
            let bytes = try await measure(bodies: bodies).rigid
            XCTAssertLessThanOrEqual(bytes, bodies * limit * 128,
                "\(bodies) brył: \(bytes) B pamięci kontaktów brył przekracza budżet O(P·k)")
        }
    }

    func testRigidContactMemoryGrowsLinearlyWithBodyCount() async throws {
        let few = try await measure(bodies: 30).rigid
        let many = try await measure(bodies: 120).rigid
        XCTAssertLessThanOrEqual(Double(many), 4.5 * Double(max(few, 1)), "30 brył: \(few) B, 120 brył: \(many) B")
    }

    func testTotalContactMemoryWithBodiesStaysWithinBudget() async throws {
        let total = try await measure(bodies: 120).total
        XCTAssertLessThanOrEqual(total, (300 + 120) * limit * 2048)
    }

    // Wiersz bryły ma stałe k: bryła pod ponad k bańkami zwiększa licznik, a klatka jest opublikowana i skończona.
    func testRigidRowOverflowRaisesCounterAndKeepsFrameFinite() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var objects: [NativePublicObject] = []
        // Bańki tuż poza bryłą (pierścień w odległości 23 od środka), ale w jej zasięgu sprawdzanym przez kandydatów.
        let count = limit + 12, perSide = count / 4
        for index in 0..<count {
            let side = index / perSide, u = Float(index % perSide) / Float(perSide) * 46 - 23
            let offsets: [WorldPoint] = [[u, -23], [23, u], [-u, 23], [-23, -u]]
            objects.append(NativePublicObject(descriptor: .bubble(try BubbleDescriptor(id: ObjectID(rawValue: UInt64(index + 1)),
                position: [100 + offsets[min(side, 3)].x, 100 + offsets[min(side, 3)].y], targetRadius: 1,
                physicsMaterialID: bubbleMaterial, renderStyleID: style))))
        }
        objects.append(NativePublicObject(descriptor: .rigidBody(try RigidBodyDescriptor(id: ObjectID(rawValue: 10_000),
            vertices: [[-20, -20], [20, -20], [20, 20], [-20, 20]], position: [100, 100], motionRole: .dynamic,
            physicsMaterialID: polygonMaterial, renderStyleID: style))))
        var frame = try await world.step(objects: objects,
            materials: [bubbleMaterial: try PhysicsMaterial(kind: .bubble), polygonMaterial: try PhysicsMaterial(kind: .rigid)],
            styles: [style: try RenderStyle()], region: WorldRectangle(min: [-200, -200], max: [400, 400]), duration: 1.0 / 60)
        XCTAssertGreaterThan(frame.contactCandidateOverflowCount, 0)
        XCTAssertGreaterThanOrEqual(frame.maximumContactCandidatesPerObject, limit)
        frame = try await world.step(objects: Array(frame.objects.values),
            materials: [bubbleMaterial: try PhysicsMaterial(kind: .bubble), polygonMaterial: try PhysicsMaterial(kind: .rigid)],
            styles: [style: try RenderStyle()], region: WorldRectangle(min: [-200, -200], max: [400, 400]), duration: 1.0 / 60)
        XCTAssertEqual(frame.objects.count, limit + 13)
        for object in frame.objects.values {
            XCTAssertTrue(object.position.x.isFinite && object.position.y.isFinite)
        }
    }
}
