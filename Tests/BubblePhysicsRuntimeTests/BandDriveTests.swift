import BubblePhysics
import XCTest

/// P-B-1 – P-B-4 i P-B-8 (G1-AC1 – G1-AC4, G1-AC6): gumka siłowa `BubbleDrivePolicy.bandStiffness` przez publiczny świat.
///
/// Chwycona bańka dostaje siłę F = K_band · (cel − położenie), obciętą do `maximumForce`; prędkość wynika z siły i masy,
/// a nie jest narzucana. Tłumienie ruchu to tylko materiał γ (`damping`, tempo w 1/s); gumka nie tłumi.
/// Od silnika 4.0.0 gumka liczy się w każdym podkroku z bieżącego położenia (G4-AC4), więc naciągnięcie w kroku maleje o drogę bańki,
/// a jedyną stratą kontaktu ze ścianą jest γ materiału (bez tłumienia kontaktu). Sceny bez kontaktów stoją w środku ram sceny tłoku,
/// daleko od ścian. Krok stały 1/60.
@MainActor
final class BandDriveTests: XCTestCase {
    private let dt = CrowdScene.step
    private let radius: Float = 10

    private func world(material: PhysicsMaterial) throws -> (BubbleWorld, WorldTransaction) {
        let world = try BubbleWorld(configuration: CrowdScene.configuration())
        var setup = try CrowdScene.resources(bubble: material)
        for wall in try CrowdScene.walls() { setup = setup.add(wall) }
        return (world, setup)
    }

    private func speed(_ state: ObjectState) -> Float { (state.velocity.x * state.velocity.x + state.velocity.y * state.velocity.y).squareRoot() }

    /// Prędkość ustalona bańki ciągniętej ze stałym naciągnięciem s wzdłuż +x: cel jest przesuwany co krok tak, by naciągnięcie
    /// zostało równe s (G1-AC1). Zwraca prędkość po `seconds` oraz maksimum prędkości z całego przebiegu.
    private func steadyState(mass: Float, damping: Float, policy: BubbleDrivePolicy, stretch: Float,
                             seconds: Double = 4) async throws -> (speed: Float, peak: Float) {
        let (world, base) = try world(material: CrowdScene.bubblePhysics(damping: damping))
        let start = WorldPoint(-150, 0)
        _ = world.submit(try base
            .add(CrowdScene.bubble(1, at: start, radius: radius, mass: mass, drivePolicy: policy))
            .beginPlayerDrive(CrowdScene.id(1), target: start + WorldPoint(stretch, 0)))
        var last: ObjectState?, peak: Float = 0
        for index in 0..<Int((seconds / dt).rounded()) {
            let frame = await world.advance(by: dt)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue, "krok \(index)")
            let state = try XCTUnwrap(frame.objects[CrowdScene.id(1)])
            peak = max(peak, speed(state))
            last = state
            let achieved = try XCTUnwrap(frame.driveFeedback.first).achievedPoint
            _ = world.submit(WorldTransaction().updatePlayerDrive(CrowdScene.id(1), target: achieved + WorldPoint(stretch, 0)))
        }
        return (speed(try XCTUnwrap(last)), peak)
    }

    /// Prędkość ustalona przy naciągnięciu s liczonym od położenia na początku kroku (cel przesuwany co krok): w kroku bańka jedzie
    /// z v, więc średnie naciągnięcie to s − v · dt / 2, a opór γ i siła składają się dokładnie (półimpulsy). Z v = v e^(−γ dt) +
    /// (K / m) (s − v dt / 2) (1 − e^(−γ dt)) / γ wynika v = k s f / (1 − e^(−γ dt) + k f dt / 2), k = K / m, f = (1 − e^(−γ dt)) / γ.
    /// Dla dt → 0 to K · s / (m · γ).
    private func steadySpeed(stiffness: Float, stretch: Float, mass: Float, gamma: Float) -> Float {
        let decay = exp(-gamma * Float(dt)), f = (1 - decay) / gamma, k = stiffness / mass
        return k * stretch * f / (1 - decay + k * f * Float(dt) / 2)
    }

    /// P-B-1: v = K · s / (m · γ) z poprawką na średnie naciągnięcie w kroku (3 %), poniżej `maximumLinearSpeed` (600).
    func testSteadySpeedIsStiffnessTimesStretchOverMassTimesMaterialDamping() async throws {
        let stiffness: Float = 60, stretch: Float = 1, mass: Float = 1, gamma: Float = 2
        let policy = try BubbleDrivePolicy(bandStiffness: stiffness)
        let a = try await steadyState(mass: mass, damping: gamma, policy: policy, stretch: stretch)
        let expected = steadySpeed(stiffness: stiffness, stretch: stretch, mass: mass, gamma: gamma)
        XCTAssertEqual(expected, stiffness * stretch / (mass * gamma), accuracy: 0.25 * stiffness * stretch / (mass * gamma), "poprawka jest niewielka")
        XCTAssertEqual(a.speed, expected, accuracy: 0.03 * expected)
        XCTAssertLessThan(a.peak, 600)
    }

    /// P-B-2: stosunek prędkości ustalonych to odwrotność stosunku mas (z poprawką na średnie naciągnięcie), w osobnych światach.
    func testSteadySpeedRatioIsTheInverseOfTheMassRatio() async throws {
        let policy = try BubbleDrivePolicy(bandStiffness: 60)
        let light = try await steadyState(mass: 1, damping: 2, policy: policy, stretch: 1)
        let heavy = try await steadyState(mass: 2.5, damping: 2, policy: policy, stretch: 1)
        let expected = steadySpeed(stiffness: 60, stretch: 1, mass: 1, gamma: 2) / steadySpeed(stiffness: 60, stretch: 1, mass: 2.5, gamma: 2)
        XCTAssertEqual(light.speed / heavy.speed, expected, accuracy: 0.05 * expected)
        XCTAssertGreaterThan(expected, 2, "ciężka bańka jedzie wyraźnie wolniej")
        XCTAssertGreaterThan(heavy.speed, 1)
    }

    // MARK: ściana (P-B-3)

    private struct Rest {
        var depth: Float
        var stretch: Float
        var speed: Float
    }

    /// Sztywność kontaktu K_c bańki przy lewej ścianie (materiał miękki: K_c = r_ref / c₀ = 20 / 0,01) i opór γ, który jako jedyny gasi
    /// drgania bańki o ścianę (kontakt nie tłumi).
    private let wallStiffnessKc: Float = 2000, wallDamping: Float = 4

    /// Bańka z K_c przy lewej ścianie, ciągnięta w nią gumką `K` z limitem `maximumForce`; stan po 6 s.
    private func pressedAgainstTheWall(stretch: Float) async throws -> Rest {
        let (world, base) = try world(material: CrowdScene.softBubblePhysics(base: 0.01, damping: wallDamping))
        let policy = try BubbleDrivePolicy(bandStiffness: 10, maximumForce: 300)
        _ = world.submit(try CrowdScene.bandPressedBubble(base, 1, y: 0, radius: 20, stretch: stretch, policy: policy))
        var frame = await world.advance(by: dt)
        for index in 0..<360 {
            frame = await world.advance(by: dt)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue, "krok \(index)")
        }
        let state = try XCTUnwrap(frame.objects[CrowdScene.id(1)])
        let feedback = try XCTUnwrap(frame.driveFeedback.first)
        return Rest(depth: CrowdScene.wallDepth(of: state, targetRadius: 20), stretch: abs(feedback.target.x - feedback.achievedPoint.x),
                    speed: speed(state))
    }

    /// P-B-3 (G1-AC3): poniżej granicy `maximumForce` / K siła kontaktu z prawa F = K_c · ε / (1 − ε)² (ε = ugięcie / r) równa się
    /// K · s (10 %); powyżej niej położenie równowagi jest to samo (0,5 jedn.), bo siła jest obcięta do `maximumForce`.
    func testWallPressMatchesTheBandForceBelowTheLimitAndSaturatesAboveIt() async throws {
        let stiffness: Float = 10, maximumForce: Float = 300
        func contactForce(_ rest: Rest) -> Float {
            Float(ContactLawReference.force(epsilon: Double(rest.depth / 20), stiffness: Double(wallStiffnessKc)))
        }
        for stretch: Float in [6, 15, 24] {
            let rest = try await pressedAgainstTheWall(stretch: stretch)
            XCTAssertLessThan(rest.speed, 0.1, "s = \(stretch): bańka stoi")
            let expected = stiffness * rest.stretch
            XCTAssertEqual(contactForce(rest), expected, accuracy: 0.1 * expected, "s = \(stretch)")
        }
        var saturated: [Float] = []
        for stretch: Float in [45, 90] {
            let rest = try await pressedAgainstTheWall(stretch: stretch)
            XCTAssertLessThan(rest.speed, 0.1, "s = \(stretch): bańka stoi")
            XCTAssertEqual(contactForce(rest), maximumForce, accuracy: 0.1 * maximumForce, "s = \(stretch)")
            saturated.append(rest.depth)
        }
        XCTAssertEqual(saturated[0], saturated[1], accuracy: 0.5)
    }

    // MARK: puszczenie (P-B-4)

    /// P-B-4 (G1-AC4): po `endPlayerDrive` bańka zachowuje prędkość z ostatniego kroku napędu i leci dalej (hamuje ją tylko
    /// tłumienie materiału, tu zerowe; bez tłumienia bańka przyspiesza, więc pętla jest krótka).
    func testReleasingTheDriveKeepsTheVelocity() async throws {
        let (world, base) = try world(material: CrowdScene.bubblePhysics(damping: 0))
        let policy = try BubbleDrivePolicy(bandStiffness: 60)
        let start = WorldPoint(-150, 0)
        _ = world.submit(try base
            .add(CrowdScene.bubble(1, at: start, radius: radius, mass: 1, drivePolicy: policy))
            .beginPlayerDrive(CrowdScene.id(1), target: start + WorldPoint(1, 0)))
        var before: ObjectState?
        for _ in 0..<60 {
            let frame = await world.advance(by: dt)
            before = try XCTUnwrap(frame.objects[CrowdScene.id(1)])
            let achieved = try XCTUnwrap(frame.driveFeedback.first).achievedPoint
            _ = world.submit(WorldTransaction().updatePlayerDrive(CrowdScene.id(1), target: achieved + WorldPoint(1, 0)))
        }
        let speedBefore = speed(try XCTUnwrap(before))
        XCTAssertGreaterThan(speedBefore, 5, "bańka jedzie")
        _ = world.submit(WorldTransaction().endPlayerDrive(CrowdScene.id(1)))
        let release = await world.advance(by: dt)
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
        let afterRelease = try XCTUnwrap(release.objects[CrowdScene.id(1)])
        XCTAssertEqual(afterRelease.velocity.x, speedBefore, accuracy: 0.01 * speedBefore, "ramka puszczenia")
        XCTAssertTrue(release.driveFeedback.isEmpty)
        var later = release
        for _ in 0..<30 { later = await world.advance(by: dt) }
        XCTAssertEqual(try XCTUnwrap(later.objects[CrowdScene.id(1)]).velocity.x, speedBefore, accuracy: 0.01 * speedBefore,
                       "pół sekundy po puszczeniu")
    }

    // MARK: ramki (P-B-8)

    /// P-B-8 (G1-AC6): γ = 0, cel stały, jeden krok na ramkę, bez kontaktów: Δv między ramkami N i N+1 równa się
    /// K · (target − achievedPoint) / m · dt, z `DriveFeedback` ramki N.
    func testVelocityChangeBetweenFramesFollowsTheFeedbackStretch() async throws {
        let (world, base) = try world(material: CrowdScene.bubblePhysics(damping: 0))
        let stiffness: Float = 30, mass: Float = 2
        let policy = try BubbleDrivePolicy(bandStiffness: stiffness)
        _ = world.submit(try base
            .add(CrowdScene.bubble(1, at: .zero, radius: radius, mass: mass, drivePolicy: policy))
            .beginPlayerDrive(CrowdScene.id(1), target: [20, 12]))
        var previous = await world.advance(by: dt)
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
        for index in 0..<4 {
            let next = await world.advance(by: dt)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue)
            let feedback = try XCTUnwrap(previous.driveFeedback.first)
            let expected = (feedback.target - feedback.achievedPoint) * (stiffness / mass * Float(dt))
            let delta = try XCTUnwrap(next.objects[CrowdScene.id(1)]).velocity - XCTUnwrap(previous.objects[CrowdScene.id(1)]).velocity
            XCTAssertEqual(delta.x, expected.x, accuracy: 0.01 * abs(expected.x), "ramka \(index) x")
            XCTAssertEqual(delta.y, expected.y, accuracy: 0.01 * abs(expected.y), "ramka \(index) y")
            previous = next
        }
    }
}
