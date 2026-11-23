@testable import BubblePhysics
@testable import BubblePhysicsRuntime
import XCTest

/// Walidacja rozmieszczenia po stronie bryły (P-B-35, G7-AC1) i stała tolerancja wspólnego środka (P-B-36, G7-AC2): transakcja,
/// po której środek bańki leżałby w bryle kolidującej z nią według filtrów, jest odrzucana także wtedy, gdy to bryła, a nie
/// bańka, wchodzi do świata. Odrzucona transakcja zostawia stan bez zmian. Sam stager, bez GPU.
final class RigidPlacementTests: XCTestCase {
    private let bubbleMaterial = PhysicsMaterialID(rawValue: 1)
    private let rigidMaterial = PhysicsMaterialID(rawValue: 2)
    private let style = RenderMaterialID(rawValue: 1)
    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }

    private func resources() throws -> WorldTransaction {
        WorldTransaction()
            .updatePhysicsMaterial(bubbleMaterial, material: try PhysicsMaterial(kind: .bubble, contactStiffness: 1e9))
            .updatePhysicsMaterial(rigidMaterial, material: try PhysicsMaterial(kind: .rigid))
            .updateRenderMaterial(style, material: try RenderMaterial())
    }
    private func bubble(_ value: UInt64, at position: WorldPoint, radius: Float = 2,
                        filter: CollisionFilter = .default) throws -> WorldObject {
        .bubble(try BubbleDescriptor(id: id(value), position: position, targetRadius: radius, mass: 2,
                                     physicsMaterialID: bubbleMaterial, renderMaterialID: style, filter: filter))
    }
    private func bodyDescriptor(_ value: UInt64, _ shape: RigidShape, at position: WorldPoint = .zero,
                                role: MotionRole = .static, filter: CollisionFilter = .default) throws -> RigidBodyDescriptor {
        try RigidBodyDescriptor(id: id(value), shape: shape, position: position, motionRole: role,
                                physicsMaterialID: rigidMaterial, renderMaterialID: style, filter: filter)
    }
    private func body(_ value: UInt64, _ shape: RigidShape, at position: WorldPoint = .zero,
                      role: MotionRole = .static, filter: CollisionFilter = .default) throws -> WorldObject {
        .rigidBody(try bodyDescriptor(value, shape, at: position, role: role, filter: filter))
    }
    private func rectangle(_ low: WorldPoint, _ high: WorldPoint) throws -> RigidShape {
        .polygon(try PolygonGeometry(vertices: [low, [high.x, low.y], high, [low.x, high.y]]))
    }
    private func state(_ transactions: [WorldTransaction]) throws -> RuntimeState {
        var state = RuntimeState(configuration: try WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-100, -100], max: [100, 100])))
        for transaction in transactions { state = try TransactionStager.stage(transaction, against: state).state }
        return state
    }
    /// Transakcja odrzucona na operacji `index` z `invalidPlacement(bubble, issue)`; wsad zostawia świat bez zmian.
    private func assertRejected(_ transaction: WorldTransaction, against initial: RuntimeState, index: Int, bubble: UInt64,
                                _ issue: PlacementIssue, _ name: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try TransactionStager.stage(transaction, against: initial), name, file: file, line: line) {
            XCTAssertEqual($0 as? TransactionRejection,
                           TransactionRejection(operationIndex: index, reason: .invalidPlacement(self.id(bubble), issue)),
                           name, file: file, line: line)
        }
        let boundary = TransactionStager.stageBatch(
            [PendingTransaction(token: TransactionToken(rawValue: 1), transaction: transaction)], against: initial)
        XCTAssertEqual(boundary.state, initial, "\(name): świat bez zmian", file: file, line: line)
        XCTAssertTrue(boundary.frame.transactionReceipts.isEmpty, name, file: file, line: line)
    }

    // MARK: wstawienie bryły nad bańką (P-B-35)

    func testAddedBodyCoveringABubbleCenterIsRejectedForEveryShape() throws {
        let initial = try state([resources().add(bubble(1, at: [10, 10]))])
        let shapes: [(String, RigidShape, WorldPoint)] = [
            ("wielokąt", try rectangle([-5, -5], [5, 5]), [10, 10]),
            ("koło", .circle(radius: 5), [12, 10]),
            ("kapsuła", .capsule(halfLength: 8, radius: 1), [10, 10.5]),
        ]
        for (name, shape, position) in shapes {
            assertRejected(WorldTransaction().add(try body(100, shape, at: position)), against: initial, index: 0, bubble: 1,
                           .insideRigidBody, name)
        }
        // Bryła dynamiczna i kinematyczna też: reguła nie zależy od roli.
        assertRejected(WorldTransaction().add(try body(100, .circle(radius: 5), at: [10, 10], role: .kinematic)),
                       against: initial, index: 0, bubble: 1, .insideRigidBody)
    }

    func testBodyPlacedAwayFromBubbleCentersIsAccepted() throws {
        let initial = try state([resources().add(bubble(1, at: [10, 10]))])
        // Środek bańki jest poza kołem, choć sama bańka (r = 2) nachodzi na bryłę: liczy się tylko środek.
        XCTAssertNoThrow(try TransactionStager.stage(
            WorldTransaction().add(body(100, .circle(radius: 5), at: [16, 10])), against: initial))
        XCTAssertNoThrow(try TransactionStager.stage(
            WorldTransaction().add(body(100, rectangle([20, 20], [30, 30]))), against: initial))
    }

    /// G7-AC1: brzeg liczy się jako wnętrze, także lewa krawędź wielokąta, którą parzystość przecięć odrzucała.
    func testBubbleCenterOnTheBoundaryCountsAsInside() throws {
        let shapes: [(String, RigidShape, WorldPoint, WorldPoint)] = [
            ("lewa krawędź wielokąta", try rectangle([0, 0], [4, 4]), .zero, [0, 2]),
            ("prawa krawędź wielokąta", try rectangle([0, 0], [4, 4]), .zero, [4, 2]),
            ("dolna krawędź wielokąta", try rectangle([0, 0], [4, 4]), .zero, [2, 0]),
            ("górna krawędź wielokąta", try rectangle([0, 0], [4, 4]), .zero, [2, 4]),
            ("wierzchołek wielokąta", try rectangle([0, 0], [4, 4]), .zero, [0, 0]),
            ("brzeg koła", .circle(radius: 5), [0, 0], [5, 0]),
            ("brzeg kapsuły", .capsule(halfLength: 4, radius: 1), [0, 0], [0, 1]),
        ]
        for (name, shape, position, center) in shapes {
            let initial = try state([resources().add(body(100, shape, at: position))])
            assertRejected(WorldTransaction().add(try bubble(1, at: center)), against: initial, index: 0, bubble: 1, .insideRigidBody,
                           "bańka na \(name)")
            let withBubble = try state([resources().add(bubble(1, at: center))])
            assertRejected(WorldTransaction().add(try body(100, shape, at: position)), against: withBubble, index: 0, bubble: 1,
                           .insideRigidBody, "bryła z bańką na \(name)")
        }
    }

    // MARK: replace i replaceRigidBodies (P-B-35)

    func testReplacedBodyCoveringABubbleCenterIsRejected() throws {
        let initial = try state([resources().add(bubble(1, at: [10, 10])).add(body(100, rectangle([40, 40], [50, 50])))])
        assertRejected(WorldTransaction().replace(id(100), with: try body(100, rectangle([5, 5], [15, 15]))),
                       against: initial, index: 0, bubble: 1, .insideRigidBody)
        XCTAssertNoThrow(try TransactionStager.stage(
            WorldTransaction().replace(id(100), with: body(100, rectangle([60, 60], [70, 70]))), against: initial))
    }

    func testReplaceRigidBodiesResultCoveringABubbleCenterIsRejected() throws {
        let initial = try state([resources().add(bubble(1, at: [10, 10])).add(body(100, rectangle([40, 40], [50, 50])))
            .add(body(101, rectangle([60, 60], [70, 70])))])
        assertRejected(WorldTransaction().replaceRigidBodies([id(100), id(101)], with: [
            try bodyDescriptor(102, rectangle([50, 50], [55, 55])), try bodyDescriptor(103, .circle(radius: 4), at: [9, 10])]),
            against: initial, index: 0, bubble: 1, .insideRigidBody)
        XCTAssertNoThrow(try TransactionStager.stage(WorldTransaction().replaceRigidBodies([id(100), id(101)], with: [
            try bodyDescriptor(102, rectangle([50, 50], [55, 55])), try bodyDescriptor(103, .circle(radius: 4), at: [-50, 10])]),
            against: initial))
    }

    /// Bryła i bańka w jednej transakcji: kolejność operacji nie ma znaczenia dla wyniku, a indeks wskazuje drugą z nich.
    func testBodyAndBubbleInOneTransactionAreRejectedInEitherOrder() throws {
        let initial = try state([resources()])
        assertRejected(WorldTransaction().add(try bubble(1, at: [10, 10])).add(try body(100, .circle(radius: 5), at: [10, 10])),
                       against: initial, index: 1, bubble: 1, .insideRigidBody)
        assertRejected(WorldTransaction().add(try body(100, .circle(radius: 5), at: [10, 10])).add(try bubble(1, at: [10, 10])),
                       against: initial, index: 1, bubble: 1, .insideRigidBody)
    }

    // MARK: filtry (P-B-35)

    func testBodyExcludedByTheCollisionFilterMayCoverTheBubbleCenter() throws {
        let bubbleOnly = CollisionFilter(category: 0b01, mask: 0b01)
        let bodyOnly = CollisionFilter(category: 0b10, mask: 0b10)
        let initial = try state([resources().add(bubble(1, at: [10, 10], filter: bubbleOnly))])
        XCTAssertNoThrow(try TransactionStager.stage(
            WorldTransaction().add(body(100, .circle(radius: 5), at: [10, 10], filter: bodyOnly)), against: initial))
        let withBody = try state([resources().add(body(100, .circle(radius: 5), at: [10, 10], filter: bodyOnly))])
        XCTAssertNoThrow(try TransactionStager.stage(WorldTransaction().add(bubble(1, at: [10, 10], filter: bubbleOnly)),
                                                     against: withBody))
        // Kolidujący filtr tej samej sceny jest odrzucany.
        assertRejected(WorldTransaction().add(try body(100, .circle(radius: 5), at: [10, 10], filter: bubbleOnly)),
                       against: initial, index: 0, bubble: 1, .insideRigidBody)
    }

    func testOnlyBubblesCollidingWithTheBodyAreReported() throws {
        let bubbleOnly = CollisionFilter(category: 0b01, mask: 0b01)
        let initial = try state([resources().add(bubble(1, at: [10, 10], filter: bubbleOnly)).add(bubble(2, at: [11, 10]))])
        assertRejected(WorldTransaction().add(try body(100, .circle(radius: 5), at: [10, 10], filter: CollisionFilter(category: 0b10, mask: 0b11))),
                       against: initial, index: 0, bubble: 2, .insideRigidBody)
    }

    // MARK: stała tolerancja wspólnego środka (P-B-36)

    /// Próg to max(1e-4 · min(r_a, r_b), 1e-4), stały: dla r = 0,5 część względna to 5e-5, więc rządzi tolerancja położenia 1e-4.
    func testCoincidentCenterToleranceIsTheConstantOneEMinusFour() throws {
        XCTAssertEqual(PlacementGeometry.positionTolerance, 1e-4)
        XCTAssertEqual(PlacementGeometry.coincidentCenterTolerance(radius: 0.5, otherRadius: 0.5), 1e-4)
        XCTAssertEqual(PlacementGeometry.coincidentCenterTolerance(radius: 2, otherRadius: 30), 2e-4, accuracy: 1e-10)
        let initial = try state([resources().add(bubble(1, at: [10, 10], radius: 0.5))])
        assertRejected(WorldTransaction().add(try bubble(2, at: [10.00008, 10], radius: 0.5)), against: initial, index: 0,
                       bubble: 2, .coincidentCenter)
        XCTAssertNoThrow(try TransactionStager.stage(WorldTransaction().add(bubble(2, at: [10.0002, 10], radius: 0.5)),
                                                     against: initial))
    }
}
