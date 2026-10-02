public struct RadialDiagnosticScene: Equatable, Sendable {
    public let bounds: AABB
    public let world: RadialWorldState
    public let labels: [String]

    public init(bounds: AABB, world: RadialWorldState, labels: [String]) {
        precondition(world.bubbles.count == labels.count)
        self.bounds = bounds
        self.world = world
        self.labels = labels
    }
}

public enum RadialDiagnosticSceneFactory {
    public static let bounds = AABB(minimum: .zero, maximum: Vector2(x: 375, y: 812))

    public static func make() throws -> RadialDiagnosticScene {
        let radii: [Float] = [430, 160, 90, 80, 72, 64, 56, 48, 32, 30, 28, 26, 24, 22, 20, 18]
        let centers: [Vector2] = [
            Vector2(x: 188, y: 660), Vector2(x: 110, y: 185),
            Vector2(x: 285, y: 170), Vector2(x: 290, y: 335),
            Vector2(x: 105, y: 355), Vector2(x: 205, y: 420),
            Vector2(x: 315, y: 485), Vector2(x: 75, y: 515),
            Vector2(x: 155, y: 555), Vector2(x: 235, y: 575),
            Vector2(x: 325, y: 620), Vector2(x: 55, y: 660),
            Vector2(x: 125, y: 715), Vector2(x: 205, y: 735),
            Vector2(x: 285, y: 720), Vector2(x: 345, y: 760)
        ]
        let contactMaterial = SpringMaterial(
            quadraticStiffness: 20, quarticStiffness: 0.0001, drag: 4
        )
        let dynamics = RadialBubbleMaterial(
            radialStiffness: 240, radialNonlinearity: 0.0005,
            radialDamping: 30, neighborStiffness: 80,
            pressureResponse: 1, contactCorrection: 0.35,
            bodyLinearDrag: 5, bodyAngularDrag: 6,
            birthDuration: 0.8, maximumRadialSpeed: 200
        )
        let bubbles = zip(radii, centers).enumerated().map { index, item in
            let (radius, center) = item
            var bubble = RadialBubbleState.collapsed(
                id: BubbleID(rawValue: index + 1), center: center,
                targetRadius: radius, maxSegmentLength: 12,
                mass: max(8, radius * radius * 0.002)
            )
            bubble.material = contactMaterial
            bubble.dynamics = dynamics
            return bubble
        }
        return try RadialDiagnosticScene(
            bounds: bounds, world: RadialWorldState(bubbles: bubbles),
            labels: radii.enumerated().map { String(1 << ($0.offset + 1)) }
        )
    }
}
