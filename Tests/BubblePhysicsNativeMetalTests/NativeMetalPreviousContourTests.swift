import BubblePhysicsModel
import Metal
@testable import BubblePhysicsNativeMetal
import XCTest

/// Sonda faktu z R2 (zadanie 51): solver trzyma kontury w dwóch buforach ping-pong, więc po publikacji strona t−1 jest
/// nietknięta do następnego kroku, bez żadnej kopii. Dwa wyjątki: krok wykonany na GPU bez publikacji nadpisuje ją,
/// a ponowne przydzielenie stanu przy wzroście pojemności musi ją skopiować (zadanie 59).
/// Wykonuje bufor naprawdę, a potem zgłasza błąd wykonania: GPU zapisało wszystkie kontury, ale krok nie zostanie opublikowany.
@MainActor
private final class FailingAfterRunExecutor: NativeMetalCommandExecuting {
    var failNext = false
    func complete(_ command: MTLCommandBuffer) async throws -> NativeMetalCommandTiming {
        let timing = try await NativeMetalCommandExecutor().complete(command)
        if failNext { failNext = false; throw NativeMetalSolverError.commandFailed("wstrzyknięty błąd po wykonaniu") }
        return timing
    }
}

@MainActor
final class NativeMetalPreviousContourTests: XCTestCase {
    private let bubbleMaterial = PhysicsMaterialID(rawValue: 1)
    private let rigidMaterial = PhysicsMaterialID(rawValue: 2)
    private let style = RenderMaterialID(rawValue: 1)
    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }

    /// Bańka z prędkością 6/s, więc jej kontur zmienia się z kroku na krok.
    private func moving(_ value: UInt64, at position: WorldPoint) throws -> NativePublicObject {
        NativePublicObject(descriptor: .bubble(try BubbleDescriptor(id: id(value), position: position, velocity: [6, 0],
            targetRadius: 1, physicsMaterialID: bubbleMaterial, renderMaterialID: style)))
    }

    private func step(_ world: NativePublicWorld, _ objects: [NativePublicObject],
                      beforeCommit: ((NativeMetalRenderHandoff) throws -> Void)? = nil) async throws -> NativePublicFrame {
        try await world.step(objects: objects,
            materials: [bubbleMaterial: PhysicsMaterial(kind: .bubble), rigidMaterial: PhysicsMaterial(kind: .rigid)],
            region: WorldRectangle(min: [-100, -100], max: [100, 100]), duration: 1.0 / 60, beforeCommit: beforeCommit)
    }

    /// Następny krok z obiektami z poprzedniej klatki, jak robi to stepper.
    private func next(_ world: NativePublicWorld, _ frame: NativePublicFrame,
                      beforeCommit: ((NativeMetalRenderHandoff) throws -> Void)? = nil) async throws -> NativePublicFrame {
        try await step(world, Array(frame.objects.values), beforeCommit: beforeCommit)
    }

    func testPreviousSideOfAPublishedStepHoldsTheContoursOfThePreviousPublication() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var frame = try await step(world, [moving(1, at: [0, 0])])
        let first = try XCTUnwrap(world.publishedRenderHandoff)
        XCTAssertFalse(first.previousContoursValid, "po pierwszej publikacji nie ma jeszcze kroku t−1")
        XCTAssertEqual(first.debugPreviousContourSnapshot().count, 0)
        let firstContours = first.debugContourSnapshot()
        XCTAssertGreaterThanOrEqual(firstContours[id(1)]?.count ?? 0, 32)

        frame = try await next(world, frame)
        let second = try XCTUnwrap(world.publishedRenderHandoff)
        XCTAssertTrue(second.previousContoursValid)
        XCTAssertEqual(second.previousBubbleIDs, [id(1)])
        XCTAssertEqual(second.debugPreviousContourSnapshot(), firstContours, "t−1 to kontury poprzedniej publikacji")
        XCTAssertNotEqual(second.debugContourSnapshot(), firstContours, "bańka się poruszyła, więc t różni się od t−1")
        XCTAssertEqual(first.debugContourSnapshot(), firstContours,
                       "strona t opublikowana przed krokiem jest nietknięta po kroku t+1")
        _ = frame
    }

    func testPreviousSideIsStillIntactInTheFrameBetweenSteps() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var frame = try await step(world, [moving(1, at: [0, 0])])
        let firstContours = try XCTUnwrap(world.publishedRenderHandoff).debugContourSnapshot()
        frame = try await next(world, frame)
        let handoff = try XCTUnwrap(world.publishedRenderHandoff)
        let current = handoff.debugContourSnapshot()
        // Klatka pośrednia nic nie wykonuje na GPU: obie strony zostają, ten sam uchwyt, te same dane.
        XCTAssertTrue(world.publishedRenderHandoff === handoff)
        XCTAssertEqual(handoff.debugPreviousContourSnapshot(), firstContours)
        XCTAssertEqual(handoff.debugContourSnapshot(), current)
        _ = frame
    }

    func testStepInProgressSeesTheLastPublicationAsItsPreviousSide() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var frame = try await step(world, [moving(1, at: [0, 0])])
        let published = try XCTUnwrap(world.publishedRenderHandoff).debugContourSnapshot()
        var seen: [ObjectID: [WorldPoint]] = [:]
        var seenValid = false
        frame = try await next(world, frame) { handoff in
            seen = handoff.debugPreviousContourSnapshot(); seenValid = handoff.previousContoursValid
        }
        XCTAssertTrue(seenValid)
        XCTAssertEqual(seen, published, "w handoffie kroku w toku t−1 to ostatnia publikacja")
        _ = frame
    }

    /// Wymuszony `guardFailure` na GPU: cienki pręt z ogromną prędkością kątową w bańce, jak w
    /// `NativeMetalRigidPolygonTests.testFailedGeometryChangeCannotCorruptPublishedCollisionShape`.
    private func guardFailureStep(_ world: NativePublicWorld, _ frame: NativePublicFrame) async throws {
        let rod = NativePublicObject(descriptor: .rigidBody(try RigidBodyDescriptor(id: id(99),
            vertices: [[-0.1, -2], [0.1, -2], [0.1, 2], [-0.1, 2]], position: [10, 10], angularVelocity: 1000,
            mass: 2, momentOfInertia: 2, motionRole: .dynamic, physicsMaterialID: rigidMaterial, renderMaterialID: style)))
        let victim = try moving(2, at: [10, 11.5])
        do {
            _ = try await step(world, Array(frame.objects.values) + [rod, victim])
            XCTFail("krok z prętem o prędkości kątowej 1000 musi zostać odrzucony po wykonaniu na GPU")
        } catch let failure as NativeMetalSafetyFailure {
            XCTAssertEqual(failure.reason, .guardFailure)
        }
    }

    func testStepFailedAfterTheGPURanOverwritesThePreviousSideAndTheNextPublicationRestoresIt() async throws {
        let executor = FailingAfterRunExecutor()
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()), commandExecutor: executor)
        var frame = try await step(world, [moving(1, at: [0, 0])])
        let firstContours = try XCTUnwrap(world.publishedRenderHandoff).debugContourSnapshot()
        frame = try await next(world, frame)
        let published = try XCTUnwrap(world.publishedRenderHandoff)
        let publishedContours = published.debugContourSnapshot()
        XCTAssertTrue(published.previousContoursValid)
        XCTAssertEqual(published.debugPreviousContourSnapshot(), firstContours)

        executor.failNext = true
        do {
            _ = try await next(world, frame)
            XCTFail("błąd wykonania odrzuca krok")
        } catch NativeMetalSolverError.commandFailed {}
        XCTAssertTrue(world.publishedRenderHandoff === published, "odrzucony krok nic nie publikuje")
        XCTAssertEqual(published.debugContourSnapshot(), publishedContours, "strona t jest nietknięta")
        XCTAssertNotEqual(published.debugPreviousContourSnapshot(), firstContours, "strona t−1 jest nadpisana")
        XCTAssertFalse(published.previousContoursValid, "uchwyt wie, że jego strona t−1 jest nieważna")

        frame = try await next(world, frame)
        let recovered = try XCTUnwrap(world.publishedRenderHandoff)
        XCTAssertTrue(recovered.previousContoursValid)
        XCTAssertEqual(recovered.debugPreviousContourSnapshot()[id(1)], publishedContours[id(1)],
                       "w roli t−1 ląduje dawna strona opublikowana")
        _ = frame
    }

    /// Fakt z sondy: `guardFailure` z kroku XPBD zatrzymuje kernele konturów (`safety[3] != 0`), więc strona t−1 przeżywa.
    /// Flaga i tak gaśnie, bo inne błędy po wykonaniu (wartość poza zakresem po odczycie, błąd bufora) ją nadpisują.
    func testGuardFailureStopsTheContourKernelsButTheFlagStaysConservative() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var frame = try await step(world, [moving(1, at: [0, 0])])
        let firstContours = try XCTUnwrap(world.publishedRenderHandoff).debugContourSnapshot()
        frame = try await next(world, frame)
        let published = try XCTUnwrap(world.publishedRenderHandoff)
        try await guardFailureStep(world, frame)
        XCTAssertEqual(published.debugPreviousContourSnapshot(), firstContours)
        XCTAssertFalse(published.previousContoursValid)
        _ = frame
    }

    func testRejectedStepBeforeTheGPUKeepsThePreviousSide() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var frame = try await step(world, [moving(1, at: [0, 0])])
        let firstContours = try XCTUnwrap(world.publishedRenderHandoff).debugContourSnapshot()
        frame = try await next(world, frame)
        let published = try XCTUnwrap(world.publishedRenderHandoff)
        struct GameError: Error {}
        do {
            _ = try await next(world, frame) { _ in throw GameError() }
            XCTFail("rzucające domknięcie odrzuca krok")
        } catch is GameError {}
        XCTAssertTrue(published.previousContoursValid, "bufor nie został zatwierdzony, GPU nic nie zapisało")
        XCTAssertEqual(published.debugPreviousContourSnapshot(), firstContours)
        _ = frame
    }

    /// Czerwone do zadania 59: ponowne przydzielenie stanu przy wzroście pojemności kopiuje dziś bańki, liczniki i
    /// deformację, ale nie punkty konturów, więc w roli t−1 ląduje pusta strona.
    func testReallocationKeepsPreviousContours() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var frame = try await step(world, [moving(1, at: [0, 0])])
        let firstContours = try XCTUnwrap(world.publishedRenderHandoff).debugContourSnapshot()
        // Pojemność baniek ma minimum 16: 17 dodatkowych baniek przydziela stan od nowa na początku publikowanego kroku.
        var extra: [NativePublicObject] = []
        for index in 0..<17 { extra.append(try moving(UInt64(10 + index), at: WorldPoint(Float(-90 + 10 * index), 50))) }
        frame = try await step(world, Array(frame.objects.values) + extra)
        let handoff = try XCTUnwrap(world.publishedRenderHandoff)
        XCTAssertEqual(handoff.bubbleCount, 18)
        XCTAssertTrue(handoff.previousContoursValid)
        XCTAssertEqual(handoff.previousBubbleIDs, [id(1)], "kolejność baniek poprzedniej publikacji")
        XCTAssertEqual(handoff.debugPreviousContourSnapshot()[id(1)], firstContours[id(1)])
        _ = frame
    }

    /// Wzrost kroku konturu (duża bańka) zmienia `contourStride`: punkty muszą być przeliczone bańka po bańce.
    func testReallocationKeepsPreviousContoursWhenContourStrideGrows() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var frame = try await step(world, [moving(1, at: [0, 0])])
        let first = try XCTUnwrap(world.publishedRenderHandoff)
        let firstContours = first.debugContourSnapshot()
        let big = NativePublicObject(descriptor: .bubble(try BubbleDescriptor(id: id(2), position: [50, 0], targetRadius: 45,
            motionRole: .static, physicsMaterialID: bubbleMaterial, renderMaterialID: style)))
        frame = try await step(world, Array(frame.objects.values) + [big])
        let handoff = try XCTUnwrap(world.publishedRenderHandoff)
        XCTAssertGreaterThan(handoff.contourStride, first.contourStride, "stan przydzielony z większym krokiem konturu")
        XCTAssertEqual(handoff.debugPreviousContourSnapshot()[id(1)], firstContours[id(1)])
        _ = frame
    }
}
