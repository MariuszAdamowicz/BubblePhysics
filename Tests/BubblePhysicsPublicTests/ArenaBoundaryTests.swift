import BubblePhysics
import XCTest

@MainActor
final class ArenaBoundaryTests: XCTestCase {
    func testPresetOwnsFourPhysicalBoundariesWhileSimulationRegionRemainsNonPhysical() async throws {
        let arena = try ArenaPreset(id: "box", bounds: .init(min: [-2, -2], max: [2, 2]),
            bubbleRadius: 0.5, physicsMaterialID: .init(rawValue: 1), renderStyleID: .init(rawValue: 1))
        let region = try WorldRectangle(min: [-10, -10], max: [10, 10])

        for (target, coordinate, direction) in [
            (WorldPoint(-8, 0), 0, -1), (WorldPoint(8, 0), 0, 1),
            (WorldPoint(0, -8), 1, -1), (WorldPoint(0, 8), 1, 1)
        ] {
            let world = try BubbleWorld(configuration: WorldConfiguration(simulationRegion: region,
                arenas: [arena]))
            let id = ObjectID(rawValue: 1)
            world.submit(try WorldTransaction()
                .updatePhysicsMaterial(.init(rawValue: 1), material: PhysicsMaterial(kind: .bubble))
                .updateRenderStyle(.init(rawValue: 1), style: RenderStyle())
                .add(.bubble(BubbleDescriptor(id: id, position: .zero, targetRadius: 0.5,
                    physicsMaterialID: .init(rawValue: 1), renderStyleID: .init(rawValue: 1))))
                .beginPlayerDrive(id, target: target))

            var frame = await world.advance(by: 1.0 / 60)
            for _ in 0..<80 { frame = await world.advance(by: 1.0 / 60) }
            let achieved = try XCTUnwrap(frame.driveFeedback.first?.achievedPoint)
            let component = coordinate == 0 ? achieved.x : achieved.y
            XCTAssertEqual(Float(direction) * component, 1.5, accuracy: 0.08,
                "Arena boundary should stop drive toward \(target)")
            XCTAssertNil(world.diagnostics.lastAdvanceIssue)
        }

        let unbounded = try BubbleWorld(configuration: WorldConfiguration(simulationRegion: region))
        let id = ObjectID(rawValue: 2)
        unbounded.submit(try WorldTransaction()
            .updatePhysicsMaterial(.init(rawValue: 1), material: PhysicsMaterial(kind: .bubble))
            .updateRenderStyle(.init(rawValue: 1), style: RenderStyle())
            .add(.bubble(BubbleDescriptor(id: id, position: .zero, targetRadius: 0.5,
                physicsMaterialID: .init(rawValue: 1), renderStyleID: .init(rawValue: 1))))
            .beginPlayerDrive(id, target: [5, 0]))
        var unboundedFrame = await unbounded.advance(by: 1.0 / 60)
        for _ in 0..<30 { unboundedFrame = await unbounded.advance(by: 1.0 / 60) }
        XCTAssertGreaterThan(try XCTUnwrap(unboundedFrame.driveFeedback.first?.achievedPoint.x), 2)
        XCTAssertNil(unbounded.diagnostics.lastAdvanceIssue)
    }
}
