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
    private var previousAngles: [UInt32: Float] = [:]

    public init() {}

    public mutating func pose(range: MetalBubbleRange, particles: [MetalParticle]) -> BubbleLabelPose {
        let center = particles[Int(range.centerIndex)].position
        guard range.boundaryCount > 0 else {
            return BubbleLabelPose(position: center, angleRadians: previousAngles[range.id] ?? 0)
        }
        let materialPoint = particles[Int(range.boundaryStart)].position
        let direction = materialPoint - center
        let rawAngle = atan2(direction.y, direction.x)
        let angle: Float
        if let previous = previousAngles[range.id] {
            var delta = rawAngle - previous
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            angle = previous + delta
        } else {
            angle = rawAngle
        }
        previousAngles[range.id] = angle
        return BubbleLabelPose(position: center, angleRadians: angle)
    }

    public mutating func reset() {
        previousAngles.removeAll(keepingCapacity: true)
    }
}
