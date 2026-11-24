import Foundation
import simd

/// Odniesienie w Double dla testów świata silnika 4.0.0 (`docs/sdlc/changes/2026-11-23-engine-4-0-0`).
/// Liczy to, co silnik liczy w float32 na GPU: prawo kontaktu F = K · ε / (1 − ε)², jego odwrotność, energię U(ε),
/// równowagę d*, parę różnych materiałów, regułę podkroku h w jednym wymiarze i trajektorię pola radialnego.
/// Nie zna silnika ani modelu, więc sprawdza go niezależnie. Własne testy: `ContactLawReferenceTests`.
///
/// Zapis: ε = x / r to ugięcie względne, q = F / K, d to odległość środka bańki od powierzchni przeszkody.
enum ContactLawReference {
    // MARK: Prawo kontaktu

    /// F = K · ε / (1 − ε)². Dla ε ≤ 0 siła jest zerem (kontakt nie ciągnie).
    static func force(epsilon: Double, stiffness: Double) -> Double {
        guard epsilon > 0 else { return 0 }
        return stiffness * epsilon / ((1 - epsilon) * (1 - epsilon))
    }

    /// Rozwiązanie ε / (1 − ε)² = q w (0, 1). Postać bez kasowania się składników dla małych i dużych q:
    /// ε = 2q / ((2q + 1) + √(4q + 1)).
    static func epsilon(forForceRatio q: Double) -> Double {
        guard q > 0 else { return 0 }
        return 2 * q / ((2 * q + 1) + (4 * q + 1).squareRoot())
    }

    /// U(ε) = ∫₀^(rε) F dx = K · r · (1/(1 − ε) + ln(1 − ε) − 1).
    static func energy(epsilon: Double, stiffness: Double, radius: Double) -> Double {
        guard epsilon > 0 else { return 0 }
        // 1/(1 − ε) − 1 = ε/(1 − ε); log1p daje ln(1 − ε) bez utraty cyfr przy małym ε.
        return stiffness * radius * (epsilon / (1 - epsilon) + log1p(-epsilon))
    }

    /// d* = r · (1 − ε*), gdzie ε* rozwiązuje ε / (1 − ε)² = F / K.
    static func equilibriumDistance(force: Double, stiffness: Double, radius: Double) -> Double {
        radius * (1 - epsilon(forForceRatio: force / stiffness))
    }

    /// ε_max z bilansu energii U(ε_max) = E (bisekcja, U rośnie monotonicznie od 0 do ∞).
    static func maximumEpsilon(energy target: Double, stiffness: Double, radius: Double) -> Double {
        guard target > 0 else { return 0 }
        var low = 0.0, high = 1.0
        for _ in 0..<200 {
            let mid = 0.5 * (low + high)
            if energy(epsilon: mid, stiffness: stiffness, radius: radius) < target { low = mid } else { high = mid }
        }
        return 0.5 * (low + high)
    }

    // MARK: Para

    struct PairBody {
        var radius: Double
        var stiffness: Double
    }

    struct PairContact {
        /// Wspólna siła kontaktu pary.
        var force: Double
        var epsilonA: Double
        var epsilonB: Double
        /// Wgniecenie każdej bańki r · ε; suma równa się nakładaniu.
        var deflectionA: Double
        var deflectionB: Double
    }

    /// Para o nakładaniu δ = r_a + r_b − (odległość środków): rozwiązanie r_a ε(F/K_a) + r_b ε(F/K_b) = δ względem F
    /// (bisekcja po F, dokładność Double). `nil`, gdy δ < 0 albo δ ≥ r_a + r_b (środki w jednym punkcie lub dalej).
    static func pairContact(overlap: Double, a: PairBody, b: PairBody) -> PairContact? {
        guard overlap >= 0, overlap < a.radius + b.radius else { return nil }
        func sum(_ f: Double) -> Double {
            a.radius * epsilon(forForceRatio: f / a.stiffness) + b.radius * epsilon(forForceRatio: f / b.stiffness)
        }
        var low = 0.0, high = max(a.stiffness, b.stiffness)
        while sum(high) < overlap { high *= 2 }
        for _ in 0..<400 {
            let mid = 0.5 * (low + high)
            if sum(mid) < overlap { low = mid } else { high = mid }
        }
        let f = overlap == 0 ? 0 : 0.5 * (low + high)
        let ea = epsilon(forForceRatio: f / a.stiffness), eb = epsilon(forForceRatio: f / b.stiffness)
        return PairContact(force: f, epsilonA: ea, epsilonB: eb, deflectionA: a.radius * ea, deflectionB: b.radius * eb)
    }

    // MARK: Reguła h, symulacja 1D (bańka i ściana)

    /// Bańka prostopadle do ściany. `distance` to odległość środka od powierzchni ściany, `velocity` dodatnia oddala od ściany.
    /// Kontakt działa dla d < r. Reguła podkroku w każdej chwili: h = min(czas do końca kroku, 1/ω, d / (4 |v|)),
    /// gdzie ω² = (k + K_band) / m, a k = dF/dx = K · (1 + ε) / ((1 − ε)³ · r) (tylko w kontakcie).
    /// Całkowanie leapfrog (½ impulsu, ruch, siły, ½ impulsu); siła oporu −γ · m · v.
    struct WallScene {
        var radius: Double
        var mass: Double
        var stiffness: Double
        var damping: Double
        var startDistance: Double
        var velocity: Double
        /// Stała siła dociskająca do ściany (G5-AC2: F = 20 000); zero, gdy brak.
        var pressForce: Double = 0
        /// Dodatkowa sztywność gumki, wchodzi tylko do ω (siła gumki nie jest tu liczona).
        var bandStiffness: Double = 0
        var frameStep: Double = 1.0 / 60
        var maximumSubstepsPerFrame: Int = 1024

        struct Frame {
            var substeps: Int
            var distance: Double
            var velocity: Double
        }

        struct Substep {
            /// Stan po podkroku: odległość, prędkość i prędkość w połowie podkroku (do całki oporu).
            var distance: Double
            var velocity: Double
            var midVelocity: Double
            var h: Double
            /// min(dt, 1/ω, d / (4 |v|)) z początku podkroku; h to ten limit albo reszta kroku.
            var limit: Double
        }

        struct Trace {
            var frames: [Frame] = []
            var substeps: [Substep] = []
            /// Któraś klatka potrzebowała więcej podkroków niż limit; przebieg kończy się na niej.
            var limitExceeded = false
            /// Środek doszedł do powierzchni ściany (d ≤ 0); przebieg kończy się w tym podkroku.
            var penetrated = false
        }

        func contactForce(distance: Double) -> Double {
            force(epsilon: 1 - distance / radius, stiffness: stiffness)
        }

        /// Energia kinetyczna, sprężysta kontaktu i potencjał stałej siły dociskającej (dla d ≥ 0).
        func energy(distance: Double, velocity: Double) -> Double {
            0.5 * mass * velocity * velocity
                + ContactLawReference.energy(epsilon: 1 - distance / radius, stiffness: stiffness, radius: radius)
                + pressForce * distance
        }

        private func acceleration(distance: Double, velocity: Double) -> Double {
            (contactForce(distance: distance) - pressForce) / mass - damping * velocity
        }

        private func substepLimit(distance: Double, velocity: Double) -> Double {
            var bound = frameStep
            var k = bandStiffness
            let epsilon = 1 - distance / radius
            if epsilon > 0 { k += stiffness * (1 + epsilon) / (pow(1 - epsilon, 3) * radius) }
            if k > 0 { bound = min(bound, 1 / (k / mass).squareRoot()) }
            if velocity != 0 { bound = min(bound, distance / (4 * abs(velocity))) }
            return bound
        }

        func run(frames: Int) -> Trace {
            var trace = Trace()
            var s = startDistance, v = velocity
            for _ in 0..<frames {
                var remaining = frameStep, count = 0
                while remaining > 0 {
                    if count == maximumSubstepsPerFrame { trace.limitExceeded = true; break }
                    let limit = substepLimit(distance: s, velocity: v)
                    let h = min(remaining, limit)
                    remaining = h >= remaining ? 0 : remaining - h
                    let a0 = acceleration(distance: s, velocity: v)
                    let half = v + 0.5 * h * a0
                    s += h * half
                    if s <= 0 { trace.penetrated = true; count += 1; break }
                    v = half + 0.5 * h * acceleration(distance: s, velocity: half)
                    trace.substeps.append(Substep(distance: s, velocity: v, midVelocity: half, h: h, limit: limit))
                    count += 1
                }
                trace.frames.append(Frame(substeps: count, distance: s, velocity: v))
                if trace.limitExceeded || trace.penetrated { break }
            }
            return trace
        }
    }

    // MARK: Pole radialne

    /// Pole radialne w kole o środku w początku układu; wzór jak w silniku (`MotionControllers.fieldForce`):
    /// siła = strength · (1 − d/R)^falloff w kierunku od środka (ujemna strength przyciąga), falloff 0 to stała siła,
    /// poza zasięgiem i w samym środku siła jest zerem.
    struct RadialField {
        var strength: Double
        var falloff: Double
        var radius: Double

        func force(at point: SIMD2<Double>) -> SIMD2<Double> {
            let distance = simd_length(point)
            guard distance > 0, distance <= radius else { return .zero }
            let profile = falloff == 0 ? 1 : pow(max(0, 1 - distance / radius), falloff)
            return point * (strength * profile / distance)
        }
    }

    /// Całkowanie RK4 ruchu bańki w polu radialnym (bez kontaktów) z oporem −γ · v; krok `step`, czas `duration`.
    static func integrateRadialField(_ field: RadialField, mass: Double, damping: Double, position: SIMD2<Double>,
                                     velocity: SIMD2<Double>, duration: Double, step: Double)
        -> (position: SIMD2<Double>, velocity: SIMD2<Double>) {
        func derivative(_ p: SIMD2<Double>, _ v: SIMD2<Double>) -> (SIMD2<Double>, SIMD2<Double>) {
            (v, field.force(at: p) / mass - damping * v)
        }
        var p = position, v = velocity
        let count = Int((duration / step).rounded())
        for _ in 0..<count {
            let (k1p, k1v) = derivative(p, v)
            let (k2p, k2v) = derivative(p + 0.5 * step * k1p, v + 0.5 * step * k1v)
            let (k3p, k3v) = derivative(p + 0.5 * step * k2p, v + 0.5 * step * k2v)
            let (k4p, k4v) = derivative(p + step * k3p, v + step * k3v)
            let sumP: SIMD2<Double> = k1p + 2 * k2p + 2 * k3p + k4p
            let sumV: SIMD2<Double> = k1v + 2 * k2v + 2 * k3v + k4v
            p += (step / 6) * sumP
            v += (step / 6) * sumV
        }
        return (p, v)
    }
}
