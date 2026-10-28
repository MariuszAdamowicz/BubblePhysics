import BubblePhysics
import Metal
import XCTest

@MainActor
final class ArenaSpawnTests: XCTestCase {
    func testSemanticArenaCarriesDriveAndMergeRulesIntoSpawnedBubbles() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let material = PhysicsMaterialID(rawValue: 1), style = RenderStyleID(rawValue: 1)
        let drivePolicy = try BubbleDrivePolicy(maximumSpeed: 30, distanceResponse: 12)
        let arena = try ArenaPreset(id: "round", bounds: .init(min: [-1.1, -5], max: [1.1, 5]),
            bubbleRadius: 1, physicsMaterialID: material, renderStyleID: style,
            drivePolicy: drivePolicy, mergeGroups: MergeGroupSet(rawValue: 1), eventInterest: [.mergeContact])
        let world = try BubbleWorld(configuration: WorldConfiguration(simulationRegion: .init(min: [-10, -10], max: [10, 10]),
            fixedTimeStep: 1.0 / 60, arenas: [arena]), device: device)
        world.submit(WorldTransaction().updatePhysicsMaterial(material, material: try PhysicsMaterial(kind: .bubble))
            .updateRenderStyle(style, style: try RenderStyle()))
        _ = await world.advance(by: 1.0 / 60)

        let firstToken = world.submit(WorldTransaction().spawnBubble(.init(value: 2, arena: "round", seed: 3)))
        let firstFrame = await world.advance(by: 1.0 / 60)
        let first = try XCTUnwrap(firstFrame.transactionReceipts.first { $0.token == firstToken }?.createdObjectIDs.first)
        let secondToken = world.submit(WorldTransaction().spawnBubble(.init(value: 2, arena: "round", seed: 17)))
        let secondFrame = await world.advance(by: 1.0 / 60)
        let second = try XCTUnwrap(secondFrame.transactionReceipts.first { $0.token == secondToken }?.createdObjectIDs.first)
        let contours = world.debugContourSnapshot()
        let target = try XCTUnwrap(contours[second]).reduce(WorldPoint.zero, +) / Float(try XCTUnwrap(contours[second]).count)

        world.submit(WorldTransaction().beginPlayerDrive(first, target: target))
        var events: [WorldEvent] = []
        for _ in 0..<180 { events += (await world.advance(by: 1.0 / 60)).events }
        XCTAssertTrue(events.contains { if case .mergeContact(first, second, _) = $0 { true } else if case .mergeContact(second, first, _) = $0 { true } else { false } })
    }

    func testSeededSemanticSpawnPublishesDeterministicReceiptsWithoutGameGeometry() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let arena = try ArenaPreset(id: "small", bounds: .init(min: [-1.05, -1.05], max: [1.05, 1.05]),
            bubbleRadius: 1, physicsMaterialID: .init(rawValue: 1), renderStyleID: .init(rawValue: 1))
        let configuration = try WorldConfiguration(simulationRegion: .init(min: [-10, -8], max: [10, 8]),
            fixedTimeStep: 1.0 / 60, arenas: [arena])
        let first = try BubbleWorld(configuration: configuration, device: device)
        let second = try BubbleWorld(configuration: configuration, device: device)
        let material = PhysicsMaterialID(rawValue: 1), style = RenderStyleID(rawValue: 1)
        let setup = WorldTransaction().updatePhysicsMaterial(material, material: try PhysicsMaterial(kind: .bubble))
            .updateRenderStyle(style, style: try RenderStyle())
        first.submit(setup); second.submit(setup)
        _ = await first.advance(by: 1.0 / 60); _ = await second.advance(by: 1.0 / 60)

        let request = SpawnBubbleRequest(value: 3, arena: "small", seed: 42)
        let firstToken = first.submit(WorldTransaction().spawnBubble(request))
        let secondToken = second.submit(WorldTransaction().spawnBubble(request))
        let firstFrame = await first.advance(by: 1.0 / 60)
        let secondFrame = await second.advance(by: 1.0 / 60)
        let firstReceipt = try XCTUnwrap(firstFrame.transactionReceipts.first { $0.token == firstToken })
        let secondReceipt = try XCTUnwrap(secondFrame.transactionReceipts.first { $0.token == secondToken })
        XCTAssertEqual(firstReceipt.createdObjectIDs, secondReceipt.createdObjectIDs)
        XCTAssertEqual(firstReceipt.createdObjectIDs.count, 1)
        XCTAssertEqual(first.debugContourSnapshot(), second.debugContourSnapshot())

        let invalid = SpawnBubbleRequest(value: 0, arena: "small", seed: 42)
        let unknown = SpawnBubbleRequest(value: 3, arena: "missing", seed: 42)
        let invalidToken = first.submit(WorldTransaction().spawnBubble(invalid))
        let unknownToken = first.submit(WorldTransaction().spawnBubble(unknown))
        let fullToken = first.submit(WorldTransaction().spawnBubble(request))
        let rejected = await first.advance(by: 1.0 / 60)
        XCTAssertFalse(rejected.transactionReceipts.contains { $0.token == invalidToken || $0.token == unknownToken || $0.token == fullToken })
        XCTAssertTrue(rejected.events.contains { if case .transactionRejected(invalidToken, _) = $0 { true } else { false } })
        XCTAssertTrue(rejected.events.contains { if case .transactionRejected(unknownToken, _) = $0 { true } else { false } })
        XCTAssertTrue(rejected.events.contains { if case .transactionRejected(fullToken, _) = $0 { true } else { false } })
        XCTAssertEqual(first.debugContourSnapshot().count, 1)
    }
}
