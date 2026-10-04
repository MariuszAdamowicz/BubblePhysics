import XCTest
import Metal
import BubblePhysicsReference
@testable import BubblePhysicsReferenceMetal

final class ReferenceMetalCapacityManagerTests: XCTestCase {
    func testOverflowRetriesFromUnchangedInputAndPublishesOnlyRetryResult() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let manager = ReferenceMetalCapacityManager(device: device)
        var world = ReferenceWorld(configuration: .default, broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 42), center: .init(x: 3, y: 4), mass: 1, targetRadius: 2))
        let snapshot = ReferenceMetalSnapshot(world: world)
        let requirements = ReferenceMetalFrameRequirements(snapshot: snapshot, capacities: [.contacts: 1, .components: 3])
        var attempts = 0
        var originalComponents: MTLBuffer?
        var originalInput: MTLBuffer?
        let telemetry = try await manager.retryingFrame(requirements: requirements) { attempt in
            attempts += 1
            XCTAssertEqual(attempt.snapshot, snapshot)
            XCTAssertEqual(attempt.snapshot.configuration, world.configuration)
            XCTAssertNil(manager.publishedOutput)
            XCTAssertEqual(attempt.snapshot.centers, [SIMD2(3, 4)])
            let input = attempt.inputBuffers["centers"]!.contents().bindMemory(to: SIMD2<Float>.self, capacity: 1)
            XCTAssertEqual(input.pointee, SIMD2(3, 4))
            if attempts == 1 {
                input.pointee = SIMD2(99, 99)
                originalComponents = attempt.buffers[.components]
                originalInput = attempt.inputBuffers["centers"]
                return .init(output: .init(centers: [SIMD2(99, 99)], velocities: [.zero]), telemetry: .init(backend: .metal, finalResidual: 99), exhausted: [.contacts: 9])
            }
            XCTAssertTrue(attempt.buffers[.components] === originalComponents)
            XCTAssertTrue(attempt.inputBuffers["centers"] === originalInput)
            XCTAssertGreaterThanOrEqual(attempt.capacities[.contacts]!, 9)
            XCTAssertEqual(attempt.capacities[.components], 3)
            return .init(output: .init(centers: [SIMD2(5, 6)], velocities: [SIMD2(1, 2)]), telemetry: .init(backend: .metal, finalResidual: 0.25))
        }
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(telemetry.finalResidual, 0.25)
        XCTAssertTrue(telemetry.didOverflow)
        XCTAssertEqual(manager.publishedOutput?.centers, [SIMD2(5, 6)])
    }

    func testEncodingErrorDoesNotPublishPartialFrame() async throws {
        enum Failure: Error { case encode }
        let manager = ReferenceMetalCapacityManager(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let snapshot = ReferenceMetalSnapshot(world: ReferenceWorld(configuration: .default, broadPhase: BruteForceBroadPhase()))
        do {
            _ = try await manager.retryingFrame(requirements: .init(snapshot: snapshot)) { _ in throw Failure.encode }
            XCTFail("Expected encoding failure")
        } catch Failure.encode { }
        XCTAssertNil(manager.publishedOutput)
    }

    func testUnclassifiedOverflowNeverPublishesOutput() async throws {
        let manager = ReferenceMetalCapacityManager(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let snapshot = ReferenceMetalSnapshot(world: ReferenceWorld(configuration: .default, broadPhase: BruteForceBroadPhase()))
        do {
            _ = try await manager.retryingFrame(requirements: .init(snapshot: snapshot)) { _ in
                .init(output: .init(centers: [], velocities: []), telemetry: .init(didOverflow: true))
            }
            XCTFail("Overflow without an exhausted allocation must not be published")
        } catch ReferenceMetalCapacityError.invalidOverflowReport { }
        XCTAssertNil(manager.publishedOutput)
    }

    func testByteCountOverflowFailsBeforeEncoding() async throws {
        let manager = ReferenceMetalCapacityManager(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let snapshot = ReferenceMetalSnapshot(world: ReferenceWorld(configuration: .default, broadPhase: BruteForceBroadPhase()))
        do {
            _ = try await manager.retryingFrame(requirements: .init(snapshot: snapshot, capacities: [.contacts: Int.max])) { _ in
                XCTFail("Impossible byte count must fail before encoding")
                return .init(output: .init(centers: [], velocities: []), telemetry: .init())
            }
            XCTFail("Expected capacity overflow")
        } catch ReferenceMetalCapacityError.capacityOverflow { }
        XCTAssertNil(manager.publishedOutput)
    }

    func testInputAllocationsPersistAcrossFramesAndRefreshSnapshot() async throws {
        let manager = ReferenceMetalCapacityManager(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var world = ReferenceWorld(configuration: .default, broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 1), center: .init(x: 2, y: 3), mass: 1, targetRadius: 2))
        var originalInput: MTLBuffer?
        for center in [SIMD2<Float>(2, 3), SIMD2<Float>(4, 5)] {
            world.updateBubble(try .init(id: .init(rawValue: 1), center: .init(x: center.x, y: center.y), mass: 1, targetRadius: 2))
            _ = try await manager.retryingFrame(requirements: .init(snapshot: .init(world: world))) { attempt in
                let input = attempt.inputBuffers["centers"]!
                if let originalInput { XCTAssertTrue(input === originalInput) }
                originalInput = input
                XCTAssertEqual(input.contents().bindMemory(to: SIMD2<Float>.self, capacity: 1).pointee, center)
                return .init(output: .init(centers: [center], velocities: [.zero]), telemetry: .init())
            }
        }
        XCTAssertEqual(manager.publishedOutput?.centers, [SIMD2(4, 5)])
    }

    func testPhysicalDeviceLimitRejectsAllocationWithoutTruncatingCount() throws {
        XCTAssertEqual(try ReferenceMetalCapacityManager.byteLength(count: 4, stride: 16, maximum: 64), 64)
        XCTAssertThrowsError(try ReferenceMetalCapacityManager.byteLength(count: 5, stride: 16, maximum: 64))
        XCTAssertThrowsError(try ReferenceMetalCapacityManager.byteLength(count: Int.max, stride: 16, maximum: Int.max))
    }
}
