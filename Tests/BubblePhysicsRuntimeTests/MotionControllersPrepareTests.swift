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

    /// Przejście parametru materiału odtwarza materiał, więc musi zachować podatność kontaktu i ζ_c (G4-AC1, G4-AC2).
    func testMaterialParameterTransitionKeepsContactComplianceAndDampingRatio() throws {
        let materialID = PhysicsMaterialID(rawValue: 7)
        let compliance = BubbleContactCompliance(base: 0.174, referenceRadius: 20)
        let material = try PhysicsMaterial(kind: .bubble, damping: 0.1, contactCompliance: compliance, contactDampingRatio: 0.2)
        let transaction = WorldTransaction()
            .updatePhysicsMaterial(materialID, material: material)
            .startTransition(ParameterTransition(target: .physicsMaterial(materialID, .damping), value: .scalar(0.5), duration: 1))
        var prepared = try TransactionStager.stage(transaction, against: RuntimeState(configuration: try WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-1000, -1000], max: [1000, 1000])))).state
        try MotionControllers.prepare(&prepared, duration: duration)
        let transitioned = try XCTUnwrap(prepared.physicsMaterials[materialID])
        XCTAssertNotEqual(transitioned.damping, material.damping, "przejście ruszyło tłumienie")
        XCTAssertEqual(transitioned.contactDampingRatio, 0.2)
        XCTAssertEqual(transitioned.contactCompliance, compliance)
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

    // MARK: gałąź siłowa .playerDriven (P-B-9, P-B-10)

    private let bubbleMaterial = PhysicsMaterialID(rawValue: 1)
    private let driven = ObjectID(rawValue: 1)

    /// Bańka m = 2 w (0, 0) z prędkością `velocity` chwycona gumką/napędem prędkościowym, plus ewentualne pola i siła globalna.
    private func drivenState(policy: BubbleDrivePolicy, target: WorldPoint, velocity: WorldPoint = .zero, globalForce: WorldPoint = .zero,
                             fields: [ForceFieldDescriptor] = []) throws -> RuntimeState {
        var transaction = WorldTransaction()
            .updatePhysicsMaterial(bubbleMaterial, material: try PhysicsMaterial(kind: .bubble))
            .updateRenderMaterial(RenderMaterialID(rawValue: 1), material: try RenderMaterial())
            .add(.bubble(try BubbleDescriptor(id: driven, position: .zero, velocity: velocity, targetRadius: 1, mass: 2,
                physicsMaterialID: bubbleMaterial, renderMaterialID: RenderMaterialID(rawValue: 1), drivePolicy: policy)))
        for field in fields { transaction = transaction.add(.forceField(field)) }
        transaction = transaction.beginPlayerDrive(driven, target: target)
        let state = RuntimeState(configuration: try WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-1000, -1000], max: [1000, 1000]), globalForce: globalForce))
        return try TransactionStager.stage(transaction, against: state).state
    }

    private func preparedVelocity(_ state: RuntimeState) throws -> WorldPoint {
        var prepared = state
        try MotionControllers.prepare(&prepared, duration: duration)
        return try XCTUnwrap(prepared.objects[driven]).velocity
    }

    private func assertEqual(_ a: WorldPoint, _ b: WorldPoint, accuracy: Float = 1e-4, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, message, file: file, line: line)
    }

    /// Przyrost prędkości to F / m · dt z F = K · (cel − położenie), bez tłumienia i bez limitu.
    func testBandForceAddsForceOverMassTimesDtToTheVelocity() throws {
        let policy = try BubbleDrivePolicy(bandStiffness: 100)
        // Naciągnięcie (3, 4): F = (300, 400), m = 2.
        let velocity = try preparedVelocity(drivenState(policy: policy, target: [3, 4], velocity: [1, -2]))
        assertEqual(velocity, WorldPoint(1 + 300 / 2 / 60, -2 + 400 / 2 / 60))
    }

    func testBandForceIsClampedToMaximumForceKeepingTheDirection() throws {
        let policy = try BubbleDrivePolicy(bandStiffness: 100, maximumForce: 250)
        // |F| = 500 → obcięte do 250 w kierunku (0,6; 0,8): F = (150, 200).
        let velocity = try preparedVelocity(drivenState(policy: policy, target: [3, 4]))
        assertEqual(velocity, WorldPoint(150 / 2 / 60, 200 / 2 / 60))
        // Poniżej limitu siła nie jest obcinana: naciągnięcie (1, 0) → F = 100.
        let below = try preparedVelocity(drivenState(policy: policy, target: [1, 0]))
        assertEqual(below, WorldPoint(100 / 2 / 60, 0))
    }

    /// Tłumienie gumki to −D · v całkowane wykładniczo: v ← (v + F/m · dt) · e^(−D · dt / m).
    func testBandDampingDecaysTheVelocityExponentiallyAfterTheForceIncrement() throws {
        let policy = try BubbleDrivePolicy(bandStiffness: 100, bandDamping: 6)
        let velocity = try preparedVelocity(drivenState(policy: policy, target: [3, 4], velocity: [1, -2]))
        let decay = Float(exp(-6.0 / 60 / 2))
        assertEqual(velocity, WorldPoint((1 + 300 / 2 / 60) * decay, (-2 + 400 / 2 / 60) * decay))
    }

    /// CD-D-10 (P-B-9): siła globalna i pole kierunkowe dodają się do siły gumki jak w `.dynamic`; pole z filtrem na inny ID nie działa.
    func testBandForceAddsGlobalForceAndFieldsLikeADynamicBubble() throws {
        let policy = try BubbleDrivePolicy(bandStiffness: 100)
        let own = try ForceFieldDescriptor(id: ObjectID(rawValue: 10), position: .zero,
            geometry: RangeGeometry(shape: .circle(radius: 100)), field: .directional(force: [0, 40]),
            filter: ObjectFilter(objectIDs: [driven]))
        let foreign = try ForceFieldDescriptor(id: ObjectID(rawValue: 11), position: .zero,
            geometry: RangeGeometry(shape: .circle(radius: 100)), field: .directional(force: [999, 999]),
            filter: ObjectFilter(objectIDs: [ObjectID(rawValue: 77)]))
        let state = try drivenState(policy: policy, target: [3, 4], globalForce: [20, -10], fields: [own, foreign])
        let velocity = try preparedVelocity(state)
        // F = (300, 400) + (20, −10) + (0, 40) = (320, 430).
        assertEqual(velocity, WorldPoint(320 / 2 / 60, 430 / 2 / 60))
    }

    /// Siła globalna wchodzi do `maximumForce` dopiero po obcięciu samej gumki: limit dotyczy gumki, nie sumy sił.
    func testMaximumForceLimitsOnlyTheBandNotTheGlobalForce() throws {
        let policy = try BubbleDrivePolicy(bandStiffness: 100, maximumForce: 250)
        let velocity = try preparedVelocity(drivenState(policy: policy, target: [3, 4], globalForce: [0, -50]))
        assertEqual(velocity, WorldPoint(150 / 2 / 60, (200 - 50) / 2 / 60))
    }

    /// P-B-10 (G5-AC1): bez `bandStiffness` napęd zostaje prędkościowy: prędkość narzucona, siła globalna ignorowana.
    func testPolicyWithoutBandKeepsTheV220VelocityDrive() throws {
        let policy = try BubbleDrivePolicy(maximumSpeed: 12)
        let velocity = try preparedVelocity(drivenState(policy: policy, target: [3, 4], velocity: [1, -2], globalForce: [20, -10]))
        assertEqual(velocity, WorldPoint(12 * 0.6, 12 * 0.8))
        // Odległość 5 · odpowiedź 1 = prędkość 5 w kierunku (0,6; 0,8).
        let response = try BubbleDrivePolicy(maximumSpeed: 12, distanceResponse: 1)
        assertEqual(try preparedVelocity(drivenState(policy: response, target: [3, 4])), WorldPoint(3, 4))
    }
}
