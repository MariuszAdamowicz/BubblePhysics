import BubblePhysicsModel
@testable import BubblePhysicsRuntime
@testable import BubblePhysicsNativeMetal
import Metal
import XCTest

@MainActor
final class NativeMetalStructuralOperationTests: XCTestCase {
    let material = PhysicsMaterialID(rawValue: 1), style = RenderStyleID(rawValue: 1)
    func id(_ n: UInt64) -> ObjectID { .init(rawValue: n) }
    func result(_ n: UInt64) -> BubbleResult { .init(id: id(n), physicsMaterialID: material, renderStyleID: style) }
    func initial(_ bubbles: [BubbleDescriptor]) throws -> RuntimeState {
        var tx = try WorldTransaction().updatePhysicsMaterial(material, material: PhysicsMaterial(kind: .bubble, deformability: 1))
            .updateRenderStyle(style, style: RenderStyle())
        for b in bubbles { tx = tx.add(.bubble(b)) }
        return try TransactionStager.stage(tx, against: RuntimeState(configuration:
            WorldConfiguration(simulationRegion: WorldRectangle(min: [-100,-100], max: [100,100])))).state
    }
    func bubble(_ n: UInt64, x: Float = 0, radius: Float = 1, mass: Float = 1, vx: Float = 0) throws -> BubbleDescriptor {
        try .init(id: id(n), position: [x,0], velocity: [vx,0], targetRadius: radius,
            mass: mass, physicsMaterialID: material, renderStyleID: style)
    }
    func step(_ stepper: NativeCompleteStepper, _ state: RuntimeState, _ tx: WorldTransaction) async throws -> RuntimeState {
        let batch = TransactionStager.stageBatch([.init(token: .init(rawValue: 1), transaction: tx)], against: state,
            validate: stepper.validate)
        XCTAssertTrue(batch.frame.events.isEmpty)
        return try await stepper.completeStep(batch, duration: 1.0/60).state
    }

    // Utrata aktualnego promienia lub start dwóch pełnych kół w tym samym punkcie łamie ten kontrakt.
    func testBubbleSplitConservesConfiguredSizeSharesAndProducesSeparatedTransientShapes() async throws {
        var state = try initial([bubble(1, radius: 2, mass: 8, vx: 3)])
        state.objects[id(1)]?.targetRadius = 4
        state.objects[id(1)]?.collisionRadius = 4
        let tx = WorldTransaction().splitBubble(id(1), first: .init(result: result(2), share: 0.25),
            second: .init(result: result(3), share: 0.75))
        let staged = try TransactionStager.stage(tx, against: state).state
        let a = try XCTUnwrap(staged.objects[id(2)]), b = try XCTUnwrap(staged.objects[id(3)])
        XCTAssertEqual(a.targetRadius, 2, accuracy: 0.0001)
        XCTAssertEqual(b.targetRadius, sqrt(12), accuracy: 0.0001)
        XCTAssertGreaterThan(abs(a.position.x-b.position.x), 1)
        XCTAssertEqual(a.position.x * 2 + b.position.x * 6, 0, accuracy: 0.0001)
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let completed = try await step(stepper, state, tx)
        let first = try XCTUnwrap(completed.objects[id(2)]), second = try XCTUnwrap(completed.objects[id(3)])
        XCTAssertEqual(first.velocity.x * 2 + second.velocity.x * 6, 24, accuracy: 0.01)
        XCTAssertLessThan(first.effectiveRadius, first.targetRadius * 0.95)
        XCTAssertLessThan(second.effectiveRadius, second.targetRadius * 0.95)
    }

    func testBubbleSplitNearUnitShareHasFiniteGeometryAndRejectsUnrepresentableRemainder() throws {
        let state = try initial([bubble(1, radius: 2, mass: 8)])
        let nearUnit = WorldTransaction().splitBubble(id(1),
            first: .init(result: result(2), share: 0.999999),
            second: .init(result: result(3), share: 0.000001))
        let staged = try TransactionStager.stage(nearUnit, against: state).state
        for objectID in [id(2), id(3)] {
            let object = try XCTUnwrap(staged.objects[objectID])
            XCTAssertTrue(object.position.x.isFinite)
            XCTAssertTrue(object.position.y.isFinite)
            XCTAssertTrue(object.velocity.x.isFinite)
            XCTAssertTrue(object.velocity.y.isFinite)
            XCTAssertTrue(object.angularVelocity.isFinite)
            XCTAssertTrue(object.targetRadius.isFinite)
        }
        XCTAssertNotEqual(staged.objects[id(2)]?.position, staged.objects[id(3)]?.position)

        let roundedToOne = WorldTransaction().splitBubble(id(1),
            first: .init(result: result(2), share: 1),
            second: .init(result: result(3), share: Float.leastNonzeroMagnitude))
        XCTAssertThrowsError(try TransactionStager.stage(roundedToOne, against: state))
    }

    // Masa nierówna: środek masy nie jest rejonem styku; start nie może być zwykłym kołem.
    func testBubbleMergeCarriesMomentumAndStartsAtContactRegion() async throws {
        let state = try initial([bubble(1, x: -1, mass: 1, vx: 3), bubble(2, x: 1, mass: 3, vx: -1)])
        let tx = WorldTransaction().mergeBubbles([id(1),id(2)], result: result(3))
        let staged = try TransactionStager.stage(tx, against: state).state
        XCTAssertEqual(try XCTUnwrap(staged.objects[id(3)]).position.x, 0, accuracy: 0.0001)
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let completed = try await step(stepper, state, tx)
        let merged = try XCTUnwrap(completed.objects[id(3)])
        XCTAssertEqual(merged.mass, 4)
        XCTAssertEqual(merged.velocity.x, 0, accuracy: 0.001)
        XCTAssertLessThan(merged.effectiveRadius, 1.2)
    }

    func testPolygonReplacementIsAtomicAndRebuildsOnlyAffectedCollisionState() async throws {
        let polygonMaterial = PhysicsMaterialID(rawValue: 2)
        func polygon(_ n: UInt64, _ x: Float) throws -> PolygonDescriptor {
            try PolygonDescriptor(id: id(n), vertices: [[0,0],[1,0],[0,1]], position: [x,0],
                physicsMaterialID: polygonMaterial, renderStyleID: style)
        }
        let one = try polygon(10, -5), two = try polygon(20, 5), replacement = try polygon(30, -4)
        let base = RuntimeState(configuration: try WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-100,-100], max: [100,100])))
        let state = try TransactionStager.stage(try WorldTransaction()
            .updatePhysicsMaterial(polygonMaterial, material: PhysicsMaterial(kind: .polygon))
            .updateRenderStyle(style, style: RenderStyle())
            .add(.polygon(one)).add(.polygon(two)), against: base).state
        let invalid = WorldTransaction().replacePolygons([one.id], with: [two])
        XCTAssertThrowsError(try TransactionStager.stage(invalid, against: state))
        XCTAssertEqual(Set(state.objects.keys), [one.id, two.id])
        let staged = try TransactionStager.stage(
            WorldTransaction().replacePolygons([one.id], with: [replacement]), against: state)
        XCTAssertEqual(Set(staged.state.objects.keys), [two.id, replacement.id])
        XCTAssertEqual(staged.removedObjectIDs, [one.id])
        XCTAssertEqual(staged.createdObjectIDs, [replacement.id])
        let native = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let materials = [polygonMaterial: try PhysicsMaterial(kind: .polygon)]
        let styles = [style: try RenderStyle()]
        let region = try WorldRectangle(min: [-100,-100], max: [100,100])
        _ = try await native.step(objects: state.objects.values.map { NativePublicObject(descriptor: $0.descriptor) },
            materials: materials, styles: styles, region: region, duration: 1.0/60)
        let frame = try await native.step(objects: staged.state.objects.values.map { NativePublicObject(descriptor: $0.descriptor) },
            materials: materials, styles: styles, region: region, duration: 1.0/60)
        XCTAssertEqual(frame.profile.segmentUploadCount, 3)
    }

    func testLocalPresentationTransitionIsVisibleInNativeFrame() async throws {
        let channel = ParameterID(rawValue: "highlight")
        var state = try initial([bubble(1)])
        state = try TransactionStager.stage(WorldTransaction().startTransition(.init(
            target: .objectPresentation(id(1), channel), value: .scalar(1), duration: 1)), against: state).state
        try MotionControllers.prepare(&state, duration: 0.5)
        var input = NativePublicObject(descriptor: try XCTUnwrap(state.objects[id(1)]).descriptor)
        input.presentation = try XCTUnwrap(state.objects[id(1)]).presentation
        let native = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let frame = try await native.step(objects: [input], materials: state.physicsMaterials,
            styles: state.renderStyles, region: state.configuration.simulationRegion, duration: 1.0/60)
        XCTAssertEqual(frame.presentation[id(1)]?[channel], 0.5)
    }

    func testMergeSeedsPreviousGPUDeformationWhenSourceWasCompressed() async throws {
        let left = try BubbleDescriptor(id: id(1), position: [-0.2,0], targetRadius: 1,
            motionRole: .static, physicsMaterialID: material, renderStyleID: style)
        let right = try BubbleDescriptor(id: id(2), position: [0,0], targetRadius: 1,
            motionRole: .static, physicsMaterialID: material, renderStyleID: style)
        var state = try initial([left, right])
        let wallMaterial = PhysicsMaterialID(rawValue: 2)
        let wall = try PolygonDescriptor(id: id(100), vertices: [[0.5,-4],[2,-4],[2,4],[0.5,4]],
            physicsMaterialID: wallMaterial, renderStyleID: style)
        state = try TransactionStager.stage(WorldTransaction()
            .updatePhysicsMaterial(wallMaterial, material: PhysicsMaterial(kind: .polygon))
            .add(.polygon(wall)), against: state).state
        let native = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let first = try await native.step(objects: state.objects.values.map { NativePublicObject(descriptor: $0.descriptor) },
            materials: state.physicsMaterials, styles: state.renderStyles,
            region: state.configuration.simulationRegion, duration: 1.0/60)
        XCTAssertLessThan(try XCTUnwrap(first.objects[id(2)]).effectiveRadius, 0.7)
        let merged = try TransactionStager.stage(WorldTransaction().mergeBubbles([id(1), id(2)],
            result: .init(id: id(3), physicsMaterialID: material, renderStyleID: style, motionRole: .static)),
            against: state).state
        let object = try XCTUnwrap(merged.objects[id(3)])
        var input = NativePublicObject(descriptor: object.descriptor)
        input.position = object.position
        input.structuralShape = object.structuralShape
        let second = try await native.step(objects: [input], materials: merged.physicsMaterials,
            styles: merged.renderStyles, region: merged.configuration.simulationRegion, duration: 1.0/60)
        XCTAssertLessThan(try XCTUnwrap(second.objects[id(3)]).effectiveRadius, 0.7)
    }

    func testMergeContourDoesNotDependOnWhetherOutputReusesSourceID() async throws {
        func mergedRadius(_ outputID: UInt64) async throws -> Float {
            let left = try BubbleDescriptor(id: id(1), position: [-0.2,0], targetRadius: 1,
                motionRole: .static, physicsMaterialID: material, renderStyleID: style)
            let right = try BubbleDescriptor(id: id(2), position: [0,0], targetRadius: 1,
                motionRole: .static, physicsMaterialID: material, renderStyleID: style)
            var state = try initial([left, right])
            let wallMaterial = PhysicsMaterialID(rawValue: 2)
            let wall = try PolygonDescriptor(id: id(100), vertices: [[0.5,-4],[2,-4],[2,4],[0.5,4]],
                physicsMaterialID: wallMaterial, renderStyleID: style)
            state = try TransactionStager.stage(WorldTransaction()
                .updatePhysicsMaterial(wallMaterial, material: PhysicsMaterial(kind: .polygon))
                .add(.polygon(wall)), against: state).state
            let native = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
            let first = try await native.step(objects: state.objects.values.map { NativePublicObject(descriptor: $0.descriptor) },
                materials: state.physicsMaterials, styles: state.renderStyles,
                region: state.configuration.simulationRegion, duration: 1.0/60)
            XCTAssertLessThan(try XCTUnwrap(first.objects[id(2)]).effectiveRadius, 0.7)
            let merged = try TransactionStager.stage(WorldTransaction().mergeBubbles([id(1), id(2)],
                result: .init(id: id(outputID), physicsMaterialID: material, renderStyleID: style, motionRole: .static)),
                against: state).state
            let object = try XCTUnwrap(merged.objects[id(outputID)])
            var input = NativePublicObject(descriptor: object.descriptor)
            input.position = object.position
            input.structuralShape = object.structuralShape
            let second = try await native.step(objects: [input], materials: merged.physicsMaterials,
                styles: merged.renderStyles, region: merged.configuration.simulationRegion, duration: 1.0/60)
            return try XCTUnwrap(second.objects[id(outputID)]).effectiveRadius
        }
        let fresh = try await mergedRadius(3)
        let reused = try await mergedRadius(2)
        XCTAssertEqual(reused, fresh, accuracy: 0.0001)
    }
}
