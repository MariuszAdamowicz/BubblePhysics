import BubblePhysics
import XCTest

/// P-B-1 – P-B-4 i P-B-8 (G1-AC1 – G1-AC4, G1-AC6): gumka siłowa `BubbleDrivePolicy.bandStiffness` przez publiczny świat.
///
/// Chwycona bańka dostaje siłę F = K_band · (cel − położenie), obciętą do `maximumForce`; prędkość wynika z siły i masy,
/// a nie jest narzucana. Tłumienie: materiał γ (`damping`, tempo w 1/s) i gumka D (F_D = −D · v).
/// Sceny bez kontaktów stoją w środku ram sceny tłoku, daleko od ścian. Krok stały 1/60.
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

    /// P-B-1: v = K · s / (m · γ + D) z tolerancją 10 %, poniżej `maximumLinearSpeed` (600), dla D = 0 i D > 0.
    func testSteadySpeedIsStiffnessTimesStretchOverMassTimesMaterialDampingPlusBandDamping() async throws {
        let stiffness: Float = 60, stretch: Float = 1, mass: Float = 1, gamma: Float = 2
        let withoutBandDamping = try BubbleDrivePolicy(rigidifies: false, bandStiffness: stiffness)
        let a = try await steadyState(mass: mass, damping: gamma, policy: withoutBandDamping, stretch: stretch)
        XCTAssertEqual(a.speed, stiffness * stretch / (mass * gamma), accuracy: 0.1 * stiffness * stretch / (mass * gamma), "D = 0")
        XCTAssertLessThan(a.peak, 600)

        let bandDamping: Float = 3
        let withBandDamping = try BubbleDrivePolicy(rigidifies: false, bandStiffness: stiffness, bandDamping: bandDamping)
        let b = try await steadyState(mass: mass, damping: gamma, policy: withBandDamping, stretch: stretch)
        let expected = stiffness * stretch / (mass * gamma + bandDamping)
        XCTAssertEqual(b.speed, expected, accuracy: 0.1 * expected, "D > 0")
        XCTAssertLessThan(b.peak, 600)
        XCTAssertLessThan(b.speed, a.speed, "tłumienie gumki zmniejsza prędkość ustaloną")
    }

    /// P-B-1 dla m ≠ 1: tłumienie gumki −D · v daje v = K · s / (m · γ + D), więc całkowanie e^(−D·dt/m) różni się od
    /// e^(−D·dt) (m = 2,5, D = 3, γ = 2: 7,5 wobec 4,8 dla błędnego wzoru).
    func testSteadySpeedWithBandDampingAndMassOtherThanOne() async throws {
        let stiffness: Float = 60, stretch: Float = 1, mass: Float = 2.5, gamma: Float = 2, bandDamping: Float = 3
        let policy = try BubbleDrivePolicy(rigidifies: false, bandStiffness: stiffness, bandDamping: bandDamping)
        let result = try await steadyState(mass: mass, damping: gamma, policy: policy, stretch: stretch)
        let expected = stiffness * stretch / (mass * gamma + bandDamping)
        XCTAssertEqual(result.speed, expected, accuracy: 0.05 * expected, "m = \(mass), D = \(bandDamping)")
        XCTAssertLessThan(result.peak, 600)
    }

    /// P-B-2: przy D = 0 stosunek prędkości ustalonych to odwrotność stosunku mas, w osobnych światach.
    func testSteadySpeedRatioIsTheInverseOfTheMassRatio() async throws {
        let policy = try BubbleDrivePolicy(rigidifies: false, bandStiffness: 60)
        let light = try await steadyState(mass: 1, damping: 2, policy: policy, stretch: 1)
        let heavy = try await steadyState(mass: 2.5, damping: 2, policy: policy, stretch: 1)
        XCTAssertEqual(light.speed / heavy.speed, 2.5, accuracy: 0.25)
        XCTAssertGreaterThan(heavy.speed, 1)
    }

    // MARK: ściana (P-B-3)

    private struct Rest {
        var depth: Float
        var stretch: Float
        var speed: Float
    }

    /// Bańka kc = 0 przy lewej ścianie, ciągnięta w nią gumką `K` z limitem `maximumForce`; stan po 6 s.
    private func pressedAgainstTheWall(stretch: Float) async throws -> Rest {
        let compliance: Float = 0.01
        let (world, base) = try world(material: CrowdScene.softBubblePhysics(base: compliance))
        let policy = try BubbleDrivePolicy(rigidifies: false, bandStiffness: 10, bandDamping: 5, maximumForce: 300)
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

    /// P-B-3 (G1-AC3): poniżej granicy `maximumForce` / K siła dociskająca F = ugięcie / c równa się K · s (10 %); powyżej niej
    /// położenie równowagi jest to samo (0,5 jedn.), bo siła jest obcięta do `maximumForce`.
    func testWallPressMatchesTheBandForceBelowTheLimitAndSaturatesAboveIt() async throws {
        let compliance: Float = 0.01, stiffness: Float = 10, maximumForce: Float = 300
        for stretch: Float in [6, 15, 24] {
            let rest = try await pressedAgainstTheWall(stretch: stretch)
            XCTAssertLessThan(rest.speed, 0.1, "s = \(stretch): bańka stoi")
            let force = rest.depth / compliance
            let expected = stiffness * rest.stretch
            XCTAssertEqual(force, expected, accuracy: 0.1 * expected, "s = \(stretch)")
        }
        var saturated: [Float] = []
        for stretch: Float in [45, 90] {
            let rest = try await pressedAgainstTheWall(stretch: stretch)
            XCTAssertLessThan(rest.speed, 0.1, "s = \(stretch): bańka stoi")
            XCTAssertEqual(rest.depth / compliance, maximumForce, accuracy: 0.1 * maximumForce, "s = \(stretch)")
            saturated.append(rest.depth)
        }
        XCTAssertEqual(saturated[0], saturated[1], accuracy: 0.5)
    }

    // MARK: puszczenie (P-B-4)

    /// P-B-4 (G1-AC4): po `endPlayerDrive` bańka zachowuje prędkość z ostatniego kroku napędu i leci dalej (hamuje ją tylko
    /// tłumienie materiału, tu zerowe).
    func testReleasingTheDriveKeepsTheVelocity() async throws {
        let (world, base) = try world(material: CrowdScene.bubblePhysics(damping: 0))
        let policy = try BubbleDrivePolicy(rigidifies: false, bandStiffness: 60, bandDamping: 3)
        let start = WorldPoint(-150, 0)
        _ = world.submit(try base
            .add(CrowdScene.bubble(1, at: start, radius: radius, mass: 1, drivePolicy: policy))
            .beginPlayerDrive(CrowdScene.id(1), target: start + WorldPoint(1, 0)))
        var before: ObjectState?
        for _ in 0..<240 {
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

    /// P-B-8 (G1-AC6): D = 0, γ = 0, cel stały, jeden krok na ramkę, bez kontaktów: Δv między ramkami N i N+1 równa się
    /// K · (target − achievedPoint) / m · dt, z `DriveFeedback` ramki N.
    func testVelocityChangeBetweenFramesFollowsTheFeedbackStretch() async throws {
        let (world, base) = try world(material: CrowdScene.bubblePhysics(damping: 0))
        let stiffness: Float = 30, mass: Float = 2
        let policy = try BubbleDrivePolicy(rigidifies: false, bandStiffness: stiffness)
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
