import Foundation

public struct RemeshPolicy: Equatable, Sendable {
    public let splitLength: Float
    public let mergeLength: Float
    public let persistenceFrames: Int
    public let cooldownFrames: Int

    public init(splitLength: Float, mergeLength: Float, persistenceFrames: Int, cooldownFrames: Int) {
        precondition(splitLength > mergeLength && mergeLength >= 0 && persistenceFrames > 0 && cooldownFrames >= 0)
        self.splitLength = splitLength
        self.mergeLength = mergeLength
        self.persistenceFrames = persistenceFrames
        self.cooldownFrames = cooldownFrames
    }
}

public struct AdaptiveContourVertex: Equatable, Sendable {
    public var position: Vector2
    public var previousPosition: Vector2

    public init(position: Vector2, previousPosition: Vector2) {
        self.position = position
        self.previousPosition = previousPosition
    }
}

public struct AdaptiveContour: Equatable, Sendable {
    public var vertices: [AdaptiveContourVertex]
    public var restLengths: [Float]
    public var stiffnessScales: [Float]

    public init(vertices: [AdaptiveContourVertex], restLengths: [Float], stiffnessScales: [Float]? = nil) {
        precondition(vertices.count == restLengths.count && vertices.count >= 3)
        self.vertices = vertices
        self.restLengths = restLengths
        self.stiffnessScales = stiffnessScales ?? Array(repeating: 1, count: restLengths.count)
        precondition(self.stiffnessScales.count == vertices.count)
    }

    public func springEnergy(material: SpringMaterial) -> Float {
        vertices.indices.reduce(0) { total, edge in
            let next = (edge + 1) % vertices.count
            let delta = vertices[next].position - vertices[edge].position
            let extensionValue = sqrt(delta.dot(delta)) - restLengths[edge]
            let quadratic = 0.5 * material.quadraticStiffness * extensionValue * extensionValue
            let quartic = 0.25 * material.quarticStiffness * pow(extensionValue, 4)
            return total + stiffnessScales[edge] * (quadratic + quartic)
        }
    }
}

public enum RemeshAction: Equatable, Sendable {
    case split(edgeIndex: Int)
    case merge(edgeIndex: Int)
}

public struct RemeshPlan: Equatable, Sendable {
    public let actions: [RemeshAction]
    public let resultingVertexCount: Int

    public init(actions: [RemeshAction], resultingVertexCount: Int) {
        self.actions = actions
        self.resultingVertexCount = resultingVertexCount
    }
}

public struct AdaptiveContourRemesher: Sendable {
    public let policy: RemeshPolicy
    private var longFrames: [Int] = []
    private var shortFrames: [Int] = []
    private var cooldown = 0

    public init(policy: RemeshPolicy) {
        self.policy = policy
    }

    public mutating func plan(_ contour: AdaptiveContour) -> RemeshPlan {
        synchronizeCounters(count: contour.vertices.count)
        if cooldown > 0 {
            cooldown -= 1
            return RemeshPlan(actions: [], resultingVertexCount: contour.vertices.count)
        }
        for edge in contour.vertices.indices {
            let length = edgeLength(edge, contour)
            longFrames[edge] = length > policy.splitLength ? longFrames[edge] + 1 : 0
            shortFrames[edge] = length < policy.mergeLength ? shortFrames[edge] + 1 : 0
        }
        if let edge = longFrames.firstIndex(where: { $0 >= policy.persistenceFrames }) {
            cooldown = policy.cooldownFrames
            return RemeshPlan(actions: [.split(edgeIndex: edge)], resultingVertexCount: contour.vertices.count + 1)
        }
        if contour.vertices.count > 8, let edge = shortFrames.firstIndex(where: { $0 >= policy.persistenceFrames }) {
            cooldown = policy.cooldownFrames
            return RemeshPlan(actions: [.merge(edgeIndex: edge)], resultingVertexCount: contour.vertices.count - 1)
        }
        return RemeshPlan(actions: [], resultingVertexCount: contour.vertices.count)
    }

    public mutating func applying(_ plan: RemeshPlan, to contour: AdaptiveContour) -> AdaptiveContour {
        guard let action = plan.actions.first else { return contour }
        var result = contour
        switch action {
        case let .split(edge):
            let next = (edge + 1) % result.vertices.count
            let start = result.vertices[edge], end = result.vertices[next]
            let vertex = AdaptiveContourVertex(
                position: (start.position + end.position) * 0.5,
                previousPosition: (start.previousPosition + end.previousPosition) * 0.5
            )
            let insertion = next == 0 ? result.vertices.count : next
            result.vertices.insert(vertex, at: insertion)
            let halfRest = result.restLengths[edge] * 0.5
            let doubledScale = result.stiffnessScales[edge] * 2
            result.restLengths[edge] = halfRest
            result.restLengths.insert(halfRest, at: insertion)
            result.stiffnessScales[edge] = doubledScale
            result.stiffnessScales.insert(doubledScale, at: insertion)
        case let .merge(edge):
            guard result.vertices.count > 8 else { return contour }
            let removed = (edge + 1) % result.vertices.count
            let followingEdge = removed
            result.restLengths[edge] += result.restLengths[followingEdge]
            result.stiffnessScales[edge] = min(result.stiffnessScales[edge], result.stiffnessScales[followingEdge]) * 0.5
            result.vertices.remove(at: removed)
            result.restLengths.remove(at: followingEdge)
            result.stiffnessScales.remove(at: followingEdge)
        }
        longFrames = []
        shortFrames = []
        return result
    }

    private mutating func synchronizeCounters(count: Int) {
        if longFrames.count != count {
            longFrames = Array(repeating: 0, count: count)
            shortFrames = Array(repeating: 0, count: count)
        }
    }

    private func edgeLength(_ edge: Int, _ contour: AdaptiveContour) -> Float {
        let delta = contour.vertices[(edge + 1) % contour.vertices.count].position - contour.vertices[edge].position
        return sqrt(delta.dot(delta))
    }
}
