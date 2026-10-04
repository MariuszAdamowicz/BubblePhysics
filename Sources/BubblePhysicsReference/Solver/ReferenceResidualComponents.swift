public struct ReferenceResidualComponentSummary: Sendable, Equatable {
    public var componentCount: Int
    public var unconvergedCount: Int
    public var maximumNorm: Float

    public init(componentCount: Int, unconvergedCount: Int, maximumNorm: Float) {
        self.componentCount = componentCount
        self.unconvergedCount = unconvergedCount
        self.maximumNorm = maximumNorm
    }
}

enum ReferenceResidualComponents {
    static func improvingBubbleIndices(
        current: [ReferenceVector2],
        trial: [ReferenceVector2],
        contacts: [ReferenceContact],
        indices: [ReferenceBubbleID: Int]
    ) -> Set<Int> {
        precondition(current.count == trial.count)
        let parent = partition(count: current.count, contacts: contacts, indices: indices)

        var currentScores: [Int: Float] = [:]
        var trialScores: [Int: Float] = [:]
        for index in current.indices {
            let component = root(of: index, parent: parent)
            currentScores[component, default: 0] += current[index].lengthSquared
            trialScores[component, default: 0] += trial[index].lengthSquared
        }

        let improvingComponents = Set(currentScores.compactMap { component, score in
            let candidate = trialScores[component, default: .infinity]
            return candidate.isFinite && candidate < score ? component : nil
        })
        return Set(current.indices.filter {
            improvingComponents.contains(root(of: $0, parent: parent))
        })
    }

    static func summary(
        residual: [ReferenceVector2],
        contacts: [ReferenceContact],
        indices: [ReferenceBubbleID: Int],
        tolerance: Float
    ) -> ReferenceResidualComponentSummary {
        guard !contacts.isEmpty else {
            return .init(componentCount: 0, unconvergedCount: 0, maximumNorm: 0)
        }
        let parent = partition(count: residual.count, contacts: contacts, indices: indices)
        let contacted = Set(contacts.compactMap { indices[$0.bubbleA] }
            + contacts.compactMap { $0.bubbleB.flatMap { indices[$0] } })
        var squaredNorms: [Int: Float] = [:]
        for index in contacted where residual.indices.contains(index) {
            squaredNorms[root(of: index, parent: parent), default: 0] += residual[index].lengthSquared
        }
        let norms = squaredNorms.values.map { max(0, $0).squareRoot() }
        let threshold = tolerance.isFinite ? max(0, tolerance) : 0
        return .init(
            componentCount: norms.count,
            unconvergedCount: norms.filter { !$0.isFinite || $0 > threshold }.count,
            maximumNorm: norms.filter { $0.isFinite }.max() ?? (norms.isEmpty ? 0 : .infinity)
        )
    }

    private static func partition(
        count: Int,
        contacts: [ReferenceContact],
        indices: [ReferenceBubbleID: Int]
    ) -> [Int] {
        var parent = Array(0..<count)
        for contact in contacts {
            guard let bubbleB = contact.bubbleB,
                  let indexA = indices[contact.bubbleA],
                  let indexB = indices[bubbleB],
                  parent.indices.contains(indexA), parent.indices.contains(indexB) else { continue }
            let rootA = root(of: indexA, parent: parent)
            let rootB = root(of: indexB, parent: parent)
            if rootA != rootB { parent[rootB] = rootA }
        }
        return parent
    }

    private static func root(of start: Int, parent: [Int]) -> Int {
        var value = start
        while parent[value] != value { value = parent[value] }
        return value
    }
}
