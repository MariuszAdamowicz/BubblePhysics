import BubblePhysicsModel

/// Wejście semantycznej operacji: GPU pobiera kontur źródła z poprzedniej publikacji.
/// Dla źródła utworzonego w tej samej transakcji używa koła lub odziedziczonych części.
package struct NativeStructuralSource: Equatable, Sendable {
    package var id: ObjectID
    package var center: WorldPoint
    package var radius: Float
    /// Półpłaszczyzny n·p <= d, we współrzędnych świata.
    package var clips: [SIMD4<Float>] = []
    package init(id: ObjectID, center: WorldPoint, radius: Float) {
        self.id = id; self.center = center; self.radius = radius
    }
}
package struct NativeStructuralShape: Equatable, Sendable {
    package var origin: WorldPoint
    package var sources: [NativeStructuralSource]
    package init(origin: WorldPoint, sources: [NativeStructuralSource]) {
        self.origin = origin; self.sources = sources
    }
}

struct NativeStructuralHeader {
    var range: SIMD4<UInt32>
    var origin: SIMD4<Float>
}
struct NativeStructuralSourceRecord {
    var identity: SIMD2<UInt64>
    var geometry: SIMD4<Float>
    var clips: SIMD4<UInt32>
}
