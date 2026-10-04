public struct ReferencePCGResult: Sendable, Equatable {
    public var solution: [ReferenceVector2]
    public var iterationCount: Int
    public var initialResidualNorm: Float
    public var finalResidualNorm: Float
    public var hasNonFiniteState: Bool
}

public enum ReferencePCGSolver {
    public static func solve(
        rightHandSide: [ReferenceVector2],
        apply: ([ReferenceVector2]) -> [ReferenceVector2],
        inverseDiagonal: [ReferenceVector2],
        tolerance: Float,
        iterationLimit: Int
    ) -> ReferencePCGResult {
        var solution = Array(repeating: ReferenceVector2.zero, count: rightHandSide.count)
        var residual = rightHandSide
        let initialNorm = norm(residual)
        guard initialNorm.isFinite, initialNorm > Float.ulpOfOne else {
            return .init(solution: solution, iterationCount: 0, initialResidualNorm: initialNorm.isFinite ? initialNorm : 0,
                         finalResidualNorm: initialNorm.isFinite ? initialNorm : 0, hasNonFiniteState: !initialNorm.isFinite)
        }
        var preconditioned = multiply(residual, inverseDiagonal)
        var direction = preconditioned
        var rz = dot(residual, preconditioned)
        var iterations = 0
        var nonFinite = false
        let threshold = max(0, tolerance) * initialNorm

        while iterations < max(0, iterationLimit) {
            let applied = apply(direction)
            let denominator = dot(direction, applied)
            guard denominator.isFinite, denominator > Float.ulpOfOne, rz.isFinite else { nonFinite = !denominator.isFinite || !rz.isFinite; break }
            let alpha = rz / denominator
            solution = add(solution, direction, scale: alpha)
            residual = add(residual, applied, scale: -alpha)
            iterations += 1
            let currentNorm = norm(residual)
            guard currentNorm.isFinite else { nonFinite = true; break }
            if currentNorm <= threshold { break }
            preconditioned = multiply(residual, inverseDiagonal)
            let nextRZ = dot(residual, preconditioned)
            guard nextRZ.isFinite else { nonFinite = true; break }
            direction = add(preconditioned, direction, scale: nextRZ / rz)
            rz = nextRZ
        }
        return .init(solution: solution, iterationCount: iterations, initialResidualNorm: initialNorm,
                     finalResidualNorm: norm(residual), hasNonFiniteState: nonFinite || solution.contains { !$0.isFinite })
    }

    private static func multiply(_ a: [ReferenceVector2], _ b: [ReferenceVector2]) -> [ReferenceVector2] {
        zip(a, b).map { .init(x: $0.x * $1.x, y: $0.y * $1.y) }
    }
    private static func add(_ a: [ReferenceVector2], _ b: [ReferenceVector2], scale: Float) -> [ReferenceVector2] {
        zip(a, b).map { $0 + $1 * scale }
    }
    private static func dot(_ a: [ReferenceVector2], _ b: [ReferenceVector2]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0.dot($1.1) }
    }
    private static func norm(_ vector: [ReferenceVector2]) -> Float { max(0, dot(vector, vector)).squareRoot() }
}
