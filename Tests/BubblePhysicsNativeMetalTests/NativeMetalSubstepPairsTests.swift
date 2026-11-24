import BubblePhysicsModel
import Metal
@testable import BubblePhysicsNativeMetal
import XCTest

/// Pary buforów poleceń pętli podkroków (wycinek 1, zadanie 8; CD-D-18): bufor podkroków i bufor końca kroku commitują się bez czekania
/// między sobą, pierwsza para ma 2 × podkroków poprzedniej klatki (najmniej 2), a każda kolejna para tej samej klatki 2 × więcej.
/// Render dostaje stan końca kroku, bo hak `beforeCommit` biegnie dopiero po buforze końca kroku (P-B-39).
@MainActor
final class NativeMetalSubstepPairsTests: XCTestCase {
    private let bubbleMaterial = PhysicsMaterialID(rawValue: 1)
    private let wallMaterial = PhysicsMaterialID(rawValue: 2)
    private let style = RenderMaterialID(rawValue: 1)
    private let wallX: Float = 360

    private func bubble(_ value: UInt64, at position: WorldPoint, velocity: WorldPoint = .zero) throws -> NativePublicObject {
        NativePublicObject(descriptor: .bubble(try BubbleDescriptor(id: ObjectID(rawValue: value), position: position, velocity: velocity,
            targetRadius: 24, mass: 1, physicsMaterialID: bubbleMaterial, renderMaterialID: style)))
    }

    private func wall() throws -> NativePublicObject {
        NativePublicObject(descriptor: .rigidBody(try RigidBodyDescriptor(id: ObjectID(rawValue: 2),
            vertices: [[-0.5, -2000], [0.5, -2000], [0.5, 2000], [-0.5, 2000]], position: [wallX, 0], mass: 1, momentOfInertia: 1,
            motionRole: .static, physicsMaterialID: wallMaterial, renderMaterialID: style)))
    }

    private func step(_ world: NativePublicWorld, _ objects: [NativePublicObject],
                      beforeCommit: ((NativeMetalRenderHandoff) throws -> Void)? = nil) async throws -> NativePublicFrame {
        try await world.step(objects: objects,
            materials: [bubbleMaterial: PhysicsMaterial(kind: .bubble, contactStiffness: 229), wallMaterial: PhysicsMaterial(kind: .rigid)],
            region: WorldRectangle(min: [-4000, -4000], max: [4000, 4000]), duration: 1.0 / 60, beforeCommit: beforeCommit)
    }

    /// Najmniejsza liczba par, których pojemność (2 × poprzednia klatka, najmniej 2, potem podwajanie) mieści `substeps` podkroków.
    private func expectedPairs(previous: Int, substeps: Int) -> Int {
        var size = max(2, 2 * previous), capacity = size, pairs = 1
        while capacity < substeps { size *= 2; capacity += size; pairs += 1 }
        return pairs
    }

    /// Podkroki ostatniego kroku z bufora sterowania na GPU.
    private func substeps(_ world: NativePublicWorld) -> Int {
        Int(world.persistentState?.substepControl.contents().load(as: NativeMetalSubstepControl.self).counts.y ?? 0)
    }

    // MARK: pary buforów

    /// Bańka w spoczynku liczy 1 podkrok, więc klatka ma jedną parę: bufor podkroków i bufor końca kroku.
    func testQuietFrameUsesOnePairOfCommandBuffers() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var frame = try await step(world, [bubble(1, at: [0, 0])])
        for _ in 0..<3 { frame = try await step(world, Array(frame.objects.values)) }
        XCTAssertEqual(frame.profile.commandBufferCount, 2)
        XCTAssertEqual(substeps(world), 1)
    }

    /// Uderzenie w ścianę z 1000 j/s: w klatkach z wieloma podkrokami liczba buforów to 2 × liczba par z podwajania, a liczba podkroków
    /// jest taka sama jak przy jednym buforze z limitem (podział na pary nie zmienia fizyki).
    func testImpactFrameEscalatesWithDoublingPairs() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var frame = try await step(world, [bubble(1, at: [wallX - 24 - 100, 0], velocity: [1000, 0]), wall()])
        var previous = substeps(world)
        var escalated = 0
        for index in 0..<30 {
            let objects = Array(frame.objects.values)
            frame = try await step(world, objects)
            let substeps = substeps(world)
            let pairs = expectedPairs(previous: previous, substeps: substeps)
            XCTAssertEqual(frame.profile.commandBufferCount, 2 * pairs,
                           "klatka \(index): \(substeps) podkroków po klatce z \(previous) powinno dać \(pairs) par")
            if pairs > 1 { escalated += 1 }
            previous = substeps
        }
        XCTAssertGreaterThan(escalated, 0, "uderzenie 10³ j/s ma przekroczyć pojemność pierwszej pary")
        XCTAssertLessThan(try XCTUnwrap(frame.objects[ObjectID(rawValue: 1)]).velocity.x, 0, "bańka ma się odbić")
    }

    // MARK: bramki końca kroku

    /// Zdarzenia (scalanie, sensor kołowy, sensor wielokątny) i zakończenie brył mają efekt uboczny, więc w klatce z wieloma parami
    /// buforów biegną tylko w ostatnim buforze końca kroku (bramki `nativePrepareEndGates`). Pierwsza klatka z uderzeniem 10³ j/s ma
    /// wiele par (para startowa ma 2 podkroki), a każde zdarzenie ma się pojawić dokładnie raz.
    func testEndOfStepEventsFireOnceInAFrameWithSeveralPairs() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let group = MergeGroupSet(rawValue: 1)
        func merging(_ value: UInt64, x: Float) throws -> NativePublicObject {
            NativePublicObject(descriptor: .bubble(try BubbleDescriptor(id: ObjectID(rawValue: value), position: [x, 500],
                targetRadius: 24, mass: 1, physicsMaterialID: bubbleMaterial, renderMaterialID: style,
                mergeGroups: group, eventInterest: .mergeContact)))
        }
        let circle = NativePublicObject(descriptor: .sensor(try SensorDescriptor(id: ObjectID(rawValue: 9),
            position: [wallX - 32, 0], geometry: RangeGeometry.circle(radius: 60), eventInterest: [.enteredSensor, .exitedSensor])))
        let polygon = NativePublicObject(descriptor: .sensor(try SensorDescriptor(id: ObjectID(rawValue: 10),
            position: [wallX, 0], geometry: RangeGeometry.polygon(vertices: [[-20, -20], [20, -20], [20, 20], [-20, 20]]),
            eventInterest: [.enteredSensor, .exitedSensor])))
        let objects = try [bubble(1, at: [wallX - 24 - 8, 0], velocity: [1000, 0]), wall(), merging(5, x: 0), merging(6, x: 30), circle, polygon]
        let frame = try await step(world, objects)
        XCTAssertGreaterThan(frame.profile.commandBufferCount, 2, "pierwsza klatka z uderzeniem ma mieć kilka par buforów")
        var entered: [String] = [], merged = 0
        for event in frame.events {
            switch event {
            case .enteredSensor(let sensor, let object): entered.append("\(sensor.rawValue)<-\(object.rawValue)")
            case .mergeContact: merged += 1
            default: XCTFail("nieoczekiwane zdarzenie \(event)")
            }
        }
        // Oba sensory obejmują bańkę 1 i ścianę 2 (sensor nie filtruje obiektów).
        XCTAssertEqual(entered.sorted(), ["10<-1", "10<-2", "9<-1", "9<-2"], "każde wejście do sensora dokładnie raz: \(frame.events)")
        XCTAssertEqual(merged, 1, "scalenie 5 i 6 dokładnie raz: \(frame.events)")
        XCTAssertEqual(frame.eventOverflow.droppedCount, 0)
    }

    // MARK: render po końcu kroku (P-B-39)

    /// Hak renderu dostaje uchwyt ze stanem końca kroku: w chwili wywołania kontury roboczego uchwytu są już policzone i równe
    /// konturom, które ten sam uchwyt (strona opublikowana) pokaże po kroku.
    func testRenderHookSeesTheContoursOfTheFinishedStep() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var frame = try await step(world, [bubble(1, at: [0, 0], velocity: [600, 0])])
        var seen: [ObjectID: [WorldPoint]] = [:]
        frame = try await step(world, Array(frame.objects.values)) { seen = $0.debugContourSnapshot() }
        let published = try XCTUnwrap(world.publishedRenderHandoff).debugContourSnapshot()
        XCTAssertFalse(seen.isEmpty)
        XCTAssertEqual(seen, published, "hak ma widzieć kontury po kroku, a nie sprzed kroku")
        _ = frame
    }

    /// Hak, który rzuca, odrzuca krok: nic się nie publikuje, a następny krok się udaje.
    func testThrowingRenderHookRejectsTheStepAndTheNextStepSucceeds() async throws {
        struct HookError: Error {}
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var frame = try await step(world, [bubble(1, at: [0, 0], velocity: [600, 0])])
        let published = try XCTUnwrap(world.publishedRenderHandoff)
        do {
            _ = try await step(world, Array(frame.objects.values)) { _ in throw HookError() }
            XCTFail("hak renderu odrzuca krok")
        } catch is HookError {}
        XCTAssertTrue(world.publishedRenderHandoff === published, "odrzucony krok nic nie publikuje")
        frame = try await step(world, Array(frame.objects.values))
        XCTAssertEqual(frame.objects.count, 1)
    }
}
