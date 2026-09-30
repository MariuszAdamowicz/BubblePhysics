enum EndpointKind: Int, Comparable {
    case minimum = 0
    case maximum = 1

    static func < (left: EndpointKind, right: EndpointKind) -> Bool {
        left.rawValue < right.rawValue
    }
}

struct Endpoint: Comparable {
    let bubbleID: BubbleID
    let coordinate: Float
    let kind: EndpointKind

    static func < (left: Endpoint, right: Endpoint) -> Bool {
        if left.coordinate != right.coordinate { return left.coordinate < right.coordinate }
        if left.kind != right.kind { return left.kind < right.kind }
        return left.bubbleID < right.bubbleID
    }
}

struct EndpointIndex {
    private(set) var endpoints: [Endpoint] = []

    mutating func upsert(_ bubbleID: BubbleID, minimum: Float, maximum: Float) {
        remove(bubbleID)
        insert(Endpoint(bubbleID: bubbleID, coordinate: minimum, kind: .minimum))
        insert(Endpoint(bubbleID: bubbleID, coordinate: maximum, kind: .maximum))
    }

    mutating func remove(_ bubbleID: BubbleID) {
        endpoints.removeAll { $0.bubbleID == bubbleID }
    }

    func overlappingPairs() -> Set<BubblePair> {
        var active: [BubbleID] = []
        var pairs: Set<BubblePair> = []
        for endpoint in endpoints {
            switch endpoint.kind {
            case .minimum:
                for other in active { pairs.insert(BubblePair(endpoint.bubbleID, other)) }
                active.append(endpoint.bubbleID)
                active.sort()
            case .maximum:
                active.removeAll { $0 == endpoint.bubbleID }
            }
        }
        return pairs
    }

    private mutating func insert(_ endpoint: Endpoint) {
        let offset = endpoints.partitioningIndex { $0 >= endpoint }
        endpoints.insert(endpoint, at: offset)
    }
}

private extension Array where Element: Comparable {
    func partitioningIndex(where belongsAfter: (Element) -> Bool) -> Int {
        var lower = startIndex
        var upper = endIndex
        while lower < upper {
            let middle = index(lower, offsetBy: distance(from: lower, to: upper) / 2)
            if belongsAfter(self[middle]) {
                upper = middle
            } else {
                lower = index(after: middle)
            }
        }
        return lower
    }
}
