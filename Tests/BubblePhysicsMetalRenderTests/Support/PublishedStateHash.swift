import BubblePhysics

/// Hash bitów opublikowanego stanu świata (FNV-1a po bajtach liczb), wspólny dla testów determinizmu i równoważności.
/// Hashuje wzorce bitów, więc różnica o 1 ULP zostaje wykryta.
enum PublishedStateHash {
    static let offsetBasis: UInt64 = 0xCBF2_9CE4_8422_2325

    static func fnv1a(_ values: some Sequence<UInt32>, into hash: inout UInt64) {
        for value in values {
            for shift in stride(from: 0, to: 32, by: 8) {
                hash = (hash ^ UInt64((value >> UInt32(shift)) & 0xFF)) &* 0x100_0000_01B3
            }
        }
    }

    /// Hash bitów stanu wszystkich obiektów klatki (bańki i bryły: pozycja, prędkość, obrót, prędkość kątowa,
    /// AABB, promień), posortowanych po `ObjectID`.
    static func objects(_ frame: WorldFrame) -> UInt64 {
        var objectHash = offsetBasis
        for id in frame.objects.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let object = frame.objects[id] else { continue }
            let kind: [UInt32]
            switch object.kind {
            case .bubble(let radius): kind = [1, radius.bitPattern]
            case .polygon: kind = [2, 0]
            case .circle(let radius): kind = [3, radius.bitPattern]
            case .capsule(let halfLength, let radius): kind = [4, halfLength.bitPattern, radius.bitPattern]
            }
            fnv1a([UInt32(truncatingIfNeeded: id.rawValue), UInt32(truncatingIfNeeded: id.rawValue >> 32)] + kind
                + [object.position.x, object.position.y, object.velocity.x, object.velocity.y,
                   object.rotation, object.angularVelocity,
                   object.bounds.min.x, object.bounds.min.y, object.bounds.max.x, object.bounds.max.y]
                    .map(\.bitPattern), into: &objectHash)
        }
        return objectHash
    }

    /// Hash punktów konturów baniek (`BubbleWorld.debugContourSnapshot()`), posortowanych po `ObjectID`.
    static func contours(_ snapshot: [ObjectID: [WorldPoint]]) -> UInt64 {
        var hash = offsetBasis
        for id in snapshot.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            fnv1a([UInt32(truncatingIfNeeded: id.rawValue)], into: &hash)
            for point in snapshot[id] ?? [] { fnv1a([point.x.bitPattern, point.y.bitPattern], into: &hash) }
        }
        return hash
    }
}
