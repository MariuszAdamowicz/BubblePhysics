import XCTest
@testable import BubblePhysics

final class RadialWorldStateTests: XCTestCase {
    func testWorldBuildsStableContiguousRanges() throws {
        let world = try RadialWorldState(bubbles: [
            bubble(id: 30, sensorCount: 8),
            bubble(id: 10, sensorCount: 13),
            bubble(id: 20, sensorCount: 257)
        ])

        XCTAssertEqual(world.ranges, [
            RadialBubbleRange(bubbleIndex: 0, sensorStart: 0, sensorCount: 8),
            RadialBubbleRange(bubbleIndex: 1, sensorStart: 8, sensorCount: 13),
            RadialBubbleRange(bubbleIndex: 2, sensorStart: 21, sensorCount: 257)
        ])
        XCTAssertEqual(world.totalSensorCount, 278)
    }

    func testWorldRejectsDuplicateBubbleIDs() {
        XCTAssertThrowsError(try RadialWorldState(bubbles: [
            bubble(id: 7, sensorCount: 8),
            bubble(id: 7, sensorCount: 13)
        ])) { error in
            XCTAssertEqual(error as? RadialWorldStateError, .duplicateBubbleID(BubbleID(rawValue: 7)))
        }
    }

    func testLookupUsesStableBubbleID() throws {
        let expected = bubble(id: 42, sensorCount: 13)
        let world = try RadialWorldState(bubbles: [bubble(id: 9, sensorCount: 8), expected])

        XCTAssertEqual(world.bubble(for: BubbleID(rawValue: 42)), expected)
        XCTAssertNil(world.bubble(for: BubbleID(rawValue: 99)))
    }

    private func bubble(id: Int, sensorCount: Int) -> RadialBubbleState {
        let collapsed = RadialBubbleState.collapsed(
            id: BubbleID(rawValue: id), center: .zero,
            targetRadius: 20, maxSegmentLength: 5, mass: 1
        )
        return RadialSensorRemesher.resample(collapsed, to: sensorCount)
    }
}
