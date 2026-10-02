import Foundation

public struct RadialFrameStepSchedule: Equatable, Sendable {
    public let deltaTime: Double
    public let sampleTimes: [Double]

    public var count: Int { sampleTimes.count }

    public static func make(
        previousTime: Double,
        currentTime: Double,
        fixedStep: Double,
        maximumStepCount: Int
    ) -> RadialFrameStepSchedule {
        precondition(fixedStep > 0)
        precondition(maximumStepCount > 0)
        let elapsed = max(0, currentTime - previousTime)
        let count = min(maximumStepCount, max(1, Int(ceil(elapsed / fixedStep))))
        let simulatedDuration = min(elapsed, fixedStep * Double(maximumStepCount))
        let deltaTime = simulatedDuration / Double(count)
        let start = currentTime - simulatedDuration
        return RadialFrameStepSchedule(
            deltaTime: deltaTime,
            sampleTimes: (1...count).map { start + Double($0) * deltaTime }
        )
    }
}
