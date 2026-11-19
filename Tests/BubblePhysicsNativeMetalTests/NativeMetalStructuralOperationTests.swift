import BubblePhysicsModel
@testable import BubblePhysicsRuntime
@testable import BubblePhysicsNativeMetal
import Metal
import XCTest

@MainActor
final class NativeMetalStructuralOperationTests: XCTestCase {
    let material = PhysicsMaterialID(rawValue: 1), style = RenderMaterialID(rawValue: 1)
    func id(_ n: UInt64) -> ObjectID { .init(rawValue: n) }
    func result(_ n: UInt64) -> BubbleResult { .init(id: id(n), physicsMaterialID: material, renderMaterialID: style) }
    func initial(_ bubbles: [BubbleDescriptor]) throws -> RuntimeState {
        var tx = try WorldTransaction().updatePhysicsMaterial(material, material: PhysicsMaterial(kind: .bubble, deformability: 1))
            .updateRenderMaterial(style, material: try RenderMaterial())
        for b in bubbles { tx = tx.add(.bubble(b)) }
        return try TransactionStager.stage(tx, against: RuntimeState(configuration:
            WorldConfiguration(simulationRegion: WorldRectangle(min: [-100,-100], max: [100,100])))).state
    }
    func bubble(_ n: UInt64, x: Float = 0, radius: Float = 1, mass: Float = 1, vx: Float = 0) throws -> BubbleDescriptor {
        try .init(id: id(n), position: [x,0], velocity: [vx,0], targetRadius: radius,
            mass: mass, physicsMaterialID: material, renderMaterialID: style)
    }
    func step(_ stepper: NativeCompleteStepper, _ state: RuntimeState, _ tx: WorldTransaction) async throws -> RuntimeState {
        let batch = TransactionStager.stageBatch([.init(token: .init(rawValue: 1), transaction: tx)], against: state,
            validate: stepper.validate)
        XCTAssertTrue(batch.frame.events.isEmpty)
        return try await stepper.completePublishedStep(batch, duration: 1.0/60).state
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
        func polygon(_ n: UInt64, _ x: Float) throws -> RigidBodyDescriptor {
            try RigidBodyDescriptor(id: id(n), vertices: [[0,0],[1,0],[0,1]], position: [x,0],
                physicsMaterialID: polygonMaterial, renderMaterialID: style)
        }
        let one = try polygon(10, -5), two = try polygon(20, 5), replacement = try polygon(30, -4)
        let base = RuntimeState(configuration: try WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-100,-100], max: [100,100])))
        let state = try TransactionStager.stage(try WorldTransaction()
            .updatePhysicsMaterial(polygonMaterial, material: PhysicsMaterial(kind: .rigid))
            .updateRenderMaterial(style, material: try RenderMaterial())
            .add(.rigidBody(one)).add(.rigidBody(two)), against: base).state
        let invalid = WorldTransaction().replaceRigidBodies([one.id], with: [two])
        XCTAssertThrowsError(try TransactionStager.stage(invalid, against: state))
        XCTAssertEqual(Set(state.objects.keys), [one.id, two.id])
        let staged = try TransactionStager.stage(
            WorldTransaction().replaceRigidBodies([one.id], with: [replacement]), against: state)
        XCTAssertEqual(Set(staged.state.objects.keys), [two.id, replacement.id])
        XCTAssertEqual(staged.removedObjectIDs, [one.id])
        XCTAssertEqual(staged.createdObjectIDs, [replacement.id])
        let native = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let materials = [polygonMaterial: try PhysicsMaterial(kind: .rigid)]
        let region = try WorldRectangle(min: [-100,-100], max: [100,100])
        _ = try await native.step(objects: state.objects.values.map { NativePublicObject(descriptor: $0.descriptor) },
            materials: materials, region: region, duration: 1.0/60)
        let frame = try await native.step(objects: staged.state.objects.values.map { NativePublicObject(descriptor: $0.descriptor) },
            materials: materials, region: region, duration: 1.0/60)
        XCTAssertEqual(frame.profile.segmentUploadCount, 3)
    }

    func testMergeSeedsPreviousGPUDeformationWhenSourceWasCompressed() async throws {
        let left = try BubbleDescriptor(id: id(1), position: [-0.2,0], targetRadius: 1,
            motionRole: .static, physicsMaterialID: material, renderMaterialID: style)
        let right = try BubbleDescriptor(id: id(2), position: [0,0], targetRadius: 1,
            motionRole: .static, physicsMaterialID: material, renderMaterialID: style)
        var state = try initial([left, right])
        let wallMaterial = PhysicsMaterialID(rawValue: 2)
        let wall = try RigidBodyDescriptor(id: id(100), vertices: [[0.5,-4],[2,-4],[2,4],[0.5,4]],
            physicsMaterialID: wallMaterial, renderMaterialID: style)
        state = try TransactionStager.stage(WorldTransaction()
            .updatePhysicsMaterial(wallMaterial, material: PhysicsMaterial(kind: .rigid))
            .add(.rigidBody(wall)), against: state).state
        let native = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let first = try await native.step(objects: state.objects.values.map { NativePublicObject(descriptor: $0.descriptor) },
            materials: state.physicsMaterials, region: state.configuration.simulationRegion, duration: 1.0/60)
        XCTAssertLessThan(try XCTUnwrap(first.objects[id(2)]).effectiveRadius, 0.7)
        let merged = try TransactionStager.stage(WorldTransaction().mergeBubbles([id(1), id(2)],
            result: .init(id: id(3), physicsMaterialID: material, renderMaterialID: style, motionRole: .static)),
            against: state).state
        let object = try XCTUnwrap(merged.objects[id(3)])
        var input = NativePublicObject(descriptor: object.descriptor)
        input.position = object.position
        input.structuralShape = object.structuralShape
        let second = try await native.step(objects: [input], materials: merged.physicsMaterials,
            region: merged.configuration.simulationRegion, duration: 1.0/60)
        XCTAssertLessThan(try XCTUnwrap(second.objects[id(3)]).effectiveRadius, 0.7)
    }

    func testMergeContourDoesNotDependOnWhetherOutputReusesSourceID() async throws {
        func mergedRadius(_ outputID: UInt64) async throws -> Float {
            let left = try BubbleDescriptor(id: id(1), position: [-0.2,0], targetRadius: 1,
                motionRole: .static, physicsMaterialID: material, renderMaterialID: style)
            let right = try BubbleDescriptor(id: id(2), position: [0,0], targetRadius: 1,
                motionRole: .static, physicsMaterialID: material, renderMaterialID: style)
            var state = try initial([left, right])
            let wallMaterial = PhysicsMaterialID(rawValue: 2)
            let wall = try RigidBodyDescriptor(id: id(100), vertices: [[0.5,-4],[2,-4],[2,4],[0.5,4]],
                physicsMaterialID: wallMaterial, renderMaterialID: style)
            state = try TransactionStager.stage(WorldTransaction()
                .updatePhysicsMaterial(wallMaterial, material: PhysicsMaterial(kind: .rigid))
                .add(.rigidBody(wall)), against: state).state
            let native = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
            let first = try await native.step(objects: state.objects.values.map { NativePublicObject(descriptor: $0.descriptor) },
                materials: state.physicsMaterials, region: state.configuration.simulationRegion, duration: 1.0/60)
            XCTAssertLessThan(try XCTUnwrap(first.objects[id(2)]).effectiveRadius, 0.7)
            let merged = try TransactionStager.stage(WorldTransaction().mergeBubbles([id(1), id(2)],
                result: .init(id: id(outputID), physicsMaterialID: material, renderMaterialID: style, motionRole: .static)),
                against: state).state
            let object = try XCTUnwrap(merged.objects[id(outputID)])
            var input = NativePublicObject(descriptor: object.descriptor)
            input.position = object.position
            input.structuralShape = object.structuralShape
            let second = try await native.step(objects: [input], materials: merged.physicsMaterials,
                region: merged.configuration.simulationRegion, duration: 1.0/60)
            return try XCTUnwrap(second.objects[id(outputID)]).effectiveRadius
        }
        let fresh = try await mergedRadius(3)
        let reused = try await mergedRadius(2)
        XCTAssertEqual(reused, fresh, accuracy: 0.0001)
    }

    // P-B-13: wynik scalenia z ID źródła ma w pierwszym kroku ρ_prev = 1 na końcu pary, więc podział nakładania liczy c(1), a nie
    // c(ρ źródła). Materiał z kc = 3, żeby c zależało od ρ. Host unieważnia też rekordy cache ID strukturalnych
    // (`NativeMetalSolver`, invalidationRecords), więc rekord pary zwykle zaczyna od nowa, a partner też ma ρ_prev = 1;
    // oczekiwanie liczy c partnera z ρ rekordu z kroku pierwszego tylko wtedy, gdy rekord został dopasowany (wiek > 1).
    func testMergeResultWithSourceIDStartsItsPairEndAtRhoOne() async throws {
        let softMaterial = try PhysicsMaterial(kind: .bubble, deformability: 1,
            contactCompliance: BubbleContactCompliance(base: 0.002, referenceRadius: 1, radiusExponent: 0, compressionExponent: 3))
        func soft(_ n: UInt64, x: Float) throws -> BubbleDescriptor {
            try BubbleDescriptor(id: id(n), position: [x, 0], targetRadius: 1, physicsMaterialID: material, renderMaterialID: style)
        }
        let base = RuntimeState(configuration: try WorldConfiguration(simulationRegion: WorldRectangle(min: [-100, -100], max: [100, 100])))
        var tx = try WorldTransaction().updatePhysicsMaterial(material, material: softMaterial).updateRenderMaterial(style, material: try RenderMaterial())
        for bubble in [try soft(1, x: -1.5), try soft(2, x: 1), try soft(5, x: 1.5)] { tx = tx.add(.bubble(bubble)) }
        let state = try TransactionStager.stage(tx, against: base).state
        let native = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        _ = try await native.step(objects: state.objects.values.map { NativePublicObject(descriptor: $0.descriptor) },
            materials: state.physicsMaterials, region: state.configuration.simulationRegion, duration: 1.0 / 60)
        let before = try XCTUnwrap(native.cachedContacts.first { $0.metadata.x == 0 && $0.participants == SIMD2<Int64>(2, 5) })
        XCTAssertLessThan(before.rho.x, 0.9, "źródło niesie ściśnięty koniec, więc dziedziczenie ρ byłoby widoczne")
        XCTAssertLessThan(before.rho.y, 0.9)

        let merged = try TransactionStager.stage(WorldTransaction().mergeBubbles([id(1), id(2)],
            result: .init(id: id(2), physicsMaterialID: material, renderMaterialID: style)), against: state).state
        let object = try XCTUnwrap(merged.objects[id(2)])
        var input = NativePublicObject(descriptor: object.descriptor)
        input.position = object.position
        input.structuralShape = object.structuralShape
        let partner = NativePublicObject(descriptor: try XCTUnwrap(merged.objects[id(5)]).descriptor)
        _ = try await native.step(objects: [input, partner], materials: merged.physicsMaterials,
            region: merged.configuration.simulationRegion, duration: 1.0 / 60)
        let after = try XCTUnwrap(native.cachedContacts.first { $0.metadata.x == 0 && $0.participants == SIMD2<Int64>(2, 5) })

        let radius = object.targetRadius, otherRadius = partner.collisionRadius
        let overlap = radius + otherRadius - (partner.position - input.position).euclideanLength
        XCTAssertGreaterThan(overlap, 0.3)
        func compliance(_ rho: Float) -> Float { 0.002 * pow(max(rho, 0.01), 3) }
        let cSelf = compliance(1), cOther = compliance(after.metadata.y > 1 ? before.rho.y : 1)
        XCTAssertEqual(after.rho.x, (radius - overlap * cSelf / (cSelf + cOther)) / radius, accuracy: 1e-3)
        XCTAssertEqual(after.rho.y, (otherRadius - overlap * cOther / (cSelf + cOther)) / otherRadius, accuracy: 1e-3)
    }

    // P-B-16: kontur wyniku scalenia pochodzi z seeda źródeł tylko w pierwszej klatce; w drugiej, bez żadnego kontaktu,
    // jest już kołem o promieniu docelowym (bez relaksacji w czasie).
    func testMergeContourComesFromTheSeedOnlyInTheFirstFrame() async throws {
        let left = try BubbleDescriptor(id: id(1), position: [-0.2, 0], targetRadius: 1,
            motionRole: .static, physicsMaterialID: material, renderMaterialID: style)
        let right = try BubbleDescriptor(id: id(2), position: [0, 0], targetRadius: 1,
            motionRole: .static, physicsMaterialID: material, renderMaterialID: style)
        var state = try initial([left, right])
        let wallMaterial = PhysicsMaterialID(rawValue: 2)
        let wall = try RigidBodyDescriptor(id: id(100), vertices: [[0.5, -4], [2, -4], [2, 4], [0.5, 4]],
            physicsMaterialID: wallMaterial, renderMaterialID: style)
        state = try TransactionStager.stage(WorldTransaction()
            .updatePhysicsMaterial(wallMaterial, material: PhysicsMaterial(kind: .rigid))
            .add(.rigidBody(wall)), against: state).state
        let native = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        _ = try await native.step(objects: state.objects.values.map { NativePublicObject(descriptor: $0.descriptor) },
            materials: state.physicsMaterials, region: state.configuration.simulationRegion, duration: 1.0 / 60)
        let merged = try TransactionStager.stage(WorldTransaction().mergeBubbles([id(1), id(2)],
            result: .init(id: id(3), physicsMaterialID: material, renderMaterialID: style, motionRole: .static)),
            against: state).state
        let object = try XCTUnwrap(merged.objects[id(3)])
        var input = NativePublicObject(descriptor: object.descriptor)
        input.position = object.position
        input.structuralShape = object.structuralShape
        let first = try await native.step(objects: [input], materials: merged.physicsMaterials,
            region: merged.configuration.simulationRegion, duration: 1.0 / 60)
        XCTAssertLessThan(try XCTUnwrap(first.objects[id(3)]).effectiveRadius, 0.7, "pierwsza klatka: kontur z seeda")
        // Kształt strukturalny dostaje tylko krok, w którym operacja jest wykonana; kolejny krok go nie niesie.
        input.structuralShape = nil
        let second = try await native.step(objects: [input], materials: merged.physicsMaterials,
            region: merged.configuration.simulationRegion, duration: 1.0 / 60)
        XCTAssertEqual(try XCTUnwrap(second.objects[id(3)]).effectiveRadius, object.targetRadius, accuracy: 0.001,
            "druga klatka bez kontaktów: kontur kołowy, bez pamięci seeda")
    }
}
