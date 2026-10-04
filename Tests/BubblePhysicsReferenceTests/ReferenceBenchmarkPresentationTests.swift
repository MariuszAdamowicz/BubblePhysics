import XCTest
@testable import BubblePhysicsReference

@MainActor
final class ReferenceBenchmarkPresentationTests: XCTestCase {
    func testStoppingRunPreventsLateResultPublication() async {
        let model = ReferenceBenchmarkPresentation { configuration, _ in
            try? await Task.sleep(for: .milliseconds(30))
            return .init(configuration: configuration, runs: [])
        }
        model.start(deviceName: "test", systemVersion: "test", warmupSteps: 0, measuredSteps: 0)
        model.stop()
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(model.reportText)
        XCTAssertFalse(model.isRunning)
    }

    func testStartingAgainIgnoresProgressFromPreviousGeneration() async {
        let counter = InvocationCounter()
        let model = ReferenceBenchmarkPresentation { configuration, progress in
            let invocation = await counter.next()
            if invocation == 1 {
                try? await Task.sleep(for: .milliseconds(40))
                await progress(.init(variantIndex: 0, iterationLimit: 4, completedSteps: 9, totalSteps: 10))
            } else {
                await progress(.init(variantIndex: 0, iterationLimit: 8, completedSteps: 1, totalSteps: 4))
            }
            return .init(configuration: configuration, runs: [])
        }
        model.start(deviceName: "first", systemVersion: "test", warmupSteps: 0, measuredSteps: 0)
        model.start(deviceName: "second", systemVersion: "test", warmupSteps: 0, measuredSteps: 0)
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(model.progress, 1)
        XCTAssertTrue(model.reportText?.contains("second") == true)
        XCTAssertFalse(model.reportText?.contains("first") == true)
    }

    func testCompletedMatrixPublishesCopyableReportAndStopsProgress() async {
        let model = ReferenceBenchmarkPresentation { configuration, progress in
            await progress(.init(variantIndex: 0, iterationLimit: 4, completedSteps: 1, totalSteps: 2))
            return .init(configuration: configuration, runs: [])
        }
        model.start(deviceName: "iPhone", systemVersion: "iOS", warmupSteps: 0, measuredSteps: 0)
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.progress, 1)
        XCTAssertTrue(model.reportText?.contains("iPhone") == true)
        XCTAssertNil(model.errorMessage)
    }
}

private actor InvocationCounter {
    private var count = 0
    func next() -> Int { count += 1; return count }
}
