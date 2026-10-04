import XCTest
@testable import BubblePhysicsReference

final class ReferenceBenchmarkMatrixTests: XCTestCase {
    func testDefaultMatrixRunsFreshWorldsInFourEightTwelveSixteenOrder() async throws {
        let configuration = ReferenceBenchmarkMatrixConfiguration(
            scene: .interactive24, warmupSteps: 0, measuredSteps: 0
        )
        let report = try await ReferenceBenchmarkMatrixRunner.measure(configuration: configuration)
        XCTAssertEqual(report.runs.map(\.newtonIterationLimit), [4, 8, 12, 16])
        XCTAssertEqual(Set(report.runs.map(\.seed)), [configuration.seed])
    }

    func testProgressIsMonotonicAcrossWholeMatrix() async throws {
        let configuration = ReferenceBenchmarkMatrixConfiguration(
            scene: .interactive24, warmupSteps: 1, measuredSteps: 1, iterationLimits: [4, 8]
        )
        let recorder = ProgressRecorder()
        _ = try await ReferenceBenchmarkMatrixRunner.measure(configuration: configuration) {
            await recorder.append($0)
        }
        let values = await recorder.values
        XCTAssertEqual(values.map(\.completedSteps), values.map(\.completedSteps).sorted())
        XCTAssertEqual(values.last?.completedSteps, values.last?.totalSteps)
        XCTAssertEqual(values.last?.totalSteps, 4)
    }

    func testCancellationDuringWarmupThrowsWithoutMatrixReport() async {
        await assertCancellation(afterLocalStep: 1, warmup: 2, measured: 2)
    }

    func testCancellationDuringMeasuredFramesThrowsWithoutMatrixReport() async {
        await assertCancellation(afterLocalStep: 3, warmup: 2, measured: 2)
    }

    func testPlainTextContainsDeviceScenarioLimitsAndTimeQualityColumns() async throws {
        let report = try await ReferenceBenchmarkMatrixRunner.measure(configuration: .init(
            scene: .interactive24, warmupSteps: 0, measuredSteps: 0
        ))
        let text = report.plainText(deviceName: "iPhone Test", systemVersion: "iOS 20.0")
        XCTAssertTrue(text.contains("iPhone Test"))
        XCTAssertTrue(text.contains("iOS 20.0"))
        XCTAssertTrue(text.contains("interactive24"))
        XCTAssertTrue(text.contains("limit"))
        XCTAssertTrue(text.contains("full_p95_ms"))
        XCTAssertTrue(text.contains("penetration_p95"))
        XCTAssertTrue(text.contains("unconverged_components"))
        for limit in [4, 8, 12, 16] { XCTAssertTrue(text.contains("\(limit)")) }
    }

    private func assertCancellation(afterLocalStep boundary: Int, warmup: Int, measured: Int) async {
        do {
            _ = try await ReferenceBenchmarkMatrixRunner.measure(
                configuration: .init(
                    scene: .interactive24, warmupSteps: warmup,
                    measuredSteps: measured, iterationLimits: [4]
                ),
                progress: { _ in },
                run: { scenario, warmup, measured, progress in
                    for step in 1...(warmup + measured) {
                        try Task.checkCancellation()
                        await progress(step, warmup + measured)
                        if step == boundary { throw CancellationError() }
                    }
                    return try ReferenceBenchmarkRunner.measure(
                        scenario: scenario, warmupSteps: 0, measuredSteps: 0
                    )
                }
            )
            XCTFail("Oczekiwano CancellationError")
        } catch is CancellationError {
            // oczekiwany wynik
        } catch {
            XCTFail("Nieoczekiwany błąd: \(error)")
        }
    }
}

private actor ProgressRecorder {
    private(set) var values: [ReferenceBenchmarkProgress] = []
    func append(_ value: ReferenceBenchmarkProgress) { values.append(value) }
}
