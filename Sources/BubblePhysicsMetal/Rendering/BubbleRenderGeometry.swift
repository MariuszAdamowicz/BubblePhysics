import Foundation
import simd

public struct BubbleRenderSpan: Equatable, Sendable {
    public let bubbleID: UInt32
    public let fillIndexRange: Range<Int>
    public let outlineIndexRange: Range<Int>
    public let diagnosticPointRange: Range<Int>
}

public struct BubbleRenderGeometryBuffers: Equatable, Sendable {
    public let fillIndices: [UInt32]
    public let outlineIndices: [UInt32]
    public let diagnosticPointIndices: [UInt32]
    public let bubbles: [BubbleRenderSpan]
}

public enum BubbleRenderGeometry {
    public static func build(ranges: [MetalBubbleRange]) -> BubbleRenderGeometryBuffers {
        var fillIndices: [UInt32] = []
        var outlineIndices: [UInt32] = []
        var diagnosticPointIndices: [UInt32] = []
        var bubbles: [BubbleRenderSpan] = []

        for range in ranges {
            let boundaryCount = Int(range.boundaryCount)
            let fillStart = fillIndices.count
            if boundaryCount >= 3 {
                for offset in 0..<boundaryCount {
                    fillIndices.append(range.centerIndex)
                    fillIndices.append(range.boundaryStart + UInt32(offset))
                    fillIndices.append(range.boundaryStart + UInt32((offset + 1) % boundaryCount))
                }
            }

            let outlineStart = outlineIndices.count
            if boundaryCount >= 2 {
                for offset in 0..<boundaryCount {
                    outlineIndices.append(range.boundaryStart + UInt32(offset))
                    outlineIndices.append(range.boundaryStart + UInt32((offset + 1) % boundaryCount))
                }
            }

            let diagnosticStart = diagnosticPointIndices.count
            diagnosticPointIndices.append(range.centerIndex)
            for offset in 0..<boundaryCount {
                diagnosticPointIndices.append(range.boundaryStart + UInt32(offset))
            }
            bubbles.append(BubbleRenderSpan(
                bubbleID: range.id,
                fillIndexRange: fillStart..<fillIndices.count,
                outlineIndexRange: outlineStart..<outlineIndices.count,
                diagnosticPointRange: diagnosticStart..<diagnosticPointIndices.count
            ))
        }
        return BubbleRenderGeometryBuffers(
            fillIndices: fillIndices,
            outlineIndices: outlineIndices,
            diagnosticPointIndices: diagnosticPointIndices,
            bubbles: bubbles
        )
    }
}

public struct BubbleLabelPose: Equatable, Sendable {
    public let position: SIMD2<Float>
    public let angleRadians: Float
    public let scale: SIMD2<Float>

    public init(position: SIMD2<Float>, angleRadians: Float, scale: SIMD2<Float> = SIMD2(repeating: 1)) {
        self.position = position
        self.angleRadians = angleRadians
        self.scale = scale
    }
}

public struct BubbleMaterialAxis: Sendable {
    public private(set) var angleRadians: Float = 0
    public private(set) var angularVelocity: Float = 0
    private var isInitialized = false
    private var bubbleStates: [UInt32: AxisState] = [:]

    private struct AxisState: Sendable {
        var angle: Float
        var velocity: Float
    }

    public init() {}

    @discardableResult
    public mutating func update(materialSamples: [SIMD2<Float>], deltaTime: Float) -> Float {
        guard let target = Self.meanAngle(materialSamples) else { return angleRadians }
        if !isInitialized {
            angleRadians = target
            angularVelocity = 0
            isInitialized = true
            return angleRadians
        }
        let dt = max(deltaTime, 1 / 1_000)
        let unwrapped = Self.unwrap(target, around: angleRadians)
        let blend = 1 - exp(-8 * dt)
        let previous = angleRadians
        angleRadians += (unwrapped - angleRadians) * blend
        let measuredVelocity = (angleRadians - previous) / dt
        angularVelocity += (measuredVelocity - angularVelocity) * (1 - exp(-10 * dt))
        return angleRadians
    }

    public mutating func pose(range: MetalBubbleRange, particles: [MetalParticle]) -> BubbleLabelPose {
        let center = particles[Int(range.centerIndex)].position
        guard range.boundaryCount > 0 else {
            return BubbleLabelPose(position: center, angleRadians: bubbleStates[range.id]?.angle ?? 0)
        }
        let count = Int(range.boundaryCount)
        let sampleCount = min(8, count)
        let samples = (0..<sampleCount).map { sample -> SIMD2<Float> in
            let offset = sample * count / sampleCount
            return particles[Int(range.boundaryStart) + offset].position - center
        }
        guard let rawAngle = Self.meanAngle(samples) else {
            return BubbleLabelPose(position: center, angleRadians: bubbleStates[range.id]?.angle ?? 0)
        }
        let previous = bubbleStates[range.id]
        let angle = previous.map { Self.unwrap(rawAngle, around: $0.angle) } ?? rawAngle
        bubbleStates[range.id] = AxisState(angle: angle, velocity: angle - (previous?.angle ?? angle))
        return BubbleLabelPose(position: center, angleRadians: angle)
    }

    public mutating func reset() {
        angleRadians = 0; angularVelocity = 0; isInitialized = false
        bubbleStates.removeAll(keepingCapacity: true)
    }


    private static func meanAngle(_ samples: [SIMD2<Float>]) -> Float? {
        let valid = samples.filter { simd_length_squared($0) > 1e-10 && $0.x.isFinite && $0.y.isFinite }
        guard !valid.isEmpty else { return nil }
        let direction = valid.reduce(SIMD2<Float>.zero) { total, sample in total + simd_normalize(sample) }
        guard simd_length_squared(direction) > 1e-10 else { return nil }
        return atan2(direction.y, direction.x)
    }

    private static func unwrap(_ target: Float, around reference: Float) -> Float {
        var delta = target - reference
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return reference + delta
    }
}
