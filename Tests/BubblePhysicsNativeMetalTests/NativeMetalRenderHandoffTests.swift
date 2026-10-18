import BubblePhysicsModel
import Metal
@testable import BubblePhysicsNativeMetal
import XCTest

@MainActor
final class NativeMetalRenderHandoffTests: XCTestCase {
    func testPublishedHandoffSurvivesRejectedNextFrame() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try NativePublicWorld(device: device)
        let bubble = NativePublicObject(descriptor: .bubble(try BubbleDescriptor(
            id: .init(rawValue: 7), position: [0, 0], targetRadius: 1,
            physicsMaterialID: .init(rawValue: 1), renderStyleID: .init(rawValue: 1))))
        let materials = try [PhysicsMaterialID(rawValue: 1): PhysicsMaterial(kind: .bubble)]
        let styles = try [RenderStyleID(rawValue: 1): RenderStyle()]
        let region = try WorldRectangle(min: [-10, -10], max: [10, 10])
        _ = try await world.step(objects: [bubble], materials: materials, styles: styles,
                                 region: region, duration: 1.0 / 60)
        let previous = try XCTUnwrap(world.publishedRenderHandoff)
        XCTAssertEqual(previous.bubbleCount, 1)
        do {
            _ = try await world.step(objects: [bubble], materials: materials, styles: styles,
                                     region: region, duration: .nan)
            XCTFail("Nieprawidłowa klatka musi zostać odrzucona")
        } catch { }
        XCTAssertTrue(world.publishedRenderHandoff === previous)
    }

    func testPublicFrameDoesNotMaterializeContourSnapshot() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try NativePublicWorld(device: device)
        let bubble = NativePublicObject(descriptor: .bubble(try BubbleDescriptor(
            id: .init(rawValue: 7), position: [0, 0], targetRadius: 1,
            physicsMaterialID: .init(rawValue: 1), renderStyleID: .init(rawValue: 1))))
        _ = try await world.step(objects: [bubble],
            materials: [.init(rawValue: 1): PhysicsMaterial(kind: .bubble)],
            styles: [.init(rawValue: 1): RenderStyle()],
            region: WorldRectangle(min: [-10, -10], max: [10, 10]), duration: 1.0 / 60)
        XCTAssertEqual(world.publishedContourCPUReadbackCount, 0)
        let debug = try XCTUnwrap(world.publishedRenderHandoff).debugContourSnapshot()
        XCTAssertGreaterThanOrEqual(debug[.init(rawValue: 7)]?.count ?? 0, 32)
    }
}
