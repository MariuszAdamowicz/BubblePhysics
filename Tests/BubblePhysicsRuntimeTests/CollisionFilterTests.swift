import BubblePhysics
@testable import BubblePhysicsRuntime
import XCTest

/// P-B-11 (strona modelu): filtr kolizji, jego warunek obustronny i przekazanie do wyniku scalenia i podziału.
final class CollisionFilterTests: XCTestCase {
    private let materialID = PhysicsMaterialID(rawValue: 1)
    private let styleID = RenderStyleID(rawValue: 1)
    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }
    private func state() throws -> RuntimeState {
        RuntimeState(configuration: try WorldConfiguration(simulationRegion:
            WorldRectangle(min: [-100, -100], max: [100, 100])))
    }
    private func resources() throws -> WorldTransaction {
        WorldTransaction()
            .updatePhysicsMaterial(materialID, material: try PhysicsMaterial(kind: .bubble))
            .updateRenderStyle(styleID, style: try RenderStyle())
    }

    func testDefaultFilterCollidesWithEverythingIncludingItself() {
        let any = CollisionFilter(category: 0x8000_0000, mask: 0x1)
        XCTAssertTrue(CollisionFilter.default.collides(with: .default))
        XCTAssertTrue(CollisionFilter.default.collides(with: any) == (any.mask & CollisionFilter.default.category != 0))
        XCTAssertEqual(CollisionFilter.default.mask, .max)
        XCTAssertNotEqual(CollisionFilter.default.category, 0)
    }

    func testCollisionRequiresEachCategoryInTheOthersMask() {
        let a = CollisionFilter(category: 0b01, mask: 0b10)
        let b = CollisionFilter(category: 0b10, mask: 0b01)
        let oneSided = CollisionFilter(category: 0b10, mask: 0b00)
        XCTAssertTrue(a.collides(with: b))
        XCTAssertTrue(b.collides(with: a))
        XCTAssertFalse(a.collides(with: oneSided), "kategoria drugiego jest w masce pierwszego, ale nie odwrotnie")
        XCTAssertFalse(oneSided.collides(with: a))
        XCTAssertFalse(a.collides(with: a))
    }

    func testDescriptorsCarryTheFilterAndDefaultToTheDefaultFilter() throws {
        let filter = CollisionFilter(category: 4, mask: 8)
        let bubble = try BubbleDescriptor(id: id(1), position: .zero, targetRadius: 1, physicsMaterialID: materialID,
                                          renderStyleID: styleID, filter: filter)
        let polygon = try PolygonDescriptor(id: id(2), vertices: [[0, 0], [1, 0], [0, 1]], physicsMaterialID: materialID,
                                            renderStyleID: styleID, filter: filter)
        XCTAssertEqual(bubble.filter, filter)
        XCTAssertEqual(polygon.filter, filter)
        XCTAssertEqual(try BubbleDescriptor(id: id(3), position: .zero, targetRadius: 1, physicsMaterialID: materialID,
                                            renderStyleID: styleID).filter, .default)
    }

    func testMergeAndSplitResultsTakeTheFilterFromBubbleResult() throws {
        let filter = CollisionFilter(category: 2, mask: 6)
        let a = try BubbleDescriptor(id: id(1), position: [0, 0], targetRadius: 1, physicsMaterialID: materialID, renderStyleID: styleID)
        let b = try BubbleDescriptor(id: id(2), position: [1, 0], targetRadius: 1, physicsMaterialID: materialID, renderStyleID: styleID)
        let seeded = try TransactionStager.stage(resources().add(.bubble(a)).add(.bubble(b)), against: state()).state
        let merged = try TransactionStager.stage(WorldTransaction().mergeBubbles([id(1), id(2)],
            result: BubbleResult(id: id(3), physicsMaterialID: materialID, renderStyleID: styleID, filter: filter)),
            against: seeded).state
        guard case .bubble(let result) = try XCTUnwrap(merged.objects[id(3)]).descriptor else { return XCTFail("brak bańki") }
        XCTAssertEqual(result.filter, filter)

        let parts = [BubbleSplitPart(result: BubbleResult(id: id(4), physicsMaterialID: materialID, renderStyleID: styleID, filter: filter), share: 0.5),
                     BubbleSplitPart(result: BubbleResult(id: id(5), physicsMaterialID: materialID, renderStyleID: styleID), share: 0.5)]
        let split = try TransactionStager.stage(WorldTransaction().splitBubble(id(1), first: parts[0], second: parts[1]),
                                                against: seeded).state
        guard case .bubble(let first) = try XCTUnwrap(split.objects[id(4)]).descriptor,
              case .bubble(let second) = try XCTUnwrap(split.objects[id(5)]).descriptor else { return XCTFail("brak baniek") }
        XCTAssertEqual(first.filter, filter)
        XCTAssertEqual(second.filter, .default)
    }
}
