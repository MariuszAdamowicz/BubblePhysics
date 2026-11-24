import BubblePhysicsModel
import Metal
import simd
import XCTest
@testable import BubblePhysicsNativeMetal

/// Jądra pętli podkroków silnika 4.0.0 na GPU, na poziomie komponentu (wycinek 1, zadanie 7b): przyspieszenie bez kontaktów (siła globalna
/// i pola), zapas obwiedni z x₀, redukcja h (1/ω_max z Gershgorina, d / 4 w obu kierunkach, limit 1024), leapfrog z oporem γ i zapis
/// podkroków. Jądra biegną na ręcznie zbudowanych buforach `NativeMetalPersistentState`; odniesieniem jest Double z testu i
/// `ContactLawReference` (w tym symulacja 1D reguły h), a nie wartości przypięte z przebiegu.
@MainActor
final class NativeMetalSubstepKernelTests: XCTestCase {
    private typealias Point = SIMD2<Float>

    // MARK: Rig

    private enum Role { case force, path, `static` }

    private struct Body {
        var id: Int
        var center: Point
        var velocity: Point = .zero
        var mass: Float = 0.36
        var radius: Float = 12
        var stiffness: Float = 229
        var damping: Float = 0
        var role: Role = .force
    }

    private enum Step {
        case acceleration, margin, reduce, contactForces
        case integrate(NativeMetalSubstep.Phase)
        /// Jądra podkroku z pośrednią liczbą grup z `nativeReduceSubstep` (zero grup dla podkroku pustego).
        case indirectIntegrate(NativeMetalSubstep.Phase), indirectContactForces
    }

    /// Ręcznie zbudowana scena: bańki, odcinki, wiersze sąsiedztwa i rekordy sił w buforach produkcyjnego stanu trwałego.
    @MainActor
    private final class Rig {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipelines: [String: MTLComputePipelineState]
        let state: NativeMetalPersistentState
        let forces = NativeMetalForceBuffers()
        let ids: [UInt64]
        let count: Int
        let step: Float
        let capture: Bool
        let limit = NativeMetalSolver.candidateLimitPerObject
        /// Zapas tylko r / 4 w `nativeBroadphaseMargin` (przełącznik `minimumMarginOnly`).
        var minimumMarginOnly = false

        init(bodies: [Body], segments: [NativeSolverSegment] = [], rows: [[(neighbor: UInt32, kind: UInt32)]] = [],
             forces input: NativeForceInput = NativeForceInput(), step: Float = 1.0 / 60, capture: Bool = false) throws {
            guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Brak urządzenia Metal") }
            self.device = device
            queue = try XCTUnwrap(device.makeCommandQueue())
            pipelines = try NativeMetalPipelineCache.pipelines(for: device).stages
            state = try NativeMetalPersistentState(device: device, bubbleCount: bodies.count, segmentCount: segments.count,
                                                   captureSubsteps: capture)
            count = bodies.count
            ids = bodies.map { UInt64($0.id) }
            self.step = step
            self.capture = capture
            let bubbles = state.workingBubbles.contents().bindMemory(to: NativeMetalBubble.self, capacity: bodies.count)
            for (index, body) in bodies.enumerated() {
                var value = NativeMetalBubble(NativeSolverBubble(id: .init(rawValue: body.id), center: body.center, velocity: body.velocity,
                    mass: body.mass, inverseMass: body.role == .static ? 0 : nil, targetRadius: body.radius))
                value.contact = SIMD4(0, body.stiffness, 1, body.role == .force ? 1 : 0)
                value.material = SIMD4(body.damping, 0, 0, 0)
                value.publicFlags = SIMD4(1, body.role == .static ? 1 : 0, 0, 0)
                bubbles[index] = value
            }
            let wallSegments = state.workingSegments.contents().bindMemory(to: NativeMetalSegment.self, capacity: max(1, segments.count))
            for (index, segment) in segments.enumerated() { wallSegments[index] = NativeMetalSegment(segment) }
            let adjacency = state.adjacency.contents().bindMemory(to: SIMD4<UInt32>.self, capacity: bodies.count * limit)
            let degrees = state.adjacencyCounts.contents().bindMemory(to: UInt32.self, capacity: bodies.count)
            for (index, row) in rows.enumerated() {
                for (slot, item) in row.enumerated() { adjacency[index * limit + slot] = SIMD4(0, item.neighbor, item.kind, 0) }
                degrees[index] = UInt32(row.count)
            }
            state.control.contents().bindMemory(to: NativeMetalControl.self, capacity: 1).pointee = NativeMetalControl(
                counts: SIMD4(UInt32(bodies.count), UInt32(segments.count), 0, 0), physics: SIMD4(step, 0, 0, 0), contactDamping: .zero)
            state.contactControl.contents().bindMemory(to: NativeMetalContactControl.self, capacity: 1).pointee = NativeMetalContactControl(
                limits: .zero, counts: .zero, cache: SIMD4(0, 0, 0, UInt32(limit)), thresholds: .zero, cellWidth: .zero)
            // Bez wywołania `.margin` zapas jest nieskończony, a x₀ to środek startowy: człon zapasu nie wpływa na h.
            for index in 0..<bodies.count { setMargin(index, 1e9, reference: bodies[index].center) }
            try forces.upload(input, device: device)
            substep = NativeMetalSubstepControl(time: SIMD4(step, 0, 0, 0))
        }

        /// Zapas i x₀ bańki tak, jakby siatkę zbudowano przy tym zapasie i w tym punkcie.
        func setMargin(_ index: Int, _ margin: Float, reference: Point) {
            state.broadphaseMargin.contents().bindMemory(to: Float.self, capacity: count)[index] = margin
            state.referencePositions.contents().bindMemory(to: Point.self, capacity: count)[index] = reference
        }

        // MARK: Odczyt i zapis stanu GPU

        var substep: NativeMetalSubstepControl {
            get { state.substepControl.contents().bindMemory(to: NativeMetalSubstepControl.self, capacity: 1).pointee }
            set { state.substepControl.contents().bindMemory(to: NativeMetalSubstepControl.self, capacity: 1).pointee = newValue }
        }
        var dispatchGroups: UInt32 { state.substepDispatch.contents().bindMemory(to: UInt32.self, capacity: 3)[0] }
        func bubble(_ index: Int) -> NativeMetalBubble {
            state.workingBubbles.contents().bindMemory(to: NativeMetalBubble.self, capacity: count)[index]
        }
        func acceleration(_ index: Int) -> Point { state.acceleration.contents().bindMemory(to: Point.self, capacity: count)[index] }
        func nonContactAcceleration(_ index: Int) -> Point {
            state.nonContactAcceleration.contents().bindMemory(to: Point.self, capacity: count)[index]
        }
        func margin(_ index: Int) -> Float { state.broadphaseMargin.contents().bindMemory(to: Float.self, capacity: count)[index] }
        func reference(_ index: Int) -> Point { state.referencePositions.contents().bindMemory(to: Point.self, capacity: count)[index] }
        func setAcceleration(_ index: Int, _ value: Point) {
            state.acceleration.contents().bindMemory(to: Point.self, capacity: count)[index] = value
        }

        // MARK: Kodowanie

        func submit(_ steps: [Step]) throws {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
            let width = NativeMetalSubstep.groupWidth
            for item in steps {
                encoder.memoryBarrier(scope: .buffers)
                switch item {
                case .acceleration:
                    encoder.setComputePipelineState(pipelines["nativeAccelerationWithoutContacts"]!)
                    bindForces(encoder, output: state.nonContactAcceleration)
                    threads(encoder)
                case .margin:
                    encoder.setComputePipelineState(pipelines["nativeBroadphaseMargin"]!)
                    for (index, buffer) in [state.workingBubbles, state.control, state.nonContactAcceleration, state.substepControl,
                                            state.broadphaseMargin, state.referencePositions].enumerated() {
                        encoder.setBuffer(buffer, offset: 0, index: index)
                    }
                    var minimumOnly: UInt32 = minimumMarginOnly ? 1 : 0
                    encoder.setBytes(&minimumOnly, length: MemoryLayout<UInt32>.stride, index: 6)
                    threads(encoder)
                case .reduce:
                    let pipeline = pipelines["nativeReduceSubstep"]!
                    encoder.setComputePipelineState(pipeline)
                    for (index, buffer) in [state.workingBubbles, state.workingSegments, state.control, state.contactControl,
                                            state.adjacency, state.adjacencyCounts, state.acceleration, state.substepControl,
                                            state.substepDispatch, state.substepSteps, state.broadphaseMargin,
                                            state.referencePositions, forces.control!, forces.bands!].enumerated() {
                        encoder.setBuffer(buffer, offset: 0, index: index)
                    }
                    encoder.dispatchThreadgroups(.init(width: 1, height: 1, depth: 1),
                        threadsPerThreadgroup: .init(width: NativeMetalSubstep.reductionWidth(pipeline), height: 1, depth: 1))
                case .contactForces:
                    bindContactForces(encoder)
                    threads(encoder)
                case .indirectContactForces:
                    bindContactForces(encoder)
                    encoder.dispatchThreadgroups(indirectBuffer: state.substepDispatch, indirectBufferOffset: 0,
                                                 threadsPerThreadgroup: .init(width: width, height: 1, depth: 1))
                case .integrate(let phase):
                    bindIntegrate(encoder, phase)
                    threads(encoder)
                case .indirectIntegrate(let phase):
                    bindIntegrate(encoder, phase)
                    encoder.dispatchThreadgroups(indirectBuffer: state.substepDispatch, indirectBufferOffset: 0,
                                                 threadsPerThreadgroup: .init(width: width, height: 1, depth: 1))
                }
            }
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
        }

        private func threads(_ encoder: MTLComputeCommandEncoder) {
            encoder.dispatchThreads(.init(width: count, height: 1, depth: 1),
                                    threadsPerThreadgroup: .init(width: NativeMetalSubstep.groupWidth, height: 1, depth: 1))
        }

        private func bindForces(_ encoder: MTLComputeCommandEncoder, output: MTLBuffer) {
            for (index, buffer) in [state.workingBubbles, state.control, forces.control!, forces.fields!, forces.fieldVertices!,
                                    forces.fieldObjectIDs!, output, forces.bands!, forces.motors!].enumerated() {
                encoder.setBuffer(buffer, offset: 0, index: index)
            }
        }

        private func bindContactForces(_ encoder: MTLComputeCommandEncoder) {
            encoder.setComputePipelineState(pipelines["nativeContactForces"]!)
            for (index, buffer) in [state.workingBubbles, state.workingSegments, state.control, state.contactControl, state.adjacency,
                                    state.adjacencyCounts, state.contactForces].enumerated() {
                encoder.setBuffer(buffer, offset: 0, index: index)
            }
        }

        private func bindIntegrate(_ encoder: MTLComputeCommandEncoder, _ phase: NativeMetalSubstep.Phase) {
            encoder.setComputePipelineState(pipelines["nativeIntegrateSubstep"]!)
            for (index, buffer) in [state.workingBubbles, state.control, forces.control!, forces.fields!, forces.fieldVertices!,
                                    forces.fieldObjectIDs!, state.acceleration, state.nonContactAcceleration, state.contactForces,
                                    state.substepControl, state.substepCapture ?? state.acceleration].enumerated() {
                encoder.setBuffer(buffer, offset: 0, index: index)
            }
            var mode = SIMD4<UInt32>(phase.rawValue, capture ? 1 : 0, 0, 0)
            encoder.setBytes(&mode, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 11)
            encoder.setBuffer(forces.bands!, offset: 0, index: 12)
            encoder.setBuffer(forces.motors!, offset: 0, index: 13)
        }

        // MARK: Klatka

        /// Początek kroku: czasy od zera, a₀, siły pełne i przyspieszenie początku kroku.
        func beginFrame() throws {
            var control = substep
            control.time = SIMD4(step, 0, 0, control.time.w)
            control.counts = .zero
            substep = control
            try submit([.acceleration, .contactForces, .integrate(.initialAcceleration)])
        }

        /// Jeden podkrok: redukcja h i trzy dyspozycje pośrednie.
        func substepSequence() -> [Step] {
            [.reduce, .indirectIntegrate(.kickAndMove), .indirectContactForces, .indirectIntegrate(.forcesAndKick)]
        }

        /// Podkroki jeden po drugim do końca czasu kroku, znacznika limitu albo przebudowy; zwraca liczbę podkroków klatki.
        @discardableResult
        func runFrame(maximum: Int = 3000) throws -> Int {
            try beginFrame()
            for _ in 0..<maximum {
                try submit(substepSequence())
                let control = substep
                if control.time.y >= control.time.x || control.counts.z != 0 || control.counts.w != 0 { break }
            }
            return Int(substep.counts.y)
        }
    }

    // MARK: Pomocnicze

    private func relative(_ value: Double, _ expected: Double) -> Double {
        abs(value - expected) / max(abs(expected), .leastNormalMagnitude)
    }

    private let square: [Point] = [[0, 0], [200, 0], [200, 200], [0, 200]]

    /// Dolna krawędź kwadratu leży w y = 0 z normalną zewnętrzną (0, −1): środek bańki w (x, −d) ma odległość d od ściany.
    private func wallSegments() -> [NativeSolverSegment] { NativeStaticPolygonEdges.segments(points: square, firstID: 1, ownerID: 100) }

    private var wallRow: [(neighbor: UInt32, kind: UInt32)] { (0..<4).map { (UInt32($0), UInt32(1)) } }

    /// k = dF/dx ściany z odniesienia: pochodna centralna prawa po wgnieceniu x = r · ε.
    private func wallStiffness(distance: Double, radius: Double, stiffness: Double) -> Double {
        let epsilon = 1 - distance / radius, h = 1e-6 * (1 - epsilon)
        return (ContactLawReference.force(epsilon: epsilon + h, stiffness: stiffness)
            - ContactLawReference.force(epsilon: epsilon - h, stiffness: stiffness)) / (2 * h * radius)
    }

    /// k pary tego samego materiału z odniesienia: pochodna siły po zbliżeniu powierzchni δ.
    private func pairStiffness(overlap: Double, a: ContactLawReference.PairBody, b: ContactLawReference.PairBody) throws -> Double {
        let h = 1e-5 * min(a.radius, b.radius)
        let high = try XCTUnwrap(ContactLawReference.pairContact(overlap: overlap + h, a: a, b: b)).force
        let low = try XCTUnwrap(ContactLawReference.pairContact(overlap: overlap - h, a: a, b: b)).force
        return (high - low) / (2 * h)
    }

    private func field(_ id: UInt64, _ field: ForceField, shape: RangeGeometry.Shape = .circle(radius: 100), at position: WorldPoint = .zero,
                       rotation: Float = 0, filter: Set<ObjectID>? = nil) throws -> NativePublicObject {
        NativePublicObject(descriptor: .forceField(try ForceFieldDescriptor(id: ObjectID(rawValue: id), position: position,
            rotation: rotation, geometry: RangeGeometry(shape: shape), field: field, filter: ObjectFilter(objectIDs: filter))))
    }

    // MARK: nativeAccelerationWithoutContacts

    func testAccelerationSumsGlobalForceAndFieldsAndRespectsFilterRoleAndMass() throws {
        let box: RangeGeometry.Shape = .polygon(try PolygonGeometry(vertices: [[-50, -50], [50, -50], [50, 50], [-50, 50]]))
        let input = NativeForceInput(objects: [
            try field(10, .directional(force: [30, -40]), shape: .circle(radius: 100), at: [5, -5], rotation: 0.5),
            try field(11, .radial(strength: -50, falloff: 2), shape: .circle(radius: 80)),
            try field(12, .vortex(strength: 10, falloff: 1), shape: box, at: [5, 5], rotation: 0.3),
            try field(13, .radial(strength: 7, falloff: 0), shape: .circle(radius: 200), filter: [ObjectID(rawValue: 2)]),
            try field(14, .directional(force: [1000, 1000]), shape: .circle(radius: 300), filter: [])], globalForce: [1, -2])
        let bodies = [Body(id: 1, center: [10, 20], mass: 0.5), Body(id: 2, center: [10, 20], mass: 2),
                      Body(id: 3, center: [10, 20], role: .path), Body(id: 4, center: [10, 20], role: .static),
                      Body(id: 5, center: [400, 0], mass: 1)]
        let rig = try Rig(bodies: bodies, forces: input)
        try rig.submit([.acceleration])

        func expected(id: Int, mass: Double, point: SIMD2<Double>) -> SIMD2<Double> {
            var force = SIMD2<Double>(1, -2)
            // Kierunkowe w kole o promieniu 100 wokół (5, −5), obrócone o 0,5 rad.
            let c = cos(0.5), s = sin(0.5)
            let delta = point - SIMD2(5, -5)
            let local = SIMD2(c * delta.x + s * delta.y, -s * delta.x + c * delta.y)
            if simd_length(local) <= 100 { force += SIMD2(c * 30 - s * -40, s * 30 + c * -40) }
            // Radialne przyciągające (ujemna siła) w kole 80 z falloffem 2.
            force += ContactLawReference.RadialField(strength: -50, falloff: 2, radius: 80).force(at: point)
            // Wirowe w kwadracie ±50 wokół (5, 5), obrót 0,3, falloff 1, promień zaniku 50 · √2.
            let c3 = cos(0.3), s3 = sin(0.3), d3 = point - SIMD2(5, 5)
            let l3 = SIMD2(c3 * d3.x + s3 * d3.y, -s3 * d3.x + c3 * d3.y)
            if abs(l3.x) <= 50, abs(l3.y) <= 50, simd_length(d3) > 0 {
                let r = 50 * 2.0.squareRoot(), scale = 10 * pow(max(0, 1 - simd_length(l3) / r), 1) / simd_length(l3)
                force += SIMD2(-d3.y, d3.x) * scale
            }
            // Pole z filtrem [2] działa tylko na bańkę 2; pole z pustym filtrem na nikogo.
            if id == 2 { force += ContactLawReference.RadialField(strength: 7, falloff: 0, radius: 200).force(at: point) }
            return force / mass
        }
        for (index, mass) in [(0, 0.5), (1, 2.0), (4, 1.0)] {
            let id = bodies[index].id, point = SIMD2<Double>(Double(bodies[index].center.x), Double(bodies[index].center.y))
            let want = expected(id: id, mass: mass, point: point)
            let got = rig.nonContactAcceleration(index)
            let error = simd_length(SIMD2(Double(got.x), Double(got.y)) - want) / max(simd_length(want), 1e-9)
            XCTAssertLessThanOrEqual(error, 1e-4, "bańka \(id): \(got) wobec \(want)")
        }
        XCTAssertNotEqual(rig.nonContactAcceleration(0), .zero)
        XCTAssertEqual(rig.nonContactAcceleration(2), .zero, "rola torowa nie dostaje sił")
        XCTAssertEqual(rig.nonContactAcceleration(3), .zero, "bańka statyczna ma masę nieskończoną")
    }

    // MARK: Gumka i motor w a₀, ω_max i podkroku (zadanie 10)

    /// Wejście sił z samymi rekordami gumki i motoru (rekordy leżą rosnąco po ID, jak buduje je `NativeForceInput`).
    private func driveInput(bands: [NativeMetalBandDrive] = [], motors: [NativeMetalMotor] = [], globalForce: WorldPoint = .zero) -> NativeForceInput {
        var input = NativeForceInput(objects: [], globalForce: globalForce)
        input.bandDrives = bands
        input.motors = motors
        return input
    }

    func testAccelerationAddsBandWithOptionalCapAndMotorForceForTheirOwnersOnly() throws {
        let input = driveInput(bands: [
            NativeMetalBandDrive(identity: SIMD2(1, 0), band: SIMD4(30, -20, 22, 0)),
            NativeMetalBandDrive(identity: SIMD2(2, 0), band: SIMD4(30, -20, 22, 10)),
            NativeMetalBandDrive(identity: SIMD2(4, 0), band: SIMD4(100, 0, 22, 0))],
            motors: [NativeMetalMotor(identity: SIMD2(3, 0), drive: SIMD4(6, -8, 2, 1))], globalForce: [1, 1])
        let bodies = [Body(id: 1, center: [10, 20], mass: 0.5), Body(id: 2, center: [10, 20], mass: 0.5),
                      Body(id: 3, center: [10, 20], mass: 2), Body(id: 4, center: [0, 0], role: .path),
                      Body(id: 5, center: [10, 20], mass: 1)]
        let rig = try Rig(bodies: bodies, forces: input)
        try rig.submit([.acceleration])
        // Gumka bez limitu: K · (cel − x) = 22 · (20, −40); siła globalna (1, 1); masa 0,5.
        XCTAssertEqual(rig.nonContactAcceleration(0).x, (22 * 20 + 1) / 0.5, accuracy: 1e-3)
        XCTAssertEqual(rig.nonContactAcceleration(0).y, (22 * -40 + 1) / 0.5, accuracy: 1e-3)
        // Z limitem 10 siła gumki (|F| = 22 · √(20² + 40²) ≈ 984) ma długość 10 i ten sam kierunek; siła globalna nie jest obcinana.
        let direction = SIMD2<Float>(20, -40) / (20 * 20 + 40 * 40).squareRoot()
        XCTAssertEqual(rig.nonContactAcceleration(1).x, (10 * direction.x + 1) / 0.5, accuracy: 1e-3)
        XCTAssertEqual(rig.nonContactAcceleration(1).y, (10 * direction.y + 1) / 0.5, accuracy: 1e-3)
        // Motor: siła (6, −8) na masę 2 plus siła globalna.
        XCTAssertEqual(rig.nonContactAcceleration(2).x, (6 + 1) / 2, accuracy: 1e-5)
        XCTAssertEqual(rig.nonContactAcceleration(2).y, (-8 + 1) / 2, accuracy: 1e-5)
        XCTAssertEqual(rig.nonContactAcceleration(3), .zero, "rola torowa nie dostaje gumki")
        XCTAssertEqual(rig.nonContactAcceleration(4), [1, 1], "bańka bez rekordu dostaje tylko siłę globalną")
    }

    /// Gumka liczy się z bieżącego położenia w każdym podkroku: bez oporu jedno 1/60 s pod sprężyną o ω = √(K/m) przesuwa bańkę
    /// jak oscylator harmoniczny (x(t) = cel + (x₀ − cel) cos ωt), a nie jak stała siła z początku kroku (ta dałaby ½ a₀ t² ≈ 278 zamiast 99).
    /// Podział wymuszony 4 × daje ω h ≈ 0,25, więc błąd metody leapfrog jest rzędu procentów.
    func testBandSpringFollowsTheHarmonicOscillatorBecauseItUsesTheCurrentPosition() throws {
        let stiffness: Float = 40_000, mass: Float = 1, target: Float = 50
        let omega = Double(stiffness / mass).squareRoot()
        let rig = try Rig(bodies: [Body(id: 1, center: [0, 0], mass: mass)], forces: driveInput(
            bands: [NativeMetalBandDrive(identity: SIMD2(1, 0), band: SIMD4(target, 0, stiffness, 0))]))
        var control = rig.substep
        control.time.w = 4
        rig.substep = control
        let substeps = try rig.runFrame()
        // ω = 200: 1/ω = 0,005, a z podziałem 4 × h = 0,00125, więc krok ma ok. 14 podkroków.
        XCTAssertGreaterThanOrEqual(substeps, 12)
        let t = 1.0 / 60
        let expected = Double(target) * (1 - cos(omega * t))
        XCTAssertEqual(Double(rig.bubble(0).position.x), expected, accuracy: 0.03 * Double(target))
        let expectedVelocity = Double(target) * omega * sin(omega * t)
        XCTAssertEqual(Double(rig.bubble(0).motion.x), expectedVelocity, accuracy: 0.05 * Double(target) * omega)
    }

    func testBandStiffnessLimitsTheSubstepThroughOmegaMax() throws {
        // Bez kontaktów jedyny człon sztywności to gumka: h = 1 / ω = √(m / K) przy K = 300 000, m = 0,36.
        let rig = try Rig(bodies: [Body(id: 1, center: [0, 0], mass: 0.36)], forces: driveInput(
            bands: [NativeMetalBandDrive(identity: SIMD2(1, 0), band: SIMD4(0, 0, 300_000, 0))]))
        try rig.beginFrame()
        try rig.submit([.reduce])
        let expected = (0.36 / 300_000.0).squareRoot()
        XCTAssertEqual(Double(rig.substep.time.z), expected, accuracy: 1e-6 * 10)
        XCTAssertEqual(rig.substep.limiter.y, NativeMetalSubstep.Term.stiffness.rawValue)
        XCTAssertEqual(rig.substep.limiter.x, 1)
    }

    func testMotorTorqueSpinsTheBubbleExactlyForAnyDampingAndForceRolesOnly() throws {
        // dω/dt = M / I − γ ω; I = 0,5 · 2 · 3² = 9, M = 4,5, więc przy γ = 0 ω po kroku = 0,5 / 60, a przy γ = 2 ω = M/(Iγ) (1 − e^(−γ h)).
        for gamma: Float in [0, 2] {
            let rig = try Rig(bodies: [Body(id: 1, center: [0, 0], mass: 2, damping: gamma), Body(id: 2, center: [50, 0], mass: 2, role: .path)],
                              forces: driveInput(motors: [NativeMetalMotor(identity: SIMD2(1, 0), drive: SIMD4(0, 0, 4.5, 9)),
                                                          NativeMetalMotor(identity: SIMD2(2, 0), drive: SIMD4(0, 0, 4.5, 9))]))
            try rig.runFrame()
            let h = 1.0 / 60, g = Double(gamma)
            let expected = g == 0 ? 0.5 * h : 0.5 / g * (1 - exp(-g * h))
            XCTAssertEqual(Double(rig.bubble(0).motion.w), expected, accuracy: 1e-6, "γ \(gamma)")
            XCTAssertEqual(rig.bubble(1).motion.w, 0, "rola torowa nie dostaje momentu")
        }
    }

    func testForcedSplitMultiplierDividesTheStepIntoEqualPartsAndKeepsTheResult() throws {
        // Bańka w spoczynku pod stałą siłą globalną: naturalnie jeden podkrok, z mnożnikiem 4 dokładnie cztery równe, bez mikropodkroku z zaokrąglenia.
        var results: [(substeps: UInt32, velocity: Float, position: Float, history: [Float])] = []
        for multiplier: Float in [1, 4, 7] {
            let rig = try Rig(bodies: [Body(id: 1, center: [0, 0], velocity: [3, 0], mass: 0.5, damping: 1)],
                              forces: NativeForceInput(objects: [], globalForce: [3, 0]))
            var control = rig.substep
            control.time.w = multiplier
            rig.substep = control
            try rig.runFrame()
            let history = rig.state.substepSteps.contents().bindMemory(to: Float.self, capacity: 8)
            results.append((rig.substep.counts.y, rig.bubble(0).motion.x, rig.bubble(0).position.x, (0..<Int(rig.substep.counts.y)).map { history[$0] }))
        }
        XCTAssertEqual(results.map(\.substeps), [1, 4, 7])
        for result in results.dropFirst() {
            XCTAssertEqual(result.history.reduce(0, +), 1.0 / 60, accuracy: 1e-7, "suma h to czas kroku")
            XCTAssertEqual(result.history.max() ?? 0, result.history.min() ?? 0, accuracy: 1e-7, "równe części")
            XCTAssertEqual(result.velocity, results[0].velocity, accuracy: 1e-4, "ten sam wynik przy stałej sile")
            XCTAssertEqual(result.position, results[0].position, accuracy: 1e-4)
        }
    }

    // MARK: nativeBroadphaseMargin

    func testMarginIsTheLargerOfTheTravelBoundAndAQuarterRadiusAndStoresTheReferencePosition() throws {
        let bodies = [Body(id: 1, center: [100, 200], velocity: [3000, 0], mass: 0.36, radius: 12),
                      Body(id: 2, center: [-5, 7], velocity: [0.5, 0], mass: 0.36, radius: 40),
                      Body(id: 3, center: [8, 9], velocity: [0, 0], mass: 0.5, radius: 24)]
        // Siła globalna 5 działa na wszystkie bańki napędzane siłami: a₀ = 5 / m.
        let rig = try Rig(bodies: bodies, forces: NativeForceInput(objects: [], globalForce: [5, 0]))
        try rig.submit([.acceleration, .margin])
        let t = 1.0 / 60
        func bound(speed: Double, acceleration: Double) -> Double { 1.05 * (speed * t + 0.5 * acceleration * t * t) }
        XCTAssertLessThanOrEqual(relative(Double(rig.margin(0)), bound(speed: 3000, acceleration: 5 / 0.36)), 1e-5, "szybka: człon ruchu")
        XCTAssertEqual(rig.margin(1), 10, "wolna: r / 4 = 10 (człon ruchu to \(bound(speed: 0.5, acceleration: 5 / 0.36)))")
        XCTAssertEqual(rig.margin(2), 6, "spoczynek: r / 4 mimo przyspieszenia")
        for index in 0..<3 { XCTAssertEqual(rig.reference(index), bodies[index].center, "x₀ ← x, bańka \(index)") }
        // Czas pozostały, a nie cały krok: po 0,01 s kroku zostaje 1/60 − 0,01.
        var control = rig.substep
        control.time.y = 0.01
        rig.substep = control
        try rig.submit([.margin])
        let remaining = t - 0.01
        XCTAssertLessThanOrEqual(relative(Double(rig.margin(0)), 1.05 * (3000 * remaining + 0.5 * (5 / 0.36) * remaining * remaining)), 1e-4)
    }

    func testMarginKernelTakesTheReferencePositionFromTheCurrentCenter() throws {
        let rig = try Rig(bodies: [Body(id: 1, center: [1, 2])])
        try rig.submit([.acceleration, .margin])
        var bubble = rig.bubble(0)
        XCTAssertEqual(rig.reference(0), [1, 2])
        bubble.position.x = 50; bubble.position.y = -9
        rig.state.workingBubbles.contents().bindMemory(to: NativeMetalBubble.self, capacity: 1)[0] = bubble
        try rig.submit([.margin])
        XCTAssertEqual(rig.reference(0), [50, -9], "każde wywołanie (także przy przebudowie) ustawia x₀ ← x")
    }

    // MARK: nativeReduceSubstep

    func testReductionWithoutContactsTakesTheWholeRemainingStepAndRecordsIt() throws {
        let rig = try Rig(bodies: [Body(id: 41, center: [0, 0], velocity: [5, 0]), Body(id: 42, center: [500, 0])])
        try rig.submit([.reduce])
        let control = rig.substep
        XCTAssertEqual(control.time.z, 1.0 / 60, "h = czas kroku")
        XCTAssertEqual(control.time.y, control.time.x, "czas upłynął w całości")
        XCTAssertEqual(control.counts.x, 1)
        XCTAssertEqual(control.counts.y, 1)
        XCTAssertEqual(control.counts.z, 0, "bez przebudowy")
        XCTAssertEqual(control.counts.w, 0, "bez limitu")
        XCTAssertEqual(control.limiter.y, NativeMetalSubstep.Term.remainingTime.rawValue)
        XCTAssertEqual(rig.dispatchGroups, 1)
        XCTAssertEqual(rig.state.substepSteps.contents().bindMemory(to: Float.self, capacity: 1)[0], 1.0 / 60)
    }

    func testReductionStepsOnlyUntilTheEndOfTheStepAndTheLastHIsTheRemainder() throws {
        let rig = try Rig(bodies: [Body(id: 1, center: [0, 0])])
        var control = rig.substep
        control.time.y = 0.012
        rig.substep = control
        try rig.submit([.reduce])
        XCTAssertEqual(rig.substep.time.z, Float(1.0 / 60) - 0.012, accuracy: 1e-7)
        XCTAssertEqual(rig.substep.time.y, rig.substep.time.x, "upłynięcie ustawione dokładnie na czas kroku, bez dryfu sumy")
        // Po końcu kroku podkrok jest pusty: h = 0, zero grup, liczniki bez zmian.
        try rig.submit([.reduce])
        XCTAssertEqual(rig.substep.time.z, 0)
        XCTAssertEqual(rig.dispatchGroups, 0)
        XCTAssertEqual(rig.substep.counts.x, 1)
        XCTAssertEqual(rig.substep.counts.y, 1)
    }

    func testDispatchCoversEveryBubbleInGroupsOfTheFixedWidth() throws {
        let bodies = (0..<130).map { Body(id: $0 + 1, center: Point(Float($0) * 100, 0)) }
        let rig = try Rig(bodies: bodies)
        try rig.submit([.reduce])
        XCTAssertEqual(Int(rig.dispatchGroups), (130 + NativeMetalSubstep.groupWidth - 1) / NativeMetalSubstep.groupWidth)
    }

    func testStiffnessTermForAWallContactIsOneOverOmegaFromTheWallStiffnessAndMass() throws {
        // Przypadki, w których 1/ω jest mniejsze od kroku 1/60 (inaczej wyznaczałby h czas kroku).
        for (distance, mass, stiffness) in [(Float(2), Float(0.36), Float(229)), (0.4, 38, 229), (3, 1, 22_900)] {
            let rig = try Rig(bodies: [Body(id: 7, center: [100, -distance], mass: mass, radius: 12, stiffness: stiffness)],
                              segments: wallSegments(), rows: [wallRow])
            try rig.submit([.reduce])
            let k = wallStiffness(distance: Double(distance), radius: 12, stiffness: Double(stiffness))
            let expected = 1 / (k / Double(mass)).squareRoot()
            let control = rig.substep
            XCTAssertLessThanOrEqual(relative(Double(control.time.z), expected), 1e-3, "d \(distance), m \(mass), K \(stiffness)")
            XCTAssertEqual(control.limiter.y, NativeMetalSubstep.Term.stiffness.rawValue)
            XCTAssertEqual(control.limiter.x, 7, "obiekt: bańka o największym ω")
            XCTAssertLessThan(control.time.z, 1.0 / 60)
        }
    }

    func testStiffnessTermForAPairUsesGershgorinRowsWithTheLighterBubbleDeterminingOmega() throws {
        // Masy 1 i 4, ten sam materiał, nakładanie 21: ω₁² = k · (1/1 + 1/√4), ω₂² = k · (1/4 + 1/2); maksimum ma lżejsza.
        let a = Body(id: 5, center: [0, 0], mass: 1, radius: 12), b = Body(id: 9, center: [3, 0], mass: 4, radius: 12)
        let rig = try Rig(bodies: [a, b], rows: [[(1, 0)], [(0, 0)]])
        try rig.submit([.reduce])
        let k = try pairStiffness(overlap: 24 - 3, a: .init(radius: 12, stiffness: 229), b: .init(radius: 12, stiffness: 229))
        let expected = 1 / (k * 1.5).squareRoot()
        let control = rig.substep
        XCTAssertLessThanOrEqual(relative(Double(control.time.z), expected), 2e-3)
        XCTAssertEqual(control.limiter.x, 5, "obiekt: lżejsza bańka ma większe ω")
        XCTAssertEqual(control.limiter.y, NativeMetalSubstep.Term.stiffness.rawValue)
    }

    func testStaticNeighbourAddsNoPartnerTermToOmega() throws {
        // Bańka 1 przy statycznej bańce 2 (masa nieskończona): ω₁² = k / m₁, jak przy ścianie; statyczna nie wyznacza ω.
        let a = Body(id: 1, center: [0, 0], mass: 1, radius: 12), b = Body(id: 2, center: [3, 0], mass: 1, radius: 12, role: .static)
        let rig = try Rig(bodies: [a, b], rows: [[(1, 0)], [(0, 0)]])
        try rig.submit([.reduce])
        let k = try pairStiffness(overlap: 21, a: .init(radius: 12, stiffness: 229), b: .init(radius: 12, stiffness: 229))
        XCTAssertLessThanOrEqual(relative(Double(rig.substep.time.z), 1 / k.squareRoot()), 2e-3)
        XCTAssertEqual(rig.substep.limiter.x, 1)
    }

    func testPairWithDifferentStiffnessUsesTwoSpringsInSeries() throws {
        let a = Body(id: 3, center: [0, 0], mass: 1, radius: 12, stiffness: 229)
        let b = Body(id: 4, center: [6, 0], mass: 1, radius: 20, stiffness: 22_900)
        let rig = try Rig(bodies: [a, b], rows: [[(1, 0)], [(0, 0)]])
        try rig.submit([.reduce])
        let overlap = 32.0 - 6.0
        let pair = try XCTUnwrap(ContactLawReference.pairContact(overlap: overlap, a: .init(radius: 12, stiffness: 229),
                                                                  b: .init(radius: 20, stiffness: 22_900)))
        let h = 1e-5
        let up = try XCTUnwrap(ContactLawReference.pairContact(overlap: overlap + h, a: .init(radius: 12, stiffness: 229),
                                                               b: .init(radius: 20, stiffness: 22_900))).force
        let down = try XCTUnwrap(ContactLawReference.pairContact(overlap: overlap - h, a: .init(radius: 12, stiffness: 229),
                                                                 b: .init(radius: 20, stiffness: 22_900))).force
        XCTAssertGreaterThan(pair.force, 0)
        let k = (up - down) / (2 * h)
        XCTAssertLessThanOrEqual(relative(Double(rig.substep.time.z), 1 / (k * 2).squareRoot()), 5e-3, "równe masy 1: ω² = k · (1 + 1) = 2k")
    }

    /// Wymóg drogi d / 4 w podkroku, z wyrazem przyspieszenia: h = d / (2 (s + v)), s = √(v² + A d / 2).
    private func distanceBound(distance: Double, speed: Double, accelerationSum: Double) -> Double {
        let s = (speed * speed + accelerationSum * distance / 2).squareRoot()
        return distance / (2 * (s + speed))
    }

    func testDistanceTermLimitsAnApproachingCandidateWithoutContactToAQuarterOfTheDistance() throws {
        // Środek 14 od ściany, promień 12: kandydat bez kontaktu, zbliża się z 1000 j/s, a = 0: h = d / (4 v).
        let rig = try Rig(bodies: [Body(id: 21, center: [100, -14], velocity: [0, 1000])], segments: wallSegments(), rows: [wallRow])
        try rig.submit([.reduce])
        let control = rig.substep
        XCTAssertLessThanOrEqual(relative(Double(control.time.z), 14.0 / 4000), 1e-4)
        XCTAssertEqual(control.limiter.y, NativeMetalSubstep.Term.distance.rawValue)
        XCTAssertEqual(control.limiter.x, 21)
    }

    func testDistanceTermExemptsACandidateWithoutContactThatMovesAwayButNotOneThatWillTurnBack() throws {
        // Oddala się z 1000 j/s, a = 0: wypada z nierówności, h = czas kroku.
        let away = try Rig(bodies: [Body(id: 1, center: [100, -14], velocity: [0, -1000])], segments: wallSegments(), rows: [wallRow])
        try away.submit([.reduce])
        XCTAssertEqual(away.substep.time.z, 1.0 / 60)
        XCTAssertEqual(away.substep.limiter.y, NativeMetalSubstep.Term.remainingTime.rawValue)
        // Oddala się, ale przyspieszenie w stronę ściany (g = 1e6) zawróci ją w krok: nie wypada, h z równania kwadratowego.
        let turning = try Rig(bodies: [Body(id: 2, center: [100, -14], velocity: [0, -100], mass: 1)], segments: wallSegments(),
                              rows: [wallRow])
        turning.setAcceleration(0, [0, 1e6])
        try turning.submit([.reduce])
        let hMax = 1.0 / 60
        XCTAssertGreaterThan(-100 + 1e6 * hMax / 2, 0, "warunek wypadnięcia z nierówności nie zachodzi")
        let expected = distanceBound(distance: 14, speed: -100, accelerationSum: 1e6)
        XCTAssertLessThanOrEqual(relative(Double(turning.substep.time.z), expected), 1e-3)
        XCTAssertEqual(turning.substep.limiter.y, NativeMetalSubstep.Term.distance.rawValue)
    }

    func testDistanceTermAppliesToAnActiveContactInBothDirections() throws {
        // Kontakt aktywny (d = 8 < r = 12): ta sama droga d / 4 przy dojeździe i przy odjeździe, z przyspieszeniem z kontaktu.
        var results: [Float] = []
        for velocity: Float in [1000, -1000] {
            let rig = try Rig(bodies: [Body(id: 6, center: [100, -8], velocity: [0, velocity], mass: 0.36)], segments: wallSegments(),
                              rows: [wallRow])
            try rig.submit([.contactForces, .integrate(.initialAcceleration)])
            let force = ContactLawReference.force(epsilon: 1 - 8.0 / 12, stiffness: 229)
            let a = force / 0.36
            XCTAssertLessThanOrEqual(relative(Double(simd_length(rig.acceleration(0))), a), 1e-3)
            try rig.submit([.reduce])
            XCTAssertLessThanOrEqual(relative(Double(rig.substep.time.z), distanceBound(distance: 8, speed: 1000, accelerationSum: a)), 2e-3,
                                     "v = \(velocity)")
            XCTAssertEqual(rig.substep.limiter.y, NativeMetalSubstep.Term.distance.rawValue)
            results.append(rig.substep.time.z)
        }
        XCTAssertEqual(results[0], results[1], "|v| decyduje, nie kierunek")
    }

    func testDistanceTermForAPairUsesTheRelativeVelocityAlongTheCentreLineAndBothAccelerations() throws {
        // Dwie bańki dalej niż R, zbliżają się wzdłuż osi z 400 i 600 j/s: względna prędkość zbliżania 1000.
        let a = Body(id: 1, center: [0, 0], velocity: [400, 3], mass: 1, radius: 12)
        let b = Body(id: 2, center: [30, 0], velocity: [-600, -7], mass: 1, radius: 12)
        let rig = try Rig(bodies: [a, b], rows: [[(1, 0)], [(0, 0)]])
        try rig.submit([.reduce])
        XCTAssertLessThanOrEqual(relative(Double(rig.substep.time.z), 30.0 / 4000), 1e-4, "prędkości styczne nie wchodzą do v_n")
        XCTAssertEqual(rig.substep.limiter.y, NativeMetalSubstep.Term.distance.rawValue)
    }

    func testReductionTakesTheMinimumOfAllTermsAcrossBubblesAndRowsAndBreaksTiesByIndex() throws {
        // Dwa jednakowe kandydaty ze ścianą (te same d i v): wyznacza ten z mniejszym indeksem.
        let rig = try Rig(bodies: [Body(id: 31, center: [60, -14], velocity: [0, 1000]), Body(id: 32, center: [140, -14], velocity: [0, 1000]),
                                   Body(id: 33, center: [100, -14], velocity: [0, 100])],
                          segments: wallSegments(), rows: [wallRow, wallRow, wallRow])
        try rig.submit([.reduce])
        XCTAssertEqual(rig.substep.limiter.x, 31)
        XCTAssertLessThanOrEqual(relative(Double(rig.substep.time.z), 14.0 / 4000), 1e-4)
    }

    func testFrameLimitSetsTheFlagKeepsTheLastLimiterAndMakesTheSubstepEmpty() throws {
        let rig = try Rig(bodies: [Body(id: 1, center: [0, 0])])
        var control = rig.substep
        control.counts = SIMD4(1, UInt32(NativeMetalSubstep.frameLimit), 0, 0)
        control.limiter = SIMD2(77, NativeMetalSubstep.Term.distance.rawValue)
        control.time.y = 0.001
        rig.substep = control
        try rig.submit([.reduce])
        let after = rig.substep
        XCTAssertEqual(after.counts.w, 1, "znacznik limitu")
        XCTAssertEqual(after.time.z, 0)
        XCTAssertEqual(after.counts.y, UInt32(NativeMetalSubstep.frameLimit), "podkrok nie jest liczony")
        XCTAssertEqual(after.limiter, SIMD2<UInt64>(77, NativeMetalSubstep.Term.distance.rawValue), "obiekt i człon z ostatniego podkroku")
        XCTAssertEqual(rig.dispatchGroups, 0)
        // Dokładnie 1024 podkroki są dozwolone: limit działa dopiero przy próbie kolejnego, gdy czas jeszcze został.
        var exact = rig.substep
        exact.counts = SIMD4(1, UInt32(NativeMetalSubstep.frameLimit - 1), 0, 0)
        exact.time.y = 0.001
        exact.time.z = 0
        exact.limiter = .zero
        rig.substep = exact
        try rig.submit([.reduce])
        XCTAssertEqual(rig.substep.counts.w, 0)
        XCTAssertEqual(rig.substep.counts.y, UInt32(NativeMetalSubstep.frameLimit))
    }

    func testFrameLimitIsNotRaisedWhenTheStepIsAlreadyOver() throws {
        let rig = try Rig(bodies: [Body(id: 1, center: [0, 0])])
        var control = rig.substep
        control.counts = SIMD4(1, UInt32(NativeMetalSubstep.frameLimit), 0, 0)
        control.time.y = control.time.x
        rig.substep = control
        try rig.submit([.reduce])
        XCTAssertEqual(rig.substep.counts.w, 0, "krok skończony dokładnie w 1024. podkroku to nie przekroczenie")
        XCTAssertEqual(rig.dispatchGroups, 0)
    }

    // MARK: Zapas obwiedni: tryb minimalny i człon h_zapasu (CD-D-23)

    func testMinimumMarginOnlyDropsTheMotionTermAndKeepsAQuarterRadius() throws {
        let bodies = [Body(id: 1, center: [100, 200], velocity: [3000, 0], mass: 0.36, radius: 12),
                      Body(id: 2, center: [0, 0], velocity: [0, 0], mass: 0.5, radius: 40)]
        let rig = try Rig(bodies: bodies, forces: NativeForceInput(objects: [], globalForce: [50, 0]))
        rig.minimumMarginOnly = true
        try rig.submit([.acceleration, .margin])
        XCTAssertEqual(rig.margin(0), 3, "szybka bańka dostaje tylko r / 4")
        XCTAssertEqual(rig.margin(1), 10)
        for index in 0..<2 { XCTAssertEqual(rig.reference(index), bodies[index].center, "x₀ ← x także w trybie minimalnym") }
        rig.minimumMarginOnly = false
        try rig.submit([.margin])
        XCTAssertGreaterThan(rig.margin(0), 40, "bez przełącznika człon ruchu: 1,05 · 3000 / 60 = 52,5")
    }

    /// Największe h z ½ a h² + v h = zapas (a stałe w podkroku), w Double.
    private func marginBound(left: Double, speed: Double, acceleration: Double) -> Double {
        if acceleration == 0 { return left / speed }
        return (-speed + (speed * speed + 2 * acceleration * left).squareRoot()) / acceleration
    }

    func testMarginTermSetsHFromTheRemainingMarginAndFlagsARebuildAfterThatSubstep() throws {
        for (speed, acceleration) in [(Double(1000), Double(0)), (200, 1e5), (0, 4e5)] {
            let rig = try Rig(bodies: [Body(id: 9, center: [10, 20], velocity: [Float(speed), 0], mass: 0.36)])
            // Zapas 6 j, bańka przesunęła się o 4 j od x₀: zostają 2 j.
            rig.setMargin(0, 6, reference: [6, 20])
            rig.setAcceleration(0, [Float(acceleration), 0])
            try rig.submit([.reduce])
            let control = rig.substep
            let expected = marginBound(left: 2, speed: speed, acceleration: acceleration)
            XCTAssertLessThan(expected, 1.0 / 60, "człon zapasu ma wyznaczać h")
            XCTAssertLessThanOrEqual(relative(Double(control.time.z), expected), 1e-3, "v \(speed), a \(acceleration)")
            XCTAssertEqual(control.limiter.y, NativeMetalSubstep.Term.margin.rawValue)
            XCTAssertEqual(control.limiter.x, 9, "obiekt: bańka z wyczerpywanym zapasem")
            XCTAssertEqual(control.counts.z, 1, "znacznik przebudowy po tym podkroku")
            XCTAssertEqual(control.counts.y, 1, "ten podkrok się odbywa")
            XCTAssertEqual(rig.dispatchGroups, 1)
            // Następny podkrok tego bufora jest pusty.
            let time = control.time.y
            try rig.submit([.reduce])
            XCTAssertEqual(rig.substep.time.z, 0)
            XCTAssertEqual(rig.substep.time.y, time, "czas nie płynie po znaczniku")
            XCTAssertEqual(rig.substep.counts.y, 1)
            XCTAssertEqual(rig.dispatchGroups, 0)
        }
    }

    func testMarginTermUsesTheDistanceFromTheReferenceNotThePathTravelled() throws {
        // Bańka stoi 0,5 j od x₀ (zapas 6) i leci w stronę x₀. Człon jest ostrożny, bo liczy |x − x₀| + |v| h bez kierunku: h = (6 − 0,5) / v.
        let rig = try Rig(bodies: [Body(id: 3, center: [0.5, 0], velocity: [-1000, 0])])
        rig.setMargin(0, 6, reference: [0, 0])
        try rig.submit([.reduce])
        XCTAssertLessThanOrEqual(relative(Double(rig.substep.time.z), 5.5 / 1000), 1e-3,
                                 "zostaje 6 − 0,5 j, liczone od odległości od x₀, nie od przebytej drogi")
        XCTAssertEqual(rig.substep.limiter.y, NativeMetalSubstep.Term.margin.rawValue)
    }

    func testEnoughMarginLeavesHAndTheFlagUntouched() throws {
        // v = 100: w całym kroku bańka przejdzie 1,67 j < zapas 6.
        let rig = try Rig(bodies: [Body(id: 1, center: [0, 0], velocity: [100, 0])])
        rig.setMargin(0, 6, reference: [0, 0])
        try rig.submit([.reduce])
        XCTAssertEqual(rig.substep.time.z, 1.0 / 60)
        XCTAssertEqual(rig.substep.counts.z, 0)
        XCTAssertEqual(rig.substep.limiter.y, NativeMetalSubstep.Term.remainingTime.rawValue)
    }

    func testMarginTermDoesNotFlagWhenAnotherTermIsSmaller() throws {
        // Kandydat do ściany 14 j, v = 1000: d / 4 daje 3,5 ms, zapas 6 j starczyłby na 6 ms.
        let rig = try Rig(bodies: [Body(id: 21, center: [100, -14], velocity: [0, 1000])], segments: wallSegments(), rows: [wallRow])
        rig.setMargin(0, 6, reference: [100, -14])
        try rig.submit([.reduce])
        XCTAssertEqual(rig.substep.limiter.y, NativeMetalSubstep.Term.distance.rawValue)
        XCTAssertEqual(rig.substep.counts.z, 0, "człon zapasu nie wyznaczył h, więc nie ma przebudowy")
    }

    func testExhaustedMarginFlagsARebuildInsteadOfMakingATinySubstep() throws {
        // Bańka jest już 6 j od x₀ przy zapasie 6, a druga 7 j: żadna nie ma zapasu.
        for offset: Float in [6, 7] {
            let rig = try Rig(bodies: [Body(id: 4, center: [offset, 0], velocity: [1000, 0])])
            rig.setMargin(0, 6, reference: [0, 0])
            try rig.submit([.reduce])
            let control = rig.substep
            XCTAssertEqual(control.counts.z, 1, "przesunięcie \(offset)")
            XCTAssertEqual(control.time.z, 0)
            XCTAssertEqual(control.time.y, 0, "czas nie płynie")
            XCTAssertEqual(control.counts.y, 0, "podkrok pusty nie jest liczony")
            XCTAssertEqual(rig.dispatchGroups, 0)
        }
    }

    func testStaticBubblesNeverExhaustTheirMargin() throws {
        let rig = try Rig(bodies: [Body(id: 1, center: [50, 0], velocity: [1000, 0], role: .static)])
        rig.setMargin(0, 0, reference: [0, 0])
        try rig.submit([.reduce])
        XCTAssertEqual(rig.substep.counts.z, 0)
        XCTAssertEqual(rig.substep.time.z, 1.0 / 60)
    }

    func testRebuildFlagMakesTheRemainingSubstepsOfTheBufferEmpty() throws {
        let rig = try Rig(bodies: [Body(id: 1, center: [0, 0])])
        var control = rig.substep
        control.counts.z = 1
        rig.substep = control
        try rig.submit([.reduce])
        XCTAssertEqual(rig.substep.time.z, 0)
        XCTAssertEqual(rig.substep.time.y, 0, "czas nie płynie")
        XCTAssertEqual(rig.substep.counts.y, 0)
        XCTAssertEqual(rig.dispatchGroups, 0)
    }

    // MARK: nativeIntegrateSubstep

    func testExactHalfImpulsesGiveTheExactVelocityUnderConstantForceForAnyDamping() throws {
        // Siła globalna 3 na masę 0,5: a = 6. Dwa półimpulsy z oporem składają się w v₁ = v₀ e^(−γh) + a (1 − e^(−γh)) / γ.
        for gamma: Float in [0, 1, 5, 40] {
            let rig = try Rig(bodies: [Body(id: 1, center: [0, 0], velocity: [10, -4], mass: 0.5, damping: gamma)],
                              forces: NativeForceInput(objects: [], globalForce: [3, 0]))
            try rig.runFrame()
            XCTAssertEqual(rig.substep.counts.y, 1)
            let h = 1.0 / 60.0, a = 6.0, g = Double(gamma)
            let decay = exp(-g * h)
            let vx = g == 0 ? 10 + a * h : 10 * decay + a * (1 - decay) / g
            let vy = -4 * decay
            let bubble = rig.bubble(0)
            XCTAssertLessThanOrEqual(abs(Double(bubble.motion.x) - vx), 2e-5 * max(1, abs(vx)), "γ \(gamma)")
            XCTAssertLessThanOrEqual(abs(Double(bubble.motion.y) - vy), 2e-5 * max(1, abs(vy)), "γ \(gamma)")
            // Położenie: x₀ + h · v w połowie kroku (v po pierwszym półimpulsie).
            let half = exp(-g * h / 2)
            let midX = g == 0 ? 10 + a * h / 2 : 10 * half + a * (1 - half) / g
            XCTAssertLessThanOrEqual(abs(Double(bubble.position.x) - h * midX), 1e-5, "γ \(gamma)")
        }
    }

    func testTerminalVelocityUnderConstantForceIsExactlyForceOverDampingAtAnyStep() throws {
        // Prędkość ustalona a / γ nie zależy od h: 600 klatek 1/60 (10 s) przy γ = 5 i a = 6 daje 1,2; to samo przy 4-krotnie dłuższym kroku.
        for step: Float in [1.0 / 60, 4.0 / 60] {
            let rig = try Rig(bodies: [Body(id: 1, center: [0, 0], mass: 0.5, damping: 5)],
                              forces: NativeForceInput(objects: [], globalForce: [3, 0]), step: step)
            for _ in 0..<Int(10 / step) { try rig.runFrame() }
            XCTAssertEqual(rig.bubble(0).motion.x, 1.2, accuracy: 1e-4, "krok \(step)")
        }
    }

    func testNonForceRolesGetNeitherDampingNorFieldsAndStaticBubblesDoNotMove() throws {
        let bodies = [Body(id: 1, center: [0, 0], velocity: [20, 0], damping: 5, role: .path),
                      Body(id: 2, center: [50, 0], velocity: [20, 0], damping: 5, role: .static),
                      Body(id: 3, center: [100, 0], velocity: [20, 0], damping: 5)]
        let rig = try Rig(bodies: bodies, forces: NativeForceInput(objects: [], globalForce: [100, 0]))
        try rig.runFrame()
        let h = Float(1.0 / 60)
        XCTAssertEqual(rig.bubble(0).motion.x, 20, "tor: ani opór, ani siła globalna")
        XCTAssertEqual(rig.bubble(0).position.x, 20 * h, accuracy: 1e-5, "porusza się z prędkością z hosta")
        XCTAssertEqual(rig.bubble(1).position.x, 50, "statyczna stoi")
        XCTAssertEqual(rig.bubble(1).motion.x, 20, "statyczna: stan prędkości nietknięty przez całkowanie")
        XCTAssertLessThan(rig.bubble(2).motion.x, 100, "napędzana siłami: opór i siła")
        XCTAssertNotEqual(rig.bubble(2).motion.x, 20)
    }

    func testRotationAdvancesByAngularVelocityAndDecaysWithDampingForForceRoles() throws {
        var body = Body(id: 1, center: [0, 0], damping: 3)
        body.velocity = .zero
        let rig = try Rig(bodies: [body])
        var bubble = rig.bubble(0)
        bubble.motion.w = 2
        rig.state.workingBubbles.contents().bindMemory(to: NativeMetalBubble.self, capacity: 1)[0] = bubble
        try rig.runFrame()
        let h = 1.0 / 60
        XCTAssertEqual(Double(rig.bubble(0).motion.z), 2 * h, accuracy: 1e-6)
        XCTAssertEqual(Double(rig.bubble(0).motion.w), 2 * exp(-3 * h), accuracy: 1e-5)
    }

    func testIdleSubstepsAfterTheEndOfTheStepChangeNothingAndAddNoSubsteps() throws {
        // Jak w buforze z zapasem podkroków: po końcu kroku kolejne podkroki to dyspozycje z zerem grup.
        func finalState(extra: Int) throws -> (NativeMetalBubble, NativeMetalSubstepControl) {
            let rig = try Rig(bodies: [Body(id: 1, center: [100, -14], velocity: [0, 1000], mass: 0.36)], segments: wallSegments(),
                              rows: [wallRow])
            try rig.beginFrame()
            var steps: [Step] = []
            for _ in 0..<(1 + extra) { steps += rig.substepSequence() }
            try rig.submit(steps)
            return (rig.bubble(0), rig.substep)
        }
        // Najpierw sprawdzamy, ile podkroków potrzebuje krok, potem dajemy tyle samo z nadmiarem.
        let probe = try Rig(bodies: [Body(id: 1, center: [100, -14], velocity: [0, 1000], mass: 0.36)], segments: wallSegments(), rows: [wallRow])
        let needed = try probe.runFrame()
        XCTAssertGreaterThan(needed, 3)
        let exact = try finalState(extra: needed - 1)
        let surplus = try finalState(extra: 2 * needed)
        XCTAssertEqual(exact.1.counts.y, UInt32(needed))
        XCTAssertEqual(surplus.1.counts.y, UInt32(needed), "puste podkroki nie są liczone")
        XCTAssertEqual(surplus.0.position, exact.0.position, "bez zmiany stanu po końcu kroku")
        XCTAssertEqual(surplus.0.motion, exact.0.motion)
        XCTAssertEqual(surplus.1.time.y, surplus.1.time.x)
    }

    // MARK: Odbicie od ściany: reguła h, zachowanie energii, zapis podkroków

    /// Scena 1D z odniesienia: bańka „2” (r 12, m 0,36, K 229) leci na ścianę z prędkością v. Dystans startowy to odległość od ściany.
    private func bounceRig(speed: Float, startDistance: Float = 80, damping: Float = 0, capture: Bool = false) throws -> Rig {
        try Rig(bodies: [Body(id: 1, center: [100, -startDistance], velocity: [0, speed], mass: 0.36, radius: 12, stiffness: 229, damping: damping)],
                segments: wallSegments(), rows: [wallRow], capture: capture)
    }

    func testBouncePerpendicularToTheWallMatchesTheOneDimensionalHRuleSimulationAndReturnsTheSpeedWithinTwoPercent() throws {
        for speed: Float in [1000, 3000] {
            let startDistance: Float = 80
            let rig = try bounceRig(speed: speed, startDistance: startDistance, capture: true)
            let reference = ContactLawReference.WallScene(radius: 12, mass: 0.36, stiffness: 229, damping: 0, startDistance: Double(startDistance),
                velocity: -Double(speed)).run(frames: 40)
            XCTAssertFalse(reference.penetrated)
            var counts: [Int] = [], minimum = Float.infinity, rebound: Float?
            for frame in 0..<min(40, reference.frames.count) {
                counts.append(try rig.runFrame())
                let bubble = rig.bubble(0)
                let distance = -bubble.position.y
                // Najgłębszy punkt to minimum po podkrokach klatki (zapis podkroków), nie po końcach klatek.
                for sample in rig.state.capturedSubsteps(bubbleIDs: rig.ids) { minimum = min(minimum, -(sample.bubbles[1]?.position.y ?? 0)) }
                XCTAssertGreaterThan(distance, 0, "środek po stronie startowej po każdej klatce, v \(speed), klatka \(frame)")
                XCTAssertEqual(rig.substep.counts.w, 0)
                // Stan końca klatki zgodny z odniesieniem: położenie do 0,3 j, prędkość do 3 % prędkości początkowej.
                XCTAssertLessThanOrEqual(abs(Double(distance) - reference.frames[frame].distance), 0.3, "v \(speed), klatka \(frame)")
                XCTAssertLessThanOrEqual(abs(Double(-bubble.motion.y) - reference.frames[frame].velocity), 0.03 * Double(speed),
                                         "v \(speed), klatka \(frame)")
                if bubble.motion.y < 0, distance > 12 { rebound = -bubble.motion.y; break }
            }
            let out = try XCTUnwrap(rebound, "bańka wróciła poza zasięg kontaktu, v \(speed)")
            XCTAssertLessThanOrEqual(abs(out - speed) / speed, 0.02, "prędkość odbicia ± 2 %, v \(speed): \(out)")
            // Szczyt liczby podkroków wobec symulacji 1D reguły h (to samo ± 25 %: GPU ma jeszcze człon przyspieszenia).
            let peak = counts.max() ?? 0, referencePeak = reference.frames.map(\.substeps).max() ?? 0
            XCTAssertLessThanOrEqual(abs(Double(peak) - Double(referencePeak)), 0.25 * Double(referencePeak), "v \(speed): \(peak) wobec \(referencePeak)")
            // Najgłębszy punkt z bilansu energii (U(ε) = ½ m v²), ± 10 %.
            let epsilon = ContactLawReference.maximumEpsilon(energy: 0.5 * 0.36 * Double(speed * speed), stiffness: 229, radius: 12)
            let dMinimum = 12 * (1 - epsilon)
            XCTAssertLessThanOrEqual(abs(Double(minimum) - dMinimum), 0.1 * dMinimum + 1e-3, "v \(speed): \(minimum) wobec \(dMinimum)")
        }
    }

    func testCapturedSubstepsSumToTheStepAndEndAtTheFinalState() throws {
        let rig = try bounceRig(speed: 1000, startDistance: 60, capture: true)
        // Kontakt zaczyna się w 4. klatce (lot 1000 / 60 ≈ 16,7 j na klatkę); bierzemy klatkę z największą liczbą podkroków.
        var deepest: (samples: [NativeMetalSubstepSample], position: Point, velocity: Point, count: Int)?
        for _ in 1...10 {
            let count = try rig.runFrame()
            let samples = rig.state.capturedSubsteps(bubbleIDs: rig.ids)
            XCTAssertEqual(samples.count, count, "jedna próbka na podkrok klatki; zapis zaczyna się od początku w każdej klatce")
            if count > (deepest?.count ?? 0) {
                deepest = (samples, [rig.bubble(0).position.x, rig.bubble(0).position.y], [rig.bubble(0).motion.x, rig.bubble(0).motion.y], count)
            }
            if rig.bubble(0).motion.y < 0 { break }
        }
        let frame = try XCTUnwrap(deepest)
        XCTAssertGreaterThan(frame.count, 10)
        let sum = frame.samples.reduce(0.0) { $0 + Double($1.h) }
        XCTAssertLessThanOrEqual(abs(sum - 1.0 / 60), 1e-6, "h klatki sumuje się do kroku")
        XCTAssertTrue(frame.samples.allSatisfy { $0.h > 0 && $0.bubbles.count == 1 })
        let last = try XCTUnwrap(frame.samples.last?.bubbles[1])
        XCTAssertEqual(last.position, frame.position, "ostatni podkrok kończy się stanem końca klatki")
        XCTAssertEqual(last.velocity, frame.velocity)
        // Ciągła trajektoria: przesunięcie w podkroku to h razy prędkość w połowie podkroku, a ta mieści się między prędkościami końców.
        var previous = frame.samples[0].bubbles[1]!
        for sample in frame.samples.dropFirst() {
            let body = try XCTUnwrap(sample.bubbles[1])
            let travelled = abs(body.position.y - previous.position.y)
            let bound = max(abs(body.velocity.y), abs(previous.velocity.y)) * sample.h * 1.05 + 1e-4
            XCTAssertLessThanOrEqual(travelled, bound, "h \(sample.h)")
            previous = body
        }
    }

    func testCaptureBufferIsAbsentWithoutTheSwitch() throws {
        let rig = try bounceRig(speed: 10)
        XCTAssertNil(rig.state.substepCapture)
        try rig.runFrame()
        XCTAssertTrue(rig.state.capturedSubsteps(bubbleIDs: rig.ids).isEmpty)
    }

    func testPairBounceConservesMomentumExactlyAndEnergyWithinTheLeapfrogError() throws {
        // Czołowe zderzenie baniek o różnych masach: siły pary są dokładnie przeciwne, więc pęd zachowuje się z dokładnością float.
        let a = Body(id: 1, center: [0, 0], velocity: [600, 0], mass: 0.36, radius: 12)
        let b = Body(id: 2, center: [60, 0], velocity: [-400, 0], mass: 1.5, radius: 12)
        let rig = try Rig(bodies: [a, b], rows: [[(1, 0)], [(0, 0)]])
        let momentum = Double(a.mass * a.velocity.x + b.mass * b.velocity.x)
        let energy = 0.5 * 0.36 * 600.0 * 600 + 0.5 * 1.5 * 400 * 400
        var separated = false
        for _ in 0..<12 {
            try rig.runFrame()
            XCTAssertEqual(rig.substep.counts.w, 0)
            let first = rig.bubble(0), second = rig.bubble(1)
            let p = Double(0.36 * first.motion.x + 1.5 * second.motion.x)
            XCTAssertLessThanOrEqual(abs(p - momentum), 2e-4 * max(1, abs(momentum)) * 10, "pęd")
            XCTAssertLessThan(first.position.x, second.position.x, "bez zamiany stron")
            if second.position.x - first.position.x > 24, first.motion.x < second.motion.x { separated = true; break }
        }
        XCTAssertTrue(separated)
        let first = rig.bubble(0), second = rig.bubble(1)
        let after = 0.5 * 0.36 * Double(first.motion.x * first.motion.x) + 0.5 * 1.5 * Double(second.motion.x * second.motion.x)
        XCTAssertLessThanOrEqual(abs(after - energy) / energy, 0.02, "energia po rozdzieleniu ± 2 %")
    }
}
