import XCTest
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalContourContactLayoutTests: XCTestCase {
    func testContactRecordMatchesMetalStrideAndRoundTripsSourceIdentity() {
        let record = MetalContourContact(
            pointIndex: 7,
            edgeStartIndex: 11,
            edgeEndIndex: 12,
            barycentric: 0.25,
            normal: SIMD2(0, -1),
            penetration: 3.5,
            sourceID: 0x0001_0002_0003_0004
        )

        XCTAssertEqual(MemoryLayout<MetalContourContact>.stride, 48)
        XCTAssertEqual(record.sourceID, 0x0001_0002_0003_0004)
        XCTAssertEqual(record.barycentric, 0.25)
    }

    func testCapacityPlanDetectsOverflowBeforeWritingPartialPair() {
        let plan = MetalContourContactCapacityPlan(capacity: 8)

        XCTAssertEqual(plan.reservation(for: [3, 5]), .fits(totalCount: 8))
        XCTAssertEqual(plan.reservation(for: [3, 6]), .overflow(requiredCapacity: 9))
    }

    func testSourceRangesAreStableByPairDirectionAndFeature() {
        let first = MetalContourContactSourceID(pairIndex: 4, direction: 1, feature: 9)
        let second = MetalContourContactSourceID(pairIndex: 4, direction: 1, feature: 10)

        XCTAssertLessThan(first.rawValue, second.rawValue)
        XCTAssertEqual(first, MetalContourContactSourceID(pairIndex: 4, direction: 1, feature: 9))
    }
}
