import BubblePhysics
import BubblePhysicsAssets
import BubblePhysicsMetalRender
import CoreGraphics
import Foundation
import Metal
import XCTest

/// P-B-92–P-B-96 na Macu: poziomy trybu pojemności (wymiary, tor trójkąta, krótki przebieg), termika z wstrzykniętym stanem
/// i zegarem oraz reguła pojemności na wstrzykniętych poziomach. Pomiar na iPhonie X należy do właściciela.
@MainActor
final class CapacityMeasurementTests: XCTestCase {
    private typealias Level = PublicWorldCapacityReport.Level
    private typealias Scene = PublicWorldStressBenchmark.Scene

    private let levelCounts = [100, 150, 200, 250, 300, 350, 400]
    private let gate = PublicWorldStressBenchmark.acceptanceGateMilliseconds
    private let triangleID = ObjectID(rawValue: 10_000)

    // MARK: - Pomocnicy

    private func device() throws -> MTLDevice { try XCTUnwrap(MTLCreateSystemDefaultDevice()) }

    private func operations(_ spec: BenchmarkSceneSpec, device: MTLDevice) throws -> [WorldOperation] {
        let world = try BubbleWorld.makeBenchmarkWorld(configuration: spec.configuration(), device: device,
                                                       solverIterationLimit: 4)
        return try spec.initialTransaction(assets: XCTUnwrap(world.assets)).operations
    }

    private func bubbles(_ operations: [WorldOperation]) -> [BubbleDescriptor] {
        operations.compactMap { operation in
            if case .add(.bubble(let bubble)) = operation { return bubble }
            return nil
        }
    }

    private func triangle(_ operations: [WorldOperation]) throws -> (body: RigidBodyDescriptor, path: PathDrive) {
        var body: RigidBodyDescriptor?
        var path: PathDrive?
        for operation in operations {
            switch operation {
            case .add(.rigidBody(let candidate)) where candidate.id == triangleID: body = candidate
            case .setKinematicDrive(let id, .path(let drive)) where id == triangleID: path = drive
            default: break
            }
        }
        return (try XCTUnwrap(body, "trójkąt"), try XCTUnwrap(path, "tor trójkąta"))
    }

    private func region(_ spec: BenchmarkSceneSpec) throws -> WorldRectangle {
        try spec.configuration().simulationRegion
    }

    private func level(_ count: Int, p95: Double = 5, thermal: ProcessInfo.ThermalState = .nominal) -> Level {
        Level(bubbleCount: count, thermalWorst: thermal, p95Milliseconds: p95)
    }

    /// Zegar, w którym czas płynie tylko przez `sleep`.
    private final class FakeClock {
        var now = 0.0
        var sleeps: [Double] = []
        var clock: CooldownClock {
            CooldownClock(now: { self.now }, sleep: { seconds in self.sleeps.append(seconds); self.now += seconds })
        }
    }

    // MARK: - P-B-92: wymiary poziomów

    func testLevelRegionAndRenderTargetFollowTheFormulaForEveryLevel() throws {
        let expectedPixels = [100: 920, 150: 1270, 200: 1620, 250: 1970, 300: 2436, 350: 2902, 400: 3252]
        for count in levelCounts {
            let spec = BenchmarkSceneSpec.capacity(bubbleCount: count)
            let height = Float((count + 14) / 15) * 33.5 + 30
            let rectangle = try region(spec)
            XCTAssertEqual(rectangle.min, [0, 0], "poziom \(count)")
            XCTAssertEqual(rectangle.max.x, 375, "poziom \(count)")
            XCTAssertEqual(rectangle.max.y, height, accuracy: 1e-4, "poziom \(count)")
            XCTAssertEqual(spec.regionHeight, height, accuracy: 1e-4, "poziom \(count)")
            let size = try XCTUnwrap(spec.renderSize, "poziom \(count) ma własny cel renderu")
            XCTAssertEqual(size.width, 1125, "poziom \(count)")
            XCTAssertEqual(size.height, CGFloat(Int((2436.0 * Double(height) / 700).rounded(.down))), "poziom \(count)")
            XCTAssertEqual(size.height, CGFloat(try XCTUnwrap(expectedPixels[count])), "poziom \(count)")
        }
    }

    func testBenchmarkCreatesTheRenderTargetOfTheLevelWhenNoSizeIsGiven() async throws {
        let device = try device()
        for count in [100, 400] {
            var observed: [(Int, Int)] = []
            let report = try await PublicWorldStressBenchmark.run(device: device, spec: .capacity(bubbleCount: count),
                renderSplit: false, renderTargetObserver: { observed.append(($0.width, $0.height)) },
                warmupFrames: 0, measuredFrames: 1, progress: { _, _ in })
            XCTAssertEqual(observed.count, 1)
            XCTAssertEqual(observed.first?.0, 1125)
            XCTAssertEqual(observed.first?.1, count == 100 ? 920 : 3252)
            XCTAssertEqual(report.renderWidth, 1125)
            XCTAssertEqual(report.renderHeight, count == 100 ? 920 : 3252)
        }
    }

    func testFirstNBubblesAreIdenticalOnEveryLevel() throws {
        let device = try device()
        let largest = bubbles(try operations(.capacity(bubbleCount: 400), device: device))
        XCTAssertEqual(largest.count, 400)
        for count in levelCounts {
            let level = bubbles(try operations(.capacity(bubbleCount: count), device: device))
            XCTAssertEqual(level.count, count, "poziom \(count)")
            XCTAssertTrue(level.allSatisfy { $0.decal != nil }, "poziom \(count): naklejka tekstowa na każdej bańce")
            XCTAssertEqual(Set(level.map(\.layer)), [0, 1], "poziom \(count): dwie warstwy")
            XCTAssertEqual(level, Array(largest.prefix(count)), "pierwsze \(count) baniek jak na poziomie 400")
        }
    }

    func testLevel300HasTheSameOperationsAndTargetAsTheAcceptanceScene() throws {
        let device = try device()
        let capacity = try operations(.capacity(bubbleCount: 300), device: device)
        let acceptance = try Scene.acceptance.initialTransaction(
            assets: XCTUnwrap(BubbleWorld.makeBenchmarkWorld(configuration: Scene.acceptance.configuration(), device: device,
                                                             solverIterationLimit: 4).assets)).operations
        XCTAssertEqual(capacity, acceptance)
        XCTAssertEqual(try region(.capacity(bubbleCount: 300)), try Scene.acceptance.configuration().simulationRegion)
        XCTAssertEqual(BenchmarkSceneSpec.capacity(bubbleCount: 300).renderSize, CGSize(width: 1125, height: 2436))
    }

    // MARK: - P-B-93: tor trójkąta

    func testTriangleStartsAtTheMappedFirstWaypointAndKeepsTheClearancesOnEveryLevel() throws {
        let device = try device()
        for count in levelCounts {
            let spec = BenchmarkSceneSpec.capacity(bubbleCount: count)
            let height = spec.regionHeight
            let (body, path) = try triangle(try operations(spec, device: device))
            XCTAssertEqual(body.motionRole, .kinematic)
            guard case .polygon(let geometry) = body.shape else { return XCTFail("trójkąt jest wielokątem") }
            // Odwzorowany `triangleWaypoints[0] = (187,5; 350)`: y′ = 105 + 245·(H − 210)/490 = H/2.
            XCTAssertEqual(body.position.x, 187.5, accuracy: 1e-3, "poziom \(count)")
            XCTAssertEqual(body.position.y, height / 2, accuracy: 1e-3, "poziom \(count)")
            let bottomOffset = geometry.vertices.map(\.y).min() ?? 0
            let topOffset = geometry.vertices.map(\.y).max() ?? 0
            let leftOffset = geometry.vertices.map(\.x).min() ?? 0
            let rightOffset = geometry.vertices.map(\.x).max() ?? 0
            // Pozycja startowa i każdy punkt toru (odcinki są proste, więc skrajne są w punktach).
            let centers = [body.position] + path.points
            var lowest = Float.infinity, highest = Float.infinity
            for center in centers {
                lowest = min(lowest, center.y + bottomOffset)
                highest = min(highest, height - (center.y + topOffset))
                XCTAssertGreaterThan(center.x + leftOffset, 0, "poziom \(count): w obszarze z lewej")
                XCTAssertLessThan(center.x + rightOffset, 375, "poziom \(count): w obszarze z prawej")
            }
            XCTAssertEqual(lowest, 53, accuracy: 1e-3, "najmniejszy odstęp od dolnej krawędzi, poziom \(count)")
            XCTAssertEqual(highest, 71, accuracy: 1e-3, "najmniejszy odstęp od górnej krawędzi, poziom \(count)")
        }
    }

    func testTriangleStartAndPathAtHeight700AreTheCurrentOnes() throws {
        let device = try device()
        let (body, path) = try triangle(try operations(.capacity(bubbleCount: 300), device: device))
        XCTAssertEqual(body.position, [187.5, 350])
        let lap: [WorldPoint] = [[65, 105], [310, 595], [310, 105], [65, 595], [187.5, 350]]
        XCTAssertEqual(path.points, lap + lap)
        XCTAssertEqual(path.speed, 200)
    }

    // MARK: - P-B-94: krótki przebieg poziomu

    private func countBubbles(_ frame: WorldFrame) -> Int {
        frame.objects.values.filter { if case .bubble = $0.kind { return true } else { return false } }.count
    }

    func testShortRunOfEveryLevelHasTheFullAndThePhysicsSeriesOnlyWithNBubblesInEveryFrame() async throws {
        let device = try device()
        for count in levelCounts {
            var samples: [PublicWorldStressFrameSample] = []
            let report = try await PublicWorldStressBenchmark.run(device: device, spec: .capacity(bubbleCount: count),
                renderSplit: false, frameObserver: { samples.append($0) },
                warmupFrames: 1, measuredFrames: 2, progress: { _, _ in })
            XCTAssertEqual(Set(samples.map(\.series)), [.full, .physicsOnly], "poziom \(count): bez serii podziału renderu")
            for series in [PublicWorldStressFrameSample.Series.full, .physicsOnly] {
                let frames = samples.filter { $0.series == series }
                XCTAssertEqual(frames.count, 3, "poziom \(count), seria \(series): rozgrzewka i klatki mierzone")
                for sample in frames {
                    XCTAssertEqual(countBubbles(sample.frame), count, "poziom \(count), seria \(series), klatka \(sample.index)")
                    XCTAssertEqual(sample.renderEncoded, series == .full, "tylko seria z renderem koduje render")
                }
            }
            XCTAssertEqual(report.failedFrames, 0, "poziom \(count)")
            XCTAssertEqual(report.nonFiniteFrames, 0, "poziom \(count)")
            XCTAssertFalse(report.hasRenderSplit, "poziom \(count)")
            XCTAssertEqual(report.bubbleCountMismatchFrames, 0, "poziom \(count)")
            XCTAssertEqual(report.measuredFrames, 2)
        }
    }

    func testCapacityReportHasOneLevelLinePerLevelInTheDocumentedFormat() async throws {
        let device = try device()
        let report = try await PublicWorldStressBenchmark.measureCapacity(device: device, levels: levelCounts,
            warmupFrames: 1, measuredFrames: 2, thermalState: { .nominal }, clock: FakeClock().clock,
            cooldownLimit: 600)
        XCTAssertEqual(report.levels.map(\.bubbleCount), levelCounts)
        let lines = report.text.components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("scene=capacity"), report.text)
        XCTAssertTrue(lines.contains("warmup=1; measured=2"), report.text)
        XCTAssertTrue(lines.contains("p95_gate_ms=16.6700"), report.text)
        XCTAssertTrue(lines.contains(where: { $0.hasPrefix("path=") }))
        XCTAssertTrue(lines.contains(where: { $0.hasPrefix("device=") }))
        let levelLines = lines.filter { $0.hasPrefix("level=") }
        XCTAssertEqual(levelLines.count, 7)
        let keys = ["level", "cooldown_s", "cooldown_timeout", "thermal_worst", "valid", "p95_ms", "host_non_gpu_p95_ms",
                    "gpu_physics_p95_ms", "gpu_render_estimate_ms", "max_candidates_per_object", "candidate_limit",
                    "failed_frames", "non_finite_frames", "contour_cpu_readbacks", "contact_candidate_overflow", "bubbles"]
        for (line, count) in zip(levelLines, levelCounts) {
            let fields = line.components(separatedBy: "; ")
            XCTAssertEqual(fields.map { String($0.prefix(while: { $0 != "=" })) }, keys, line)
            XCTAssertEqual(fields.first, "level=\(count)")
            for field in ["cooldown_timeout=0", "thermal_worst=nominal", "valid=1", "candidate_limit=128", "failed_frames=0",
                          "non_finite_frames=0", "contour_cpu_readbacks=0", "contact_candidate_overflow=0", "bubbles=\(count)"] {
                XCTAssertTrue(fields.contains(field), "\(field) w \(line)")
            }
        }
        XCTAssertEqual(lines.last(where: { !$0.isEmpty })?.hasPrefix("capacity="), true, report.text)
        XCTAssertEqual(report.text.components(separatedBy: "\ncapacity=").count, 2, "jedna linia capacity=")
    }

    func testLevelLineSumsTheCountersOfBothSeriesAndReportsABubbleMismatch() {
        let broken = Level(bubbleCount: 250, cooldownSeconds: 12.34, cooldownTimedOut: true, thermalWorst: .serious,
                           p95Milliseconds: 18.5, hostNonGPUP95Milliseconds: 6.25, gpuPhysicsP95Milliseconds: 8,
                           gpuRenderEstimateMilliseconds: 6.5, maximumCandidatesPerObject: 17, candidateLimit: 128,
                           failedFrames: 1, nonFiniteFrames: 2, contourCPUReadbacks: 3, contactCandidateOverflow: 4,
                           bubblesMatchedInEveryFrame: false)
        XCTAssertEqual(broken.text, "level=250; cooldown_s=12.3; cooldown_timeout=1; thermal_worst=serious; valid=0; "
            + "p95_ms=18.5000; host_non_gpu_p95_ms=6.2500; gpu_physics_p95_ms=8.0000; gpu_render_estimate_ms=6.5000; "
            + "max_candidates_per_object=17; candidate_limit=128; failed_frames=1; non_finite_frames=2; "
            + "contour_cpu_readbacks=3; contact_candidate_overflow=4; bubbles=mismatch")
        XCTAssertFalse(broken.isValid)
        XCTAssertFalse(broken.passesGate)
        XCTAssertTrue(level(100, p95: gate).passesGate, "p95 równe bramce zdaje")
        XCTAssertFalse(level(100, p95: gate + 0.0001).passesGate)
    }

    // MARK: - P-B-95: termika

    func testCooldownWaitsUntilNominalAndReportsTheWaitingTime() async throws {
        let fake = FakeClock()
        var reads = 0
        let result = try await ThermalCooldown.wait(thermalState: { reads += 1; return fake.now < 20 ? .serious : .nominal },
                                                    clock: fake.clock, limit: 600)
        XCTAssertFalse(result.timedOut)
        XCTAssertGreaterThanOrEqual(result.seconds, 20)
        XCTAssertLessThan(result.seconds, 20 + ThermalCooldown.pollIntervalSeconds + 1e-9)
        XCTAssertEqual(result.seconds, fake.now, accuracy: 1e-9)
        XCTAssertGreaterThan(reads, 1)

        let idle = FakeClock()
        let immediate = try await ThermalCooldown.wait(thermalState: { .nominal }, clock: idle.clock, limit: 600)
        XCTAssertEqual(immediate.seconds, 0)
        XCTAssertFalse(immediate.timedOut)
        XCTAssertTrue(idle.sleeps.isEmpty, "nominal od początku: bez czekania")
    }

    func testCooldownGivesUpAtTheLimitAndSaysSo() async throws {
        let fake = FakeClock()
        let result = try await ThermalCooldown.wait(thermalState: { .fair }, clock: fake.clock, limit: 600)
        XCTAssertTrue(result.timedOut, "fair to nie nominal")
        XCTAssertEqual(result.seconds, 600, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(fake.now, 600 + 1e-9, "nie czeka dłużej niż limit")
    }

    func testLevelIsMeasuredAfterTheStateReturnsToNominalAndTheReportKeepsTheWaitingTime() async throws {
        let device = try device()
        let fake = FakeClock()
        let report = try await PublicWorldStressBenchmark.measureCapacity(device: device, levels: [100], warmupFrames: 1,
            measuredFrames: 2, thermalState: { fake.now < 20 ? .serious : .nominal }, clock: fake.clock, cooldownLimit: 600)
        let level = try XCTUnwrap(report.levels.first)
        XCTAssertGreaterThanOrEqual(level.cooldownSeconds, 20)
        XCTAssertFalse(level.cooldownTimedOut)
        XCTAssertEqual(level.thermalWorst, .nominal, "stan z czasu czekania nie liczy się do klatek mierzonych")
        XCTAssertTrue(level.isValid)
        XCTAssertEqual(level.bubblesMatchedInEveryFrame, true)
        XCTAssertTrue(report.text.contains("cooldown_timeout=0; thermal_worst=nominal; valid=1"), report.text)
    }

    func testLevelIsMeasuredAnywayAfterTheCooldownLimitWithTheTimeoutNoted() async throws {
        let device = try device()
        let fake = FakeClock()
        let limit = 60.0
        let coolingReads = Int(limit / ThermalCooldown.pollIntervalSeconds) + 1
        var reads = 0
        let report = try await PublicWorldStressBenchmark.measureCapacity(device: device, levels: [100], warmupFrames: 1,
            measuredFrames: 2, thermalState: { reads += 1; return reads <= coolingReads ? .fair : .nominal },
            clock: fake.clock, cooldownLimit: limit)
        let level = try XCTUnwrap(report.levels.first)
        XCTAssertTrue(level.cooldownTimedOut)
        XCTAssertEqual(level.cooldownSeconds, limit, accuracy: 1e-9)
        XCTAssertEqual(level.thermalWorst, .nominal)
        XCTAssertGreaterThan(level.p95Milliseconds, 0, "poziom zmierzony mimo przekroczenia")
        XCTAssertEqual(level.failedFrames, 0)
        XCTAssertEqual(level.bubblesMatchedInEveryFrame, true)
        XCTAssertTrue(report.text.contains("cooldown_s=60.0; cooldown_timeout=1;"), report.text)
    }

    /// Stan czytany raz na klatkę mierzoną każdej serii (po rozgrzewce): jedno czytanie przed poziomem (czekanie na `nominal`),
    /// potem 2 klatki serii z renderem i 2 klatki serii bez renderu.
    private func worstThermal(scriptedAfterCooldown states: [ProcessInfo.ThermalState]) async throws -> Level {
        let device = try device()
        var script = [ProcessInfo.ThermalState.nominal] + states
        let report = try await PublicWorldStressBenchmark.measureCapacity(device: device, levels: [100], warmupFrames: 1,
            measuredFrames: 2, thermalState: { script.isEmpty ? .nominal : script.removeFirst() }, clock: FakeClock().clock,
            cooldownLimit: 600)
        return try XCTUnwrap(report.levels.first)
    }

    func testSeriousInAMeasuredFrameOfTheSeriesWithoutRenderMakesTheLevelInvalidAndIsReportedAsTheWorstState() async throws {
        let level = try await worstThermal(scriptedAfterCooldown: [.nominal, .nominal, .fair, .serious])
        XCTAssertEqual(level.thermalWorst, .serious)
        XCTAssertFalse(level.isValid)
        XCTAssertTrue(level.text.contains("thermal_worst=serious; valid=0;"), level.text)
    }

    func testFairInEitherSeriesStaysValidAndCriticalIsTheWorstState() async throws {
        let fair = try await worstThermal(scriptedAfterCooldown: [.nominal, .fair, .nominal, .nominal])
        XCTAssertEqual(fair.thermalWorst, .fair)
        XCTAssertTrue(fair.isValid)
        XCTAssertTrue(fair.text.contains("thermal_worst=fair; valid=1;"), fair.text)
        let critical = try await worstThermal(scriptedAfterCooldown: [.serious, .nominal, .critical, .nominal])
        XCTAssertEqual(critical.thermalWorst, .critical)
        XCTAssertFalse(critical.isValid)
    }

    func testSeriousInTheSeriesWithRenderMakesTheLevelInvalidToo() async throws {
        let level = try await worstThermal(scriptedAfterCooldown: [.nominal, .serious, .nominal, .nominal])
        XCTAssertEqual(level.thermalWorst, .serious)
        XCTAssertFalse(level.isValid)
    }

    // MARK: - P-B-96: reguła pojemności

    private func levels(passing: Set<Int>, invalid: Set<Int> = [], counts: [Int]? = nil) -> [Level] {
        (counts ?? levelCounts).map { count in
            level(count, p95: passing.contains(count) ? 12 : 20, thermal: invalid.contains(count) ? .serious : .nominal)
        }
    }

    func testCapacityIsTheLargestLevelPassingTogetherWithAllLowerOnes() {
        XCTAssertEqual(CapacityRule.evaluate(levels(passing: [100, 150, 200, 250])), .bubbles(250))
        XCTAssertEqual(CapacityRule.evaluate(levels(passing: [100, 150, 200, 250])).reportText, "250")
    }

    func testNonMonotonicResultsStopAtTheFirstFailingLevel() {
        let result = CapacityRule.evaluate(levels(passing: [100, 150, 200, 300, 350, 400]))
        XCTAssertEqual(result, .bubbles(200))
        XCTAssertEqual(result.reportText, "200")
    }

    func testAllLevelsPassingGivesAtLeastTheLargestLevel() {
        let result = CapacityRule.evaluate(levels(passing: Set(levelCounts)))
        XCTAssertEqual(result, .atLeastLargest(400))
        XCTAssertEqual(result.reportText, ">=400")
    }

    func testFailingTheSmallestLevelGivesBelowTheSmallestLevel() {
        let result = CapacityRule.evaluate(levels(passing: Set(levelCounts.dropFirst())))
        XCTAssertEqual(result, .belowSmallest(100))
        XCTAssertEqual(result.reportText, "<100")
    }

    func testInvalidLevelAtOrBelowTheFirstFailingLevelMakesCapacityUndecided() {
        // Zdają 100–250, nie zdaje 300 (pierwszy niezdający): nieważny 200 (poniżej), 300 (równy), a przy samych zdających 400.
        for invalid in [200, 300] {
            let result = CapacityRule.evaluate(levels(passing: [100, 150, 200, 250], invalid: [invalid]))
            XCTAssertEqual(result, .undecidedThermal, "nieważny poziom \(invalid)")
            XCTAssertEqual(result.reportText, "undecided_thermal")
        }
        XCTAssertEqual(CapacityRule.evaluate(levels(passing: Set(levelCounts), invalid: [400])), .undecidedThermal,
                       "zdają wszystkie, ale 400 jest nieważny")
        XCTAssertEqual(CapacityRule.evaluate(levels(passing: Set(levelCounts.dropFirst()), invalid: [100])), .undecidedThermal,
                       "nie zdaje 100, a jest nieważny")
    }

    func testInvalidLevelAboveTheFirstFailingLevelDoesNotChangeTheResult() {
        let result = CapacityRule.evaluate(levels(passing: [100, 150, 200, 250], invalid: [350, 400]))
        XCTAssertEqual(result, .bubbles(250))
        // Nieważny i zdający powyżej pierwszego niezdającego też nie zmienia wyniku.
        XCTAssertEqual(CapacityRule.evaluate(levels(passing: [100, 150, 200, 350, 400], invalid: [350])), .bubbles(200))
    }
}
