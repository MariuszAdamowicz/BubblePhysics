import BubblePhysics
import simd
import XCTest

/// Jedno tłumienie ruchu (wycinek 2, P-B-7 – P-B-12; G1-AC1 – G1-AC6): materiał γ działa najpierw na prędkość, dopiero potem
/// dochodzi F/m · dt, więc w spoczynku bańka dostaje pełną siłę, a prędkość narzucona torem albo napędem kinematycznym nie jest tłumiona.
///
/// Testy `testRest…` mierzą ugięcie bańki dociśniętej do grubej ściany (czoło w x = −100, grubość 300, co najmniej 2r). Testy
/// `testVelocity…` mierzą prędkość ramka po ramce w świecie bez ścian. Krok stały 1/60, materiał baniek o c₀ 0,0108 i r_ref 20.
@MainActor
final class MotionDampingTests: XCTestCase {
    private let dt = CrowdScene.step
    private let baseCompliance: Float = 0.0108
    private let referenceRadius: Float = 20
    /// Czoło grubej ściany; bańka stoi po jego prawej stronie i jest dociskana w −x.
    private let faceX: Float = -100
    private let rigidMaterial = PhysicsMaterialID(rawValue: 4)

    private func id(_ value: UInt64) -> ObjectID { CrowdScene.id(value) }

    // MARK: sceny

    /// Materiał baniek z podatnością c₀ · r / r_ref, `deformability` 0 (kontur czysto geometryczny) i tłumieniem γ.
    private func bubbleMaterial(damping: Float, maximumLinearSpeed: Float? = 600) throws -> PhysicsMaterial {
        try PhysicsMaterial(kind: .bubble, deformability: 0, damping: damping, maximumLinearSpeed: maximumLinearSpeed,
                            contactCompliance: BubbleContactCompliance(base: baseCompliance, referenceRadius: referenceRadius))
    }

    /// Świat z zasobami sceny tłoku, materiałem brył ruchomych `rigidMaterial` (γ = `rigidDamping`) i opcjonalną grubą ścianą.
    /// Obszar symulacji to kwadrat o połowie boku `extent`. Zwraca świat po kroku przyjmującym przygotowanie, a przy
    /// `stepsSetup` = false bez tego kroku (transakcja czeka na pierwszy `advance` testu, który liczy ten krok do pomiaru).
    private func world(bubble: PhysicsMaterial, rigidDamping: Float = 0, wall: Bool, extent: Float, stepsSetup: Bool = true,
                       file: StaticString = #filePath, line: UInt = #line,
                       _ build: (WorldTransaction) throws -> WorldTransaction) async throws -> BubbleWorld {
        let world = try BubbleWorld(configuration: WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-extent, -extent], max: [extent, extent]),
            fixedTimeStep: dt, eventBufferCapacity: 4096))
        var setup = try CrowdScene.resources(bubble: bubble)
            .updatePhysicsMaterial(rigidMaterial, material: try PhysicsMaterial(kind: .rigid, damping: rigidDamping))
        if wall {
            setup = setup.add(.rigidBody(try RigidBodyDescriptor(id: CrowdScene.wallIDs[0],
                vertices: [[-400, -450], [faceX, -450], [faceX, 450], [-400, 450]], motionRole: .static,
                physicsMaterialID: CrowdScene.wallMaterial, renderMaterialID: CrowdScene.style)))
        }
        let token = world.submit(try build(setup))
        guard stepsSetup else { return world }
        let frame = await world.advance(by: dt)
        XCTAssertNil(world.diagnostics.lastAdvanceIssue, "przygotowanie sceny", file: file, line: line)
        XCTAssertTrue(frame.transactionReceipts.contains { $0.token == token }, "przygotowanie sceny musi zostać przyjęte", file: file, line: line)
        return world
    }

    // MARK: ugięcie w spoczynku (P-B-7, P-B-8, P-B-11)

    private struct Rest {
        var deflection: Float
        /// Rozrzut ugięcia w ostatnich 60 krokach.
        var spread: Float
        var position: WorldPoint
        var contour: [WorldPoint]
    }

    /// Ugięcie r − (odległość środka od czoła) po `steps` krokach i rozrzut w ostatnich 60; kontur z `debugContourSnapshot()`.
    private func settle(_ world: BubbleWorld, _ value: UInt64, radius: Float, steps: Int = 600,
                        file: StaticString = #filePath, line: UInt = #line) async throws -> Rest {
        var tail: [Float] = []
        var position = WorldPoint.zero
        for index in 0..<steps {
            let frame = await world.advance(by: dt)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue, "krok \(index): \(String(describing: world.diagnostics.lastRejectionReason))",
                         file: file, line: line)
            position = try XCTUnwrap(frame.objects[id(value)], file: file, line: line).position
            if index >= steps - 60 { tail.append(radius - (position.x - faceX)) }
        }
        let contour = try XCTUnwrap(world.debugContourSnapshot()[id(value)], "brak konturu", file: file, line: line)
        return Rest(deflection: tail.last ?? 0, spread: (tail.max() ?? 0) - (tail.min() ?? 0), position: position, contour: contour)
    }

    /// Narastanie siły gumki do nasycenia w 120 krokach (2 s): naciągnięcie rośnie o `maximumForce / K / 120` na krok, a potem cel
    /// trafia 1 000 jednostek za czoło, jak w kryteriach. Bańka r 24 o masie 0,34 uderzona od razu pełną siłą 1 200 przeskakuje
    /// wgniecenie c · F i dociera do czoła ściany (pomiar na 2.3.0 przy γ = 0, bez zależności od tłumienia), więc stan ustalony
    /// mierzymy po łagodnym dojściu do nasycenia; stan ustalony z kryteriów się nie zmienia.
    private func rampBandToSaturation(_ world: BubbleWorld, _ value: UInt64, radius: Float, stiffness: Float, maximumForce: Float,
                                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let growth = maximumForce / stiffness / 120
        for index in 0..<120 {
            let frame = try await advance(world, file: file, line: line)
            let achieved = try XCTUnwrap(frame.driveFeedback.first, "krok \(index): brak DriveFeedback", file: file, line: line).achievedPoint
            _ = world.submit(WorldTransaction().updatePlayerDrive(id(value), target: achieved - WorldPoint(growth * Float(index + 2), 0)))
        }
        _ = world.submit(WorldTransaction().updatePlayerDrive(id(value), target: [faceX - 1000, 0]))
    }

    /// Wgniecenie konturu w stronę ściany: r − zasięg konturu od środka w −x.
    private func contourDent(_ rest: Rest, radius: Float) -> Float {
        radius - (rest.position.x - (rest.contour.map(\.x).min() ?? rest.position.x))
    }

    /// Gumka w nasyceniu: K_band = 100, `maximumForce` 1 200, cel 1 000 jednostek za czołem na prostej przez środek. Bańka r 24 dociągana
    /// do ściany ma ugięcie c₀ · (r / r_ref) · `maximumForce` dla każdego γ i m, a ugięcia przy różnych γ się zgadzają.
    func testRestBandInSaturationDeflectsByTheFullMaximumForceForEveryDampingAndMass() async throws {
        let radius: Float = 24, maximumForce: Float = 1200
        let expected = baseCompliance * (radius / referenceRadius) * maximumForce
        for mass: Float in [0.34, 1.36, 5.44] {
            var deflections: [Float] = []
            for gamma: Float in [0, 0.6, 4] {
                let policy = try BubbleDrivePolicy(bandStiffness: 100, maximumForce: maximumForce)
                let world = try await world(bubble: bubbleMaterial(damping: gamma), wall: true, extent: 1500) {
                    try $0.add(CrowdScene.bubble(1, at: [faceX + radius, 0], radius: radius, mass: mass, drivePolicy: policy))
                        .beginPlayerDrive(id(1), target: [faceX + radius - 0.1, 0])
                }
                try await rampBandToSaturation(world, 1, radius: radius, stiffness: 100, maximumForce: maximumForce)
                let rest = try await settle(world, 1, radius: radius, steps: 480)
                XCTAssertEqual(rest.deflection, expected, accuracy: 0.02 * expected,
                               "m = \(mass), γ = \(gamma): ugięcie \(rest.deflection), oczekiwane c · maximumForce = \(expected)")
                XCTAssertLessThan(rest.spread, 0.005 * expected, "m = \(mass), γ = \(gamma): ugięcie ma być uspokojone")
                deflections.append(rest.deflection)
            }
            XCTAssertLessThanOrEqual(((deflections.max() ?? 0) - (deflections.min() ?? 0)) / expected, 0.02,
                                     "m = \(mass): ugięcia przy γ ∈ {0; 0,6; 4} różnią się: \(deflections)")
        }
    }

    /// `MotorDrive` F = 600 i, w drugim świecie, siła globalna o tym samym module: ugięcie c · F w obu. Spec podaje γ = 0,6, które
    /// zabiera tylko 1 % siły (w tolerancji 2 %); γ = 4 zabiera 6,5 % i to ono odróżnia błąd od poprawnego tłumienia.
    func testRestMotorDriveAndGlobalForceDeflectByTheFullForce() async throws {
        let radius: Float = 24, force: Float = 600
        let expected = baseCompliance * (radius / referenceRadius) * force
        for gamma: Float in [0.6, 4] {
            let motor = try await world(bubble: bubbleMaterial(damping: gamma), wall: true, extent: 500) {
                try $0.add(CrowdScene.bubble(1, at: [faceX + radius, 0], radius: radius, mass: 1.36))
                    .setMotorDrive(id(1), drive: MotorDrive(force: [-force, 0]))
            }
            let global = try await world(bubble: bubbleMaterial(damping: gamma), wall: true, extent: 500) {
                try $0.add(CrowdScene.bubble(1, at: [faceX + radius, 0], radius: radius, mass: 1.36)).setGlobalForce([-force, 0])
            }
            for (name, world) in [("MotorDrive", motor), ("siła globalna", global)] {
                let rest = try await settle(world, 1, radius: radius)
                XCTAssertEqual(rest.deflection, expected, accuracy: 0.02 * expected,
                               "\(name), γ = \(gamma): ugięcie \(rest.deflection), oczekiwane c · F = \(expected)")
                XCTAssertLessThan(rest.spread, 0.005 * expected, "\(name), γ = \(gamma): ugięcie ma być uspokojone")
            }
        }
    }

    /// Gumka w nasyceniu (`maximumForce` = F = 600) i `MotorDrive` o tej samej sile dają to samo położenie środka i ten sam kontur
    /// z tolerancją 2 % ugięcia; chwyt nie zmienia promienia ani kształtu. Oba światy mają też ugięcie c · F (γ = 0,6 ze specyfikacji
    /// i γ = 4, które wykrywa utratę siły w tłumieniu).
    func testRestBandAndMotorDriveGiveTheSamePositionAndContour() async throws {
        let radius: Float = 24, force: Float = 600
        let expected = baseCompliance * (radius / referenceRadius) * force
        for gamma: Float in [0.6, 4] {
            let policy = try BubbleDrivePolicy(bandStiffness: 100, maximumForce: force)
            let band = try await world(bubble: bubbleMaterial(damping: gamma), wall: true, extent: 1500) {
                try $0.add(CrowdScene.bubble(1, at: [faceX + radius, 0], radius: radius, mass: 1.36, drivePolicy: policy))
                    .beginPlayerDrive(id(1), target: [faceX + radius - 0.1, 0])
            }
            try await rampBandToSaturation(band, 1, radius: radius, stiffness: 100, maximumForce: force)
            let motor = try await world(bubble: bubbleMaterial(damping: gamma), wall: true, extent: 1500) {
                try $0.add(CrowdScene.bubble(1, at: [faceX + radius, 0], radius: radius, mass: 1.36))
                    .setMotorDrive(id(1), drive: MotorDrive(force: [-force, 0]))
            }
            let gripped = try await settle(band, 1, radius: radius, steps: 480)
            let pushed = try await settle(motor, 1, radius: radius)
            let tolerance = 0.02 * expected
            XCTAssertEqual(gripped.position.x, pushed.position.x, accuracy: tolerance, "γ = \(gamma): położenie środka")
            XCTAssertEqual(gripped.position.y, pushed.position.y, accuracy: tolerance, "γ = \(gamma): położenie środka (y)")
            XCTAssertEqual(contourDent(gripped, radius: radius), contourDent(pushed, radius: radius), accuracy: tolerance,
                           "γ = \(gamma): wgniecenie konturu gumka \(contourDent(gripped, radius: radius)), MotorDrive \(contourDent(pushed, radius: radius))")
            XCTAssertEqual(gripped.deflection, expected, accuracy: tolerance, "γ = \(gamma): gumka, ugięcie c · F")
            XCTAssertEqual(pushed.deflection, expected, accuracy: tolerance, "γ = \(gamma): MotorDrive, ugięcie c · F")
        }
    }

    // MARK: przebieg prędkości (P-B-9, P-B-10, P-B-12)

    private enum Driven: CaseIterable {
        case band, bubbleMotor, rigidMotor
    }

    private let square: [WorldPoint] = [[-10, -10], [10, -10], [10, 10], [-10, 10]]

    /// Dwie kolejne ramki bez kontaktów: v_{N+1} = v_N · e^(−γ·dt) + F / m · dt dla gumki (z `DriveFeedback` ramki N), `MotorDrive` bańki
    /// i `MotorDrive` dynamicznej bryły wielokątnej (γ z jej materiału), dla γ ∈ {0, 0,6, 4}.
    func testVelocityStepIsPreviousVelocityTimesDecayPlusForceOverMassTimesStep() async throws {
        let mass: Float = 2, stiffness: Float = 30, target: WorldPoint = [20, 12], motorForce: WorldPoint = [40, 10]
        for kind in Driven.allCases {
            for gamma: Float in [0, 0.6, 4] {
                let name = "\(kind), γ = \(gamma)"
                let policy = try BubbleDrivePolicy(bandStiffness: stiffness)
                let world = try await world(bubble: bubbleMaterial(damping: gamma, maximumLinearSpeed: nil), rigidDamping: gamma,
                                            wall: false, extent: 500) {
                    switch kind {
                    case .band:
                        return try $0.add(CrowdScene.bubble(1, at: .zero, radius: 10, mass: mass, drivePolicy: policy))
                            .beginPlayerDrive(id(1), target: target)
                    case .bubbleMotor:
                        return try $0.add(CrowdScene.bubble(1, at: .zero, radius: 10, mass: mass))
                            .setMotorDrive(id(1), drive: MotorDrive(force: motorForce))
                    case .rigidMotor:
                        return try $0.add(.rigidBody(RigidBodyDescriptor(id: id(1), vertices: square, mass: mass, motionRole: .dynamic,
                                                                         physicsMaterialID: rigidMaterial, renderMaterialID: CrowdScene.style)))
                            .setMotorDrive(id(1), drive: MotorDrive(force: motorForce))
                    }
                }
                // Ramka po kroku przyjęcia sceny to ramka 0; porównujemy cztery kolejne pary.
                var previous = try await advance(world)
                for index in 0..<4 {
                    let next = try await advance(world)
                    let force: WorldPoint
                    if kind == .band {
                        let feedback = try XCTUnwrap(previous.driveFeedback.first, "\(name): brak DriveFeedback")
                        force = (feedback.target - feedback.achievedPoint) * stiffness
                    } else {
                        force = motorForce
                    }
                    let before = try XCTUnwrap(previous.objects[id(1)]).velocity
                    let after = try XCTUnwrap(next.objects[id(1)]).velocity
                    let expected = before * exp(-gamma * Float(dt)) + force / mass * Float(dt)
                    XCTAssertEqual(after.x, expected.x, accuracy: 0.01 * abs(expected.x) + 1e-4, "\(name), ramka \(index) x")
                    XCTAssertEqual(after.y, expected.y, accuracy: 0.01 * abs(expected.y) + 1e-4, "\(name), ramka \(index) y")
                    previous = next
                }
            }
        }
    }

    private func advance(_ world: BubbleWorld, file: StaticString = #filePath, line: UInt = #line) async throws -> WorldFrame {
        let frame = await world.advance(by: dt)
        XCTAssertNil(world.diagnostics.lastAdvanceIssue, String(describing: world.diagnostics.lastRejectionReason), file: file, line: line)
        return frame
    }

    /// Gumka ze stałym naciągnięciem s (cel przesuwany co krok o stałe naciągnięcie), `maximumForce` nil, bez kontaktów: prędkość
    /// ustalona to K · s · dt / (m · (1 − e^(−γ·dt))), poniżej `maximumLinearSpeed` (600).
    func testVelocityOfTheBandAtConstantStretchSettlesAtTheDiscreteSteadyState() async throws {
        let stiffness: Float = 60, stretch: Float = 0.1, mass: Float = 1.36
        for gamma: Float in [0.6, 4] {
            let policy = try BubbleDrivePolicy(bandStiffness: stiffness)
            let start: WorldPoint = [-300, 0]
            let world = try await world(bubble: bubbleMaterial(damping: gamma), wall: false, extent: 500) {
                try $0.add(CrowdScene.bubble(1, at: start, radius: 10, mass: mass, drivePolicy: policy))
                    .beginPlayerDrive(id(1), target: start + WorldPoint(stretch, 0))
            }
            var state: ObjectState?
            for index in 0..<840 {
                let frame = try await advance(world)
                state = try XCTUnwrap(frame.objects[id(1)])
                let achieved = try XCTUnwrap(frame.driveFeedback.first, "krok \(index)").achievedPoint
                _ = world.submit(WorldTransaction().updatePlayerDrive(id(1), target: achieved + WorldPoint(stretch, 0)))
            }
            let expected = stiffness * stretch * Float(dt) / (mass * (1 - exp(-gamma * Float(dt))))
            let velocity = try XCTUnwrap(state).velocity
            XCTAssertLessThan(expected, 600)
            XCTAssertEqual(velocity.x, expected, accuracy: 0.01 * expected, "γ = \(gamma): prędkość ustalona \(velocity.x), oczekiwana \(expected)")
            XCTAssertEqual(velocity.y, 0, accuracy: 1e-3, "γ = \(gamma)")
        }
    }

    /// Tor z prędkością 120, γ = 4: w każdym kroku, poza ostatnimi przed punktem toru, środek przesuwa się o 120 · dt (1 %), a koniec
    /// jest w ostatnim punkcie toru (1e-3).
    private func assertPathIsFollowedWithoutDamping(_ world: BubbleWorld, start: WorldPoint, end: WorldPoint, speed: Float,
                                                    _ name: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let stepLength = speed * Float(dt)
        var previous = start
        var checked = 0
        var worst: (error: Float, step: Int)?
        for index in 0..<130 {
            let frame = try await advance(world, file: file, line: line)
            let position = try XCTUnwrap(frame.objects[id(1)], file: file, line: line).position
            // Ostatni krok przed punktem toru jest krótszy (min(prędkość, odległość / dt)), więc go nie sprawdzamy.
            if simd_distance(previous, end) > 2 * stepLength {
                let error = abs(simd_distance(position, previous) - stepLength)
                if error > (worst?.error ?? -1) { worst = (error, index) }
                checked += 1
            }
            previous = position
        }
        XCTAssertGreaterThan(checked, 90, name, file: file, line: line)
        let (error, step) = try XCTUnwrap(worst, file: file, line: line)
        XCTAssertLessThanOrEqual(error, 0.01 * stepLength, "\(name): największe odchylenie kroku od \(stepLength) w kroku \(step)", file: file, line: line)
        XCTAssertEqual(previous.x, end.x, accuracy: 1e-3, "\(name): koniec toru x", file: file, line: line)
        XCTAssertEqual(previous.y, end.y, accuracy: 1e-3, "\(name): koniec toru y", file: file, line: line)
    }

    func testVelocityImposedByAPathIsNotDampedForABubble() async throws {
        let start: WorldPoint = [-100, 40], end: WorldPoint = [100, 90]
        let world = try await world(bubble: bubbleMaterial(damping: 4, maximumLinearSpeed: nil), wall: false, extent: 500, stepsSetup: false) {
            try $0.add(CrowdScene.bubble(1, at: start, radius: 10, mass: 1))
                .setPathDrive(id(1), drive: PathDrive(points: [end], speed: 120))
        }
        try await assertPathIsFollowedWithoutDamping(world, start: start, end: end, speed: 120, "bańka na torze, γ = 4")
    }

    func testVelocityImposedByAPathIsNotDampedForARigidBody() async throws {
        let start: WorldPoint = [-100, 40], end: WorldPoint = [100, 90]
        let world = try await world(bubble: bubbleMaterial(damping: 0), rigidDamping: 4, wall: false, extent: 500, stepsSetup: false) {
            try $0.add(.rigidBody(RigidBodyDescriptor(id: id(1), vertices: square, position: start, motionRole: .dynamic,
                                                      physicsMaterialID: rigidMaterial, renderMaterialID: CrowdScene.style)))
                .setPathDrive(id(1), drive: PathDrive(points: [end], speed: 120))
        }
        try await assertPathIsFollowedWithoutDamping(world, start: start, end: end, speed: 120, "bryła na torze, γ = 4")
    }

    /// Test braku regresji (przechodzi już w 2.3.0, bo host zeruje tłumienie bryły kinematycznej w `motion.w`): bryła z materiałem
    /// o `damping` 4 i napędem `.velocity` jedzie z zadaną prędkością, a jej poza po 600 krokach różni się od wyliczonej o ≤ 1e-3.
    func testVelocityOfAKinematicBodyIsNotDampedByTheMaterial() async throws {
        let start: WorldPoint = [-150, 20], linear: WorldPoint = [30, -5]
        let world = try await world(bubble: bubbleMaterial(damping: 0), rigidDamping: 4, wall: false, extent: 500, stepsSetup: false) {
            try $0.add(.rigidBody(RigidBodyDescriptor(id: id(1), vertices: square, position: start, motionRole: .kinematic,
                                                      physicsMaterialID: rigidMaterial, renderMaterialID: CrowdScene.style)))
                .setKinematicDrive(id(1), drive: .velocity(linear: linear, angular: 0))
        }
        var position = start
        for _ in 0..<600 {
            let frame = try await advance(world)
            position = try XCTUnwrap(frame.objects[id(1)]).position
        }
        let expected = start + linear * Float(Double(dt) * 600)
        XCTAssertEqual(position.x, expected.x, accuracy: 1e-3, "x")
        XCTAssertEqual(position.y, expected.y, accuracy: 1e-3, "y")
    }
}
