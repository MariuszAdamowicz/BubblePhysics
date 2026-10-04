enum ReferenceResidualComponents {
    static func improvingBubbleIndices(
        current: [ReferenceVector2],
        trial: [ReferenceVector2],
        contacts: [ReferenceContact],
        indices: [ReferenceBubbleID: Int]
    ) -> Set<Int> {
        precondition(current.count == trial.count)
        var parent = Array(current.indices)

        func root(of start: Int, parent: [Int]) -> Int {
            var value = start
            while parent[value] != value { value = parent[value] }
            return value
        }

        for contact in contacts {
            guard let bubbleB = contact.bubbleB,
                  let indexA = indices[contact.bubbleA],
                  let indexB = indices[bubbleB] else { continue }
            let rootA = root(of: indexA, parent: parent)
            let rootB = root(of: indexB, parent: parent)
            if rootA != rootB { parent[rootB] = rootA }
        }

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
}
