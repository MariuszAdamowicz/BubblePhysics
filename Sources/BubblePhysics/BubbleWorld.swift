public struct WorldDiagnostics: Equatable, Sendable {
    public let bubbleCount: Int
    public let appliedCommandCount: Int

    public init(bubbleCount: Int, appliedCommandCount: Int) {
        self.bubbleCount = bubbleCount
        self.appliedCommandCount = appliedCommandCount
    }
}

public struct WorldStepReport: Equatable, Sendable {
    public let fixedTimeStep: Float
    public let appliedCommandCount: Int
    public let diagnostics: WorldDiagnostics

    public init(fixedTimeStep: Float, appliedCommandCount: Int, diagnostics: WorldDiagnostics) {
        self.fixedTimeStep = fixedTimeStep
        self.appliedCommandCount = appliedCommandCount
        self.diagnostics = diagnostics
    }
}

public struct BubbleWorld: Sendable {
    public let configuration: WorldConfiguration
    public private(set) var gravity: Vector2

    private var queuedCommands: [WorldCommand] = []
    private var nextBubbleIdentifier = 1

    public init(configuration: WorldConfiguration) {
        self.configuration = configuration
        gravity = .zero
    }

    public mutating func reserveBubbleID() -> BubbleID {
        defer { nextBubbleIdentifier += 1 }
        return BubbleID(rawValue: nextBubbleIdentifier)
    }

    public mutating func enqueue(_ command: WorldCommand) {
        queuedCommands.append(command)
    }

    @discardableResult
    public mutating func step() -> WorldStepReport {
        let commands = queuedCommands
        queuedCommands.removeAll(keepingCapacity: true)

        for command in commands {
            switch command {
            case let .setGravity(value):
                gravity = value
            }
        }

        let diagnostics = WorldDiagnostics(bubbleCount: 0, appliedCommandCount: commands.count)
        return WorldStepReport(
            fixedTimeStep: configuration.fixedTimeStep,
            appliedCommandCount: commands.count,
            diagnostics: diagnostics
        )
    }
}
