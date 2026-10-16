import BubblePhysicsModel
import Metal
@testable import BubblePhysicsNativeMetal
import XCTest

@MainActor
final class NativeMetalPublicObjectTests: XCTestCase {
    func testRemovingEarlierPolygonDoesNotUploadUnchangedRemainingGeometry() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let objects = try [UInt64(1), UInt64(2)].map { id in
            NativePublicObject(descriptor: .polygon(try PolygonDescriptor(id: .init(rawValue: id),
                vertices: [[0, 0], [1, 0], [0, 1]], position: [Float(id) * 3, 0],
                physicsMaterialID: .init(rawValue: 1), renderStyleID: .init(rawValue: 1))))
        }
        let materials = try [PhysicsMaterialID(rawValue: 1): PhysicsMaterial(kind: .polygon)]
        let styles = try [RenderStyleID(rawValue: 1): RenderStyle()]
        let region = try WorldRectangle(min: [-10, -10], max: [10, 10])
        _ = try await world.step(objects: objects, materials: materials, styles: styles, region: region, duration: 0.25)
        let frame = try await world.step(objects: [objects[1]], materials: materials, styles: styles, region: region, duration: 0.25)
        XCTAssertEqual(frame.profile.segmentUploadCount, 0)
    }

    func testRemovalCompactsGPUWithoutResettingRemainingObjectMotion() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let objects = try [
            NativePublicObject(descriptor: .bubble(BubbleDescriptor(id: .init(rawValue: 1), position: [9, 5],
                velocity: [8, 0], targetRadius: 1, physicsMaterialID: .init(rawValue: 1), renderStyleID: .init(rawValue: 1)))),
            NativePublicObject(descriptor: .bubble(BubbleDescriptor(id: .init(rawValue: UInt64.max), position: [3, 5],
                velocity: [1, 0], targetRadius: 1, physicsMaterialID: .init(rawValue: 1), renderStyleID: .init(rawValue: 1))))
        ]
        let materials = try [PhysicsMaterialID(rawValue: 1): PhysicsMaterial(kind: .bubble)]
        let styles = try [RenderStyleID(rawValue: 1): RenderStyle()]
        let region = try WorldRectangle(min: [0, 0], max: [10, 10])
        var frame = try await world.step(objects: objects, materials: materials, styles: styles, region: region, duration: 0.25)
        frame = try await world.step(objects: Array(frame.objects.values), materials: materials, styles: styles, region: region, duration: 0.25)
        XCTAssertEqual(Set(frame.objects.keys), [.init(rawValue: UInt64.max)])
        frame = try await world.step(objects: Array(frame.objects.values), materials: materials, styles: styles, region: region, duration: 0.25)
        XCTAssertEqual(try XCTUnwrap(frame.objects[.init(rawValue: UInt64.max)]).position.x, 3.75, accuracy: 0.0001)
        XCTAssertEqual(frame.profile.bubbleUploadCount, 0)
    }

    func testStaticBubbleCannotBeMovedByStaticPolygonContainmentGuard() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let objects = try [
            NativePublicObject(descriptor: .bubble(BubbleDescriptor(id: .init(rawValue: 1), position: .zero,
                velocity: [8, 0], targetRadius: 1, motionRole: .static,
                physicsMaterialID: .init(rawValue: 1), renderStyleID: .init(rawValue: 1)))),
            NativePublicObject(descriptor: .polygon(PolygonDescriptor(id: .init(rawValue: 2),
                vertices: [[-2, -2], [2, -2], [2, 2], [-2, 2]],
                physicsMaterialID: .init(rawValue: 2), renderStyleID: .init(rawValue: 1)))),
            NativePublicObject(descriptor: .bubble(BubbleDescriptor(id: .init(rawValue: 3), position: .zero,
                targetRadius: 0.5, motionRole: .static, physicsMaterialID: .init(rawValue: 1), renderStyleID: .init(rawValue: 1))))
        ]
        let frame = try await world.step(objects: objects,
            materials: [.init(rawValue: 1): PhysicsMaterial(kind: .bubble), .init(rawValue: 2): PhysicsMaterial(kind: .polygon)],
            styles: [.init(rawValue: 1): RenderStyle()], region: WorldRectangle(min: [-10, -10], max: [10, 10]), duration: 0.25)
        XCTAssertEqual(frame.objects[.init(rawValue: 1)]?.position, .zero)
        XCTAssertEqual(frame.objects[.init(rawValue: 1)]?.velocity, .zero)
    }

    func testMaterialUpdateAffectsEveryReferencingObjectOnNextCompleteFrame() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let material = PhysicsMaterialID(rawValue: UInt64.max)
        let style = RenderStyleID(rawValue: 1)
        let objects = try [UInt64(1), UInt64.max].enumerated().map { index, id in
            NativePublicObject(descriptor: .bubble(try BubbleDescriptor(id: .init(rawValue: id),
                position: [Float(index) * 10, 0], velocity: [4, 0], targetRadius: 1,
                physicsMaterialID: material, renderStyleID: style)))
        }
        let region = try WorldRectangle(min: [-100, -100], max: [100, 100])
        let first = try await world.step(objects: objects, materials: [material: PhysicsMaterial(kind: .bubble)],
            styles: [style: RenderStyle()], region: region, duration: 0.25)
        XCTAssertEqual(Set(first.objects.keys), Set(objects.map { $0.descriptor.id }))
        let changed = try await world.step(objects: Array(first.objects.values),
            materials: [material: PhysicsMaterial(kind: .bubble, damping: 4)],
            styles: [style: RenderStyle()], region: region, duration: 0.25)
        for object in changed.objects.values { XCTAssertEqual(object.velocity.x, 1.4715178, accuracy: 0.0001) }
        XCTAssertEqual(try XCTUnwrap(changed.objects[.init(rawValue: 1)]).position.x, 1.3678794, accuracy: 0.0001)
        let third = try await world.step(objects: Array(changed.objects.values),
            materials: [material: PhysicsMaterial(kind: .bubble, damping: 4)],
            styles: [style: RenderStyle()], region: region, duration: 0.25)
        XCTAssertEqual(third.profile.bubbleUploadCount, 0)
        XCTAssertEqual(third.profile.commandBufferCount, 1)
    }

    func testStaticPolygonBlocksBubbleAndStyleUpdateDoesNotRebuildGeometry() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let style = RenderStyleID(rawValue: 1)
        let materials = try [PhysicsMaterialID(rawValue: 1): PhysicsMaterial(kind: .bubble),
                            PhysicsMaterialID(rawValue: 2): PhysicsMaterial(kind: .polygon)]
        let objects = try [
            NativePublicObject(descriptor: .bubble(BubbleDescriptor(id: .init(rawValue: 10),
                position: [-1.5, 0], velocity: [4, 0], targetRadius: 1,
                physicsMaterialID: .init(rawValue: 1), renderStyleID: style))),
            NativePublicObject(descriptor: .polygon(PolygonDescriptor(id: .init(rawValue: UInt64.max),
                vertices: [[0, -5], [2, -5], [2, 5], [0, 5]],
                physicsMaterialID: .init(rawValue: 2), renderStyleID: style,
                presentation: PresentationParameters(channels: [.init(rawValue: "saturation"): 0.8]))))
        ]
        let region = try WorldRectangle(min: [-20, -20], max: [20, 20])
        let first = try await world.step(objects: objects, materials: materials,
            styles: [style: RenderStyle()], region: region, duration: 0.25)
        XCTAssertLessThanOrEqual(try XCTUnwrap(first.objects[.init(rawValue: 10)]).position.x, -0.99)
        let second = try await world.step(objects: Array(first.objects.values), materials: materials,
            styles: [style: RenderStyle(channels: [.init(rawValue: "saturation"): 0.5])],
            region: region, duration: 0.25)
        XCTAssertEqual(second.profile.segmentUploadCount, 0)
        XCTAssertEqual(second.objects[.init(rawValue: UInt64.max)]?.position, .zero)
        XCTAssertEqual(second.presentation[.init(rawValue: 10)]?[.init(rawValue: "saturation")], 0.5)
        XCTAssertEqual(second.presentation[.init(rawValue: UInt64.max)]?[.init(rawValue: "saturation")], 0.8)
    }
}
