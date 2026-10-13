import XCTest
@testable import BubblePhysicsNativeMetal

final class NativeMetalQualityEnvelopeTests: XCTestCase {
    // Literal limits independently derived from the approved formulas.
    func testPenetrationBoundariesAndAbsoluteFloor() {
        for (cpuP95, cpuMax, allowedP95, allowedMax) in [(10.0, 20.0, 11.0, 23.0), (1, 2, 1.5, 3)] {
            let cpu = sample(p95: cpuP95, maximum: cpuMax)
            XCTAssertTrue(NativeMetalQualityEnvelope.evaluate(cpu: cpu,
                gpu: sample(p95: allowedP95, maximum: allowedMax)).isEmpty)
            XCTAssertEqual(NativeMetalQualityEnvelope.evaluate(cpu: cpu,
                gpu: sample(p95: allowedP95 + 0.0001, maximum: allowedMax)), [.penetrationP95])
            XCTAssertEqual(NativeMetalQualityEnvelope.evaluate(cpu: cpu,
                gpu: sample(p95: allowedP95, maximum: allowedMax + 0.0001)), [.penetrationMaximum])
        }
    }

    func testContainmentAndNonFiniteAlwaysReject() {
        var gpu = sample()
        gpu.containment = 1
        gpu.hasNonFiniteState = true
        XCTAssertEqual(NativeMetalQualityEnvelope.evaluate(cpu: sample(), gpu: gpu), [.containment, .nonFinite])
        gpu = sample()
        gpu.penetrationP95 = .nan
        XCTAssertTrue(NativeMetalQualityEnvelope.evaluate(cpu: sample(), gpu: gpu).contains(.nonFinite))
    }

    func testJitterAndContourReturnRequireStrictBoundaries() {
        var gpu = sample()
        gpu.maximumRestDisplacementRadiusFraction = 0.001
        gpu.releasedContourMeanRadiusErrorFraction = 0.02
        gpu.contourOscillationGrows = true
        XCTAssertEqual(NativeMetalQualityEnvelope.evaluate(cpu: sample(), gpu: gpu),
                       [.restJitter, .contourReturn, .contourOscillation])
        gpu.maximumRestDisplacementRadiusFraction = 0.000999
        gpu.releasedContourMeanRadiusErrorFraction = 0.019999
        gpu.contourOscillationGrows = false
        XCTAssertTrue(NativeMetalQualityEnvelope.evaluate(cpu: sample(), gpu: gpu).isEmpty)
    }

    func testRepeatabilityComparesGPUWithItsOwnRepeatedSequence() {
        var gpu = sample()
        gpu.publishedStateHash = 99
        gpu.repeatedPublishedStateHash = 99
        XCTAssertTrue(NativeMetalQualityEnvelope.evaluate(cpu: sample(), gpu: gpu).isEmpty)
        gpu.repeatedPublishedStateHash = 100
        XCTAssertEqual(NativeMetalQualityEnvelope.evaluate(cpu: sample(), gpu: gpu), [.repeatability])
    }

    func testMissingDynamicEvidenceCannotPassQualityGate() {
        var gpu = sample()
        gpu.maximumRestDisplacementRadiusFraction = nil
        gpu.publishedStateHash = nil
        XCTAssertEqual(NativeMetalQualityEnvelope.evaluate(cpu: sample(), gpu: gpu), [.missingEvidence])
    }

    private func sample(p95: Double = 1, maximum: Double = 2) -> NativeMetalQualitySample {
        .init(penetrationP95: p95, penetrationMaximum: maximum, containment: 0,
              hasNonFiniteState: false, maximumRestDisplacementRadiusFraction: 0,
              releasedContourMeanRadiusErrorFraction: 0, contourOscillationGrows: false,
              publishedStateHash: 1, repeatedPublishedStateHash: 1)
    }
}
