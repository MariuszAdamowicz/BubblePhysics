import BubblePhysics
import BubblePhysicsMetalRender
import BubblePhysicsMetalRenderBenchmark
import Metal
import simd
import XCTest

/// P-B-29 (G8-AC2), część sceny: cztery sceny budżetowe iPhone'a X (tłum w spoczynku, gumka do ściany, czołowe 128, „2” w tłum) budują
/// się ze 150 bańkami i liczą się bez `worldFailed`; w scenach uderzeń co najmniej 10 % klatek mierzonych ma więcej niż 1 podkrok, a ich
/// szczyt podkroków jest co najmniej 3 × większy niż w tłumie w spoczynku. Pomiar p95 na urządzeniu to zadanie 23 planu, nie te testy.
@MainActor
final class BudgetSceneTests: XCTestCase {
    private typealias Scene = PublicWorldStressBenchmark.Scene

    private let scenes: [(scene: Scene, name: String)] = [
        (.restingCrowd, "resting-crowd"), (.bandToWall, "band-to-wall"), (.headOn128, "head-on-128"), (.shotIntoCrowd, "shot-into-crowd")]

    private func device() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("brak urządzenia Metal") }
        return device
    }

    private func operations(of scene: Scene) throws -> [WorldOperation] {
        let world = try BubbleWorld.makeBenchmarkWorld(configuration: scene.configuration(), device: device())
        return try scene.initialTransaction(assets: XCTUnwrap(world.assets)).operations
    }

    private func bubbles(of scene: Scene) throws -> [BubbleDescriptor] {
        try operations(of: scene).compactMap { if case .add(.bubble(let bubble)) = $0 { return bubble } else { return nil } }
    }

    func testSceneNamesInTheReportUseHyphensLikeStress300() {
        XCTAssertEqual(scenes.map(\.scene.name), scenes.map(\.name))
        for entry in scenes { XCTAssertEqual(entry.scene.gateMilliseconds, 16.67, accuracy: 1e-9, entry.name) }
    }

    func testEverySceneBuildsWithExactly150Bubbles() throws {
        for entry in scenes {
            XCTAssertEqual(try bubbles(of: entry.scene).count, 150, entry.name)
        }
    }

    func testEverySceneHasWallsAndNoDynamicRigidBodies() throws {
        for entry in scenes {
            var statics = 0
            for operation in try operations(of: entry.scene) {
                guard case .add(.rigidBody(let body)) = operation else { continue }
                XCTAssertTrue(body.motionRole == .static || body.motionRole == .kinematic, "\(entry.name): bryła dynamiczna \(body.id)")
                if body.motionRole == .static { statics += 1 }
            }
            XCTAssertGreaterThanOrEqual(statics, 4, "\(entry.name): ściany regionu")
        }
    }

    func testEverySceneRunsWithoutAFailedFrame() async throws {
        let device = try device()
        for entry in scenes {
            let report = try await PublicWorldStressBenchmark.run(device: device, scene: entry.scene,
                warmupFrames: 30, measuredFrames: 120, progress: { _, _ in })
            XCTAssertEqual(report.scene, entry.name)
            XCTAssertEqual(report.failedFrames, 0, "\(entry.name): klatka nieudana albo świat w stanie worldFailed")
            XCTAssertEqual(report.nonFiniteFrames, 0, entry.name)
            XCTAssertEqual(report.fallbackFrames, 0, entry.name)
            XCTAssertTrue(report.allSeriesComplete, entry.name)
            XCTAssertEqual(report.measuredFrames, 120, entry.name)
            XCTAssertEqual(report.contactCandidateOverflow, 0, entry.name)
            XCTAssertTrue(report.safetyPassed, entry.name)
        }
    }

    /// Sceny uderzeń powtarzają je co 20 klatek (także w części mierzonej) transakcją `.replace` uczestników: pozycje i prędkości wracają
    /// do wartości początkowych, żeby uderzenia nie skończyły się w rozgrzewce i nie zniknęły poniżej p95.
    func testImpactScenesRepeatTheImpactEveryTwentyFramesAndTheOthersDoNot() throws {
        for scene in [Scene.restingCrowd, .bandToWall] {
            for step in 0..<400 { XCTAssertNil(try scene.stepTransaction(step: step), "\(scene.name) krok \(step)") }
        }
        for scene in [Scene.headOn128, .shotIntoCrowd] {
            let initial = Dictionary(uniqueKeysWithValues: try bubbles(of: scene).map { ($0.id, $0) })
            for step in 0..<400 {
                let transaction = try scene.stepTransaction(step: step)
                guard step > 0, step % 20 == 0 else { XCTAssertNil(transaction, "\(scene.name) krok \(step)"); continue }
                let replaced = try XCTUnwrap(transaction, "\(scene.name) krok \(step)").operations.compactMap { operation -> BubbleDescriptor? in
                    if case .replace(let id, .bubble(let bubble)) = operation { XCTAssertEqual(id, bubble.id); return bubble }
                    XCTFail("\(scene.name) krok \(step): tylko .replace baniek uczestników, a jest \(operation)")
                    return nil
                }
                XCTAssertFalse(replaced.isEmpty)
                for bubble in replaced {
                    let start = try XCTUnwrap(initial[bubble.id], "uczestnik \(bubble.id) jest w scenie")
                    XCTAssertEqual(bubble.position, start.position, "\(scene.name): pozycja startowa \(bubble.id)")
                    XCTAssertEqual(bubble.velocity, start.velocity, "\(scene.name): prędkość startowa \(bubble.id)")
                    XCTAssertEqual(bubble.targetRadius, start.targetRadius)
                }
            }
        }
    }

    /// Uczestnicy uderzeń startują z toru, którego tłum nie zajmie: żadna bańka tłumu nie leży bliżej niż suma promieni od punktu
    /// startu, ani na odcinku od startu do pierwszego kontaktu (pas lotu o szerokości średnicy uczestnika).
    func testImpactParticipantsStartOnAFreeTrack() throws {
        for scene in [Scene.headOn128, .shotIntoCrowd] {
            let all = try bubbles(of: scene)
            let movers = all.filter { simd_length($0.velocity) > 0 }
            XCTAssertEqual(movers.count, scene == .headOn128 ? 2 : 1, scene.name)
            for mover in movers {
                let direction = simd_normalize(mover.velocity)
                for other in all where other.id != mover.id && simd_length(other.velocity) == 0 {
                    let offset = other.position - mover.position
                    XCTAssertGreaterThan(simd_length(offset), mover.targetRadius + other.targetRadius,
                                         "\(scene.name): bańka \(other.id) nakłada się na start \(mover.id)")
                    // Przed uderzeniem tor jest wolny: bańki tłumu nie leżą na pasie lotu przed pierwszą przeszkodą (ramą albo pasem).
                    let along = simd_dot(offset, direction)
                    let across = abs(offset.x * direction.y - offset.y * direction.x)
                    if along > 0, across < mover.targetRadius + other.targetRadius {
                        XCTAssertGreaterThan(along, 40, "\(scene.name): bańka \(other.id) tuż na torze \(mover.id)")
                    }
                }
            }
        }
    }

    func testImpactScenesTakeMoreSubstepsThanTheRestingCrowd() async throws {
        let device = try device()
        func report(_ scene: Scene) async throws -> PublicWorldStressReport {
            try await PublicWorldStressBenchmark.run(device: device, scene: scene, warmupFrames: 30, measuredFrames: 200,
                                                     progress: { _, _ in })
        }
        let resting = try await report(.restingCrowd)
        XCTAssertEqual(resting.substepMax, 1, "G5-AC1: tłum w spoczynku liczy dokładnie 1 podkrok na krok")
        for scene in [Scene.headOn128, .shotIntoCrowd] {
            let impact = try await report(scene)
            let frames = impact.substepHistogram.values.reduce(0, +)
            let multi = impact.substepHistogram.filter { $0.key > 1 }.values.reduce(0, +)
            XCTAssertEqual(frames, impact.measuredFrames, "\(scene.name): histogram obejmuje klatki mierzone")
            XCTAssertGreaterThanOrEqual(Double(multi), 0.1 * Double(frames),
                                        "\(scene.name): klatek z > 1 podkrokiem \(multi) z \(frames), histogram \(impact.substepHistogram)")
            XCTAssertGreaterThanOrEqual(impact.substepMax, 3 * resting.substepMax,
                                        "\(scene.name): substep_max \(impact.substepMax) wobec \(resting.substepMax) w tłumie")
        }
    }

    private func measuredSamples(of scene: Scene, warmup: Int = 30, measured: Int = 120) async throws -> [PublicWorldStressFrameSample] {
        let device = try device()
        var samples: [PublicWorldStressFrameSample] = []
        _ = try await PublicWorldStressBenchmark.run(device: device, scene: scene, frameObserver: { samples.append($0) },
            warmupFrames: warmup, measuredFrames: measured, progress: { _, _ in })
        let frames = samples.filter { $0.series == .full && $0.index >= warmup }.sorted { $0.index < $1.index }
        XCTAssertEqual(frames.count, measured, scene.name)
        return frames
    }

    /// G8-AC2: „gumka w pełnym naciągnięciu do ściany”. W każdej klatce mierzonej „2” stoi dociśnięta do pionowej ściany (x = 330)
    /// siłą napiętej gumki, więc środek leży bliżej ściany niż promień 24, a statyczny docisk liczy co najmniej 2 podkroki (G5-AC2).
    /// Scena, w której „2” dopiero rozpędza się i odbija od ściany, ma klatki bez kontaktu i z 1 podkrokiem.
    func testBandToWallPressesTheTwoAgainstTheWallInEveryMeasuredFrame() async throws {
        let wallSurface: Float = 330, radius: Float = 24
        for sample in try await measuredSamples(of: .bandToWall) {
            let state = try XCTUnwrap(sample.frame.objects[ObjectID(rawValue: 150)], "klatka \(sample.index): brak „2”")
            let distance = wallSurface - state.position.x
            XCTAssertLessThan(distance, radius, "klatka \(sample.index): „2” bez kontaktu ze ścianą, środek \(state.position.x)")
            XCTAssertGreaterThan(distance, 0, "klatka \(sample.index): „2” za ścianą, środek \(state.position.x)")
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(sample.substepCount), 2, "klatka \(sample.index): docisk bez podkroków")
        }
    }

    /// Uderzenia sceny `.replace` co 20 klatek; odrzucona transakcja po cichu wyłączyłaby uderzenia.
    func testImpactScenesNeverRejectTheReplaceTransaction() async throws {
        for scene in [Scene.headOn128, .shotIntoCrowd] {
            var replaced = 0
            for sample in try await measuredSamples(of: scene, warmup: 30, measured: 60) {
                for event in sample.frame.events {
                    if case .transactionRejected(_, let rejection) = event {
                        XCTFail("\(scene.name) klatka \(sample.index): transakcja odrzucona: \(rejection)")
                    }
                }
                replaced += sample.frame.transactionReceipts.count
            }
            XCTAssertGreaterThan(replaced, 0, "\(scene.name): w klatkach mierzonych są przyjęte transakcje uderzenia")
        }
    }
}
