public enum TimeOfImpactResult: Sendable, Equatable {
    case none
    case initialOverlap(normal: ReferenceVector2, point: ReferenceVector2)
    case impact(fraction: Float, normal: ReferenceVector2, point: ReferenceVector2)
}

public enum ReferenceCCD {}
