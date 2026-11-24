import BubblePhysics
@testable import BubblePhysicsRuntime
import XCTest

/// P-B-80 (etap 8): przygotowanie kroku zapisuje obiekty w miejscu, w kolejności słownika, ale wynik i błąd nie zależą
/// od tej kolejności.
final class MotionControllersPrepareTests: XCTestCase {
    private let duration = 1.0 / 60

    private func state(bodies count: Int) throws -> RuntimeState {
        let materialID = PhysicsMaterialID(rawValue: 2), styleID = RenderMaterialID(rawValue: 1)
        var transaction = WorldTransaction()
            .updatePhysicsMaterial(materialID, material: try PhysicsMaterial(kind: .rigid))
            .updateRenderMaterial(styleID, material: try RenderMaterial())
        for index in 1...count {
            transaction = transaction.add(.rigidBody(try RigidBodyDescriptor(id: ObjectID(rawValue: UInt64(index)),
                vertices: [[0, 0], [2, 0], [2, 2], [0, 2]], position: [Float(index) * 5, 0], motionRole: .dynamic,
                physicsMaterialID: materialID, renderMaterialID: styleID)))
        }
        let state = RuntimeState(configuration: try WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-1000, -1000], max: [1000, 1000]), globalForce: [0, -10]))
        return try TransactionStager.stage(transaction, against: state).state
    }

    func testEveryDynamicObjectGetsTheGlobalForceImpulse() throws {
        var prepared = try state(bodies: 40)
        let before = prepared
        try MotionControllers.prepare(&prepared, duration: duration)
        for (id, object) in before.objects {
            guard let mass = object.mass else { continue }
            let expected = object.velocity + WorldPoint(0, -10) / mass * Float(duration)
            XCTAssertEqual(prepared.objects[id]?.velocity, expected, "obiekt \(id.rawValue)")
        }
    }

    /// Przejście parametru materiału odtwarza materiał, więc musi zachować sztywność kontaktu K_c (G1-AC1).
    func testMaterialParameterTransitionKeepsContactStiffness() throws {
        let materialID = PhysicsMaterialID(rawValue: 7)
        let material = try PhysicsMaterial(kind: .bubble, contactStiffness: 229, damping: 0.1)
        let transaction = WorldTransaction()
            .updatePhysicsMaterial(materialID, material: material)
            .startTransition(ParameterTransition(target: .physicsMaterial(materialID, .damping), value: .scalar(0.5), duration: 1))
        var prepared = try TransactionStager.stage(transaction, against: RuntimeState(configuration: try WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-1000, -1000], max: [1000, 1000])))).state
        try MotionControllers.prepare(&prepared, duration: duration)
        let transitioned = try XCTUnwrap(prepared.physicsMaterials[materialID])
        XCTAssertNotEqual(transitioned.damping, material.damping, "przejście ruszyło tłumienie")
        XCTAssertEqual(transitioned.contactStiffness, 229)
    }

    /// Deterministyczny generator (xorshift), by zestawy identyfikatorów były powtarzalne między uruchomieniami.
    private struct Sequence64 {
        var value: UInt64
        mutating func next(below bound: Int) -> Int {
            value ^= value << 13; value ^= value >> 7; value ^= value << 17
            return Int(value % UInt64(bound))
        }
    }

    func testTheErrorComesFromTheObjectWithTheSmallestIDRegardlessOfDictionaryOrder() throws {
        var random = Sequence64(value: 0x9E37_79B9_7F4A_7C15)
        // Rozmiary słownika i położenia uszkodzonych identyfikatorów zmieniają kolejność iteracji między przypadkami.
        for trial in 0..<48 {
            let size = 2 + random.next(below: 79)
            let first = 1 + random.next(below: size), second = 1 + random.next(below: size)
            guard first != second else { continue }
            let small = min(first, second), large = max(first, second)
            // Przy naprzemiennych rodzajach uszkodzenia błąd wskazuje, który obiekt został zgłoszony.
            let smallBreaksVelocity = trial.isMultiple(of: 2)
            var prepared = try state(bodies: size)
            if smallBreaksVelocity {
                prepared.objects[ObjectID(rawValue: UInt64(small))]?.velocity = [.nan, 0]
                prepared.objects[ObjectID(rawValue: UInt64(large))]?.angularVelocity = .infinity
            } else {
                prepared.objects[ObjectID(rawValue: UInt64(small))]?.angularVelocity = .infinity
                prepared.objects[ObjectID(rawValue: UInt64(large))]?.velocity = [.nan, 0]
            }
            let expected = ModelValidationError.nonFiniteValue(smallBreaksVelocity ? "motion.velocity" : "motion.angularVelocity")
            XCTAssertThrowsError(try MotionControllers.prepare(&prepared, duration: duration),
                                 "rozmiar \(size), uszkodzone \(small) i \(large)") { error in
                XCTAssertEqual(error as? ModelValidationError, expected, "rozmiar \(size), uszkodzone \(small) i \(large)")
            }
        }
    }

    // MARK: bańki: host nie liczy sił (CD-D-5)

    private let bubbleMaterial = PhysicsMaterialID(rawValue: 1)
    private let render = RenderMaterialID(rawValue: 1)

    private func assertEqual(_ a: WorldPoint, _ b: WorldPoint, accuracy: Float = 1e-4, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, message, file: file, line: line)
    }

    /// Bańki w czterech rolach z tą samą prędkością startową, γ > 0, siłą globalną, polem, gumką i motorem. Host zostawia prędkość ról
    /// siłowych bez zmian (siły liczy GPU w każdym podkroku), zeruje `.static`, a `.pathDriven` dostaje prędkość z toru (G4-AC6).
    func testHostLeavesForceDrivenBubbleVelocityAloneZeroesStaticAndTakesPathDrivenFromThePath() throws {
        let start: WorldPoint = [30, -20], policy = try BubbleDrivePolicy(bandStiffness: 100)
        let ids = (dynamic: ObjectID(rawValue: 11), motor: ObjectID(rawValue: 12), player: ObjectID(rawValue: 13),
                   path: ObjectID(rawValue: 14), still: ObjectID(rawValue: 15))
        func bubble(_ id: ObjectID, at x: Float) throws -> WorldObject {
            .bubble(try BubbleDescriptor(id: id, position: [x, 0], velocity: start, targetRadius: 1, mass: 2,
                physicsMaterialID: bubbleMaterial, renderMaterialID: render, drivePolicy: policy))
        }
        let transaction = WorldTransaction()
            .updatePhysicsMaterial(bubbleMaterial, material: try PhysicsMaterial(kind: .bubble, contactStiffness: 229, damping: 0.6))
            .updateRenderMaterial(render, material: try RenderMaterial())
            .add(try bubble(ids.dynamic, at: 0)).add(try bubble(ids.motor, at: 50)).add(try bubble(ids.player, at: 100))
            .add(try bubble(ids.path, at: 150)).add(try bubble(ids.still, at: 200))
            .add(.forceField(try ForceFieldDescriptor(id: ObjectID(rawValue: 90), position: .zero,
                geometry: RangeGeometry(shape: .circle(radius: 1000)), field: .directional(force: [0, 40]))))
            .setMotorDrive(ids.motor, drive: try MotorDrive(force: [5, 5], torque: 3))
            .beginPlayerDrive(ids.player, target: [103, 54])
            .setPathDrive(ids.path, drive: try PathDrive(points: [[150, 500]], speed: 5))
            .setMotion(ids.still, role: .static)
        var prepared = try TransactionStager.stage(transaction, against: RuntimeState(configuration: try WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-1000, -1000], max: [1000, 1000]), globalForce: [4, -10]))).state
        try MotionControllers.prepare(&prepared, duration: duration)
        for id in [ids.dynamic, ids.motor, ids.player] {
            let object = try XCTUnwrap(prepared.objects[id])
            assertEqual(object.velocity, start, "obiekt \(id.rawValue): bez tłumienia, siły globalnej, pola, gumki i motoru")
            XCTAssertEqual(object.angularVelocity, 0, "obiekt \(id.rawValue): motor nie obraca bańki na hoście")
        }
        assertEqual(try XCTUnwrap(prepared.objects[ids.path]).velocity, WorldPoint(0, 5), "pathDriven: prędkość z toru")
        assertEqual(try XCTUnwrap(prepared.objects[ids.still]).velocity, .zero, "static")
    }

    /// Promień kolizji bańki wyznacza przejście promienia raz na krok, jeszcze na hoście, przed broadphase.
    func testHostSetsBubbleCollisionRadiusFromTheTargetRadius() throws {
        let id = ObjectID(rawValue: 1)
        let transaction = WorldTransaction()
            .updatePhysicsMaterial(bubbleMaterial, material: try PhysicsMaterial(kind: .bubble, contactStiffness: 229))
            .updateRenderMaterial(render, material: try RenderMaterial())
            .add(.bubble(try BubbleDescriptor(id: id, position: .zero, targetRadius: 12, mass: 1,
                physicsMaterialID: bubbleMaterial, renderMaterialID: render)))
            .startTransition(ParameterTransition(target: .bubbleRadius(id), value: .scalar(24), duration: 2))
        var prepared = try TransactionStager.stage(transaction, against: RuntimeState(configuration: try WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-1000, -1000], max: [1000, 1000])))).state
        try MotionControllers.prepare(&prepared, duration: 1)
        let object = try XCTUnwrap(prepared.objects[id])
        XCTAssertEqual(object.targetRadius, 18, accuracy: 1e-4, "w połowie przejścia")
        XCTAssertEqual(object.collisionRadius, object.targetRadius)
    }

    /// Bryła kinematyczna dostaje prędkość z napędu (CD-D-9) i nie podlega sile globalnej.
    func testKinematicBodyVelocityComesFromItsDrive() throws {
        let body = ObjectID(rawValue: 1)
        let material = PhysicsMaterialID(rawValue: 2)
        let transaction = WorldTransaction()
            .updatePhysicsMaterial(material, material: try PhysicsMaterial(kind: .rigid))
            .updateRenderMaterial(render, material: try RenderMaterial())
            .add(.rigidBody(try RigidBodyDescriptor(id: body, vertices: [[0, 0], [2, 0], [2, 2], [0, 2]], motionRole: .kinematic,
                physicsMaterialID: material, renderMaterialID: render)))
            .setKinematicDrive(body, drive: .velocity(linear: [600, 0], angular: 1.5))
        var prepared = try TransactionStager.stage(transaction, against: RuntimeState(configuration: try WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-1000, -1000], max: [1000, 1000]), globalForce: [0, -10]))).state
        try MotionControllers.prepare(&prepared, duration: duration)
        let object = try XCTUnwrap(prepared.objects[body])
        assertEqual(object.velocity, [600, 0], accuracy: 1e-2, "prędkość z napędu, bez siły globalnej")
        XCTAssertEqual(object.angularVelocity, 1.5, accuracy: 1e-3)
    }
}
