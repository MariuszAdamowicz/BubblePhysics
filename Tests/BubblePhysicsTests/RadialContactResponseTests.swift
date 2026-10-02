import XCTest
@testable import BubblePhysics

final class RadialContactResponseTests: XCTestCase {
    func testSingleSurfaceContactCompressesSensorAndPushesBodyAlongNormal() {
        let bubble = makeBubble()
        let contact = RadialSurfaceContact(
            sensorStartIndex: 0,
            sensorEndIndex: 1,
            barycentric: 0.25,
            point: Vector2(x: 10, y: 0),
            normal: Vector2(x: -1, y: 0),
            penetration: 2,
            relativeVelocity: .zero,
            sourceID: 11
        )

        let load = RadialContactResponse.reduce(contacts: [contact], for: bubble)

        XCTAssertEqual(load.sensorCompression[0], 1.5, accuracy: 1e-5)
        XCTAssertEqual(load.sensorCompression[1], 0.5, accuracy: 1e-5)
        XCTAssertEqual(load.sensorPressureDeltas[0], 15, accuracy: 1e-5)
        XCTAssertEqual(load.sensorPressureDeltas[1], 5, accuracy: 1e-5)
        XCTAssertEqual(load.force.x, -20, accuracy: 1e-5)
        XCTAssertEqual(load.force.y, 0, accuracy: 1e-5)
        XCTAssertEqual(load.torque, 0, accuracy: 1e-5)
    }

    func testOffCenterContactProducesTorque() {
        let bubble = makeBubble()
        let contact = RadialSurfaceContact(
            sensorStartIndex: 2,
            sensorEndIndex: 3,
            barycentric: 0,
            point: Vector2(x: 0, y: 10),
            normal: Vector2(x: 1, y: 0),
            penetration: 1,
            relativeVelocity: .zero,
            sourceID: 12
        )

        let load = RadialContactResponse.reduce(contacts: [contact], for: bubble)

        XCTAssertEqual(load.force.x, 10, accuracy: 1e-5)
        XCTAssertEqual(load.force.y, 0, accuracy: 1e-5)
        XCTAssertEqual(load.torque, -100, accuracy: 1e-5)
    }

    func testSymmetricOpposingContactsProduceNoNetForceOrTorque() {
        let bubble = makeBubble()
        let contacts = [
            RadialSurfaceContact(
                sensorStartIndex: 0,
                sensorEndIndex: 1,
                barycentric: 0,
                point: Vector2(x: 10, y: 0),
                normal: Vector2(x: -1, y: 0),
                penetration: 1,
                relativeVelocity: .zero,
                sourceID: 1
            ),
            RadialSurfaceContact(
                sensorStartIndex: 4,
                sensorEndIndex: 5,
                barycentric: 0,
                point: Vector2(x: -10, y: 0),
                normal: Vector2(x: 1, y: 0),
                penetration: 1,
                relativeVelocity: .zero,
                sourceID: 2
            )
        ]

        let load = RadialContactResponse.reduce(contacts: contacts, for: bubble)

        XCTAssertEqual(load.force.x, 0, accuracy: 1e-5)
        XCTAssertEqual(load.force.y, 0, accuracy: 1e-5)
        XCTAssertEqual(load.torque, 0, accuracy: 1e-5)
    }

    func testContactReductionIsIndependentOfInputOrder() {
        let bubble = makeBubble()
        let contacts = [
            makeContact(sourceID: 30, sensor: 0, point: Vector2(x: 10, y: 1), normal: Vector2(x: -1, y: 0), penetration: 0.7),
            makeContact(sourceID: 10, sensor: 2, point: Vector2(x: -2, y: 9), normal: Vector2(x: 0, y: -1), penetration: 1.1),
            makeContact(sourceID: 20, sensor: 5, point: Vector2(x: -7, y: -4), normal: Vector2(x: 0.6, y: 0.8), penetration: 0.4)
        ]
        let expected = RadialContactResponse.reduce(contacts: contacts, for: bubble)

        for permutation in permutations(of: contacts) {
            XCTAssertEqual(RadialContactResponse.reduce(contacts: permutation, for: bubble), expected)
        }
    }

    func testBodyLoadDoesNotGrowWhenSameSurfaceUsesMoreSensors() {
        let coarse = makeBubble()
        let dense = RadialSensorRemesher.resample(coarse, to: 16)
        let coarseContact = RadialSurfaceContact(
            sensorStartIndex: 0, sensorEndIndex: 1, barycentric: 0,
            point: Vector2(x: 10, y: 0), normal: Vector2(x: -1, y: 0),
            penetration: 2, relativeVelocity: .zero, sourceID: 1
        )
        let denseContacts = [0, 1].map { index in
            RadialSurfaceContact(
                sensorStartIndex: index, sensorEndIndex: index + 1, barycentric: 0,
                point: Vector2(x: 10, y: 0), normal: Vector2(x: -1, y: 0),
                penetration: 2, relativeVelocity: .zero, sourceID: UInt64(index + 1)
            )
        }

        let coarseLoad = RadialContactResponse.reduce(contacts: [coarseContact], for: coarse)
        let denseLoad = RadialContactResponse.reduce(contacts: denseContacts, for: dense)

        XCTAssertEqual(denseLoad.force.x, coarseLoad.force.x, accuracy: 1e-5)
    }

    private func makeBubble() -> RadialBubbleState {
        var bubble = RadialBubbleState.collapsed(
            id: BubbleID(rawValue: 1),
            center: .zero,
            targetRadius: 10,
            maxSegmentLength: 10,
            mass: 2
        )
        bubble.birthProgress = 1
        bubble.material = SpringMaterial(quadraticStiffness: 10, quarticStiffness: 0, drag: 0)
        for index in bubble.sensors.indices {
            bubble.sensors[index].length = 10
            bubble.sensors[index].targetLength = 10
        }
        return bubble
    }

    private func makeContact(
        sourceID: UInt64,
        sensor: Int,
        point: Vector2,
        normal: Vector2,
        penetration: Float
    ) -> RadialSurfaceContact {
        RadialSurfaceContact(
            sensorStartIndex: sensor,
            sensorEndIndex: (sensor + 1) % 8,
            barycentric: 0.3,
            point: point,
            normal: normal,
            penetration: penetration,
            relativeVelocity: .zero,
            sourceID: sourceID
        )
    }

    private func permutations<T>(of values: [T]) -> [[T]] {
        guard values.count > 1 else { return [values] }
        return values.indices.flatMap { index -> [[T]] in
            var remainder = values
            let value = remainder.remove(at: index)
            return permutations(of: remainder).map { [value] + $0 }
        }
    }
}
