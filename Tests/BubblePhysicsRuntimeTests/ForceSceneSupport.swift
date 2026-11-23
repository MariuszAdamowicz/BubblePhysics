@testable import BubblePhysics
import BubblePhysicsNativeMetal
import Metal
import XCTest
import simd

/// Wspólne budowanie scen i odczyt wyników dla testów świata silnika 4.0.0 (plan `docs/sdlc/changes/2026-11-23-engine-4-0-0`, zadanie 5).
/// Testy świata tworzą go przez pakietowe `BubbleWorld.makeBenchmarkWorld(configuration:device:native:)`, więc przełączniki podkroków
/// (`substepSplitMultiplier`, `minimumMarginOnly`, `captureSubsteps`, `assertEverySubstep`, `injectedSubstepState`) idą z konfiguracji natywnej.
/// Odniesienie liczbowe jest w `ContactLawReference`; ten plik nie zna prawa kontaktu, tylko układa sceny i mierzy.
///
/// Bańki gry: „2” (r 24, m 1), 128 (r 64, m ≈ 6,35) i 7168 (r 148, m ≈ 38); masa gry m = (n/2)^(1/2,25).
@MainActor
enum ForceScene {
    nonisolated static let step = 1.0 / 60
    nonisolated static let stiffness: Float = 229

    nonisolated static let bubbleMaterial = PhysicsMaterialID(rawValue: 1)
    nonisolated static let wallMaterial = PhysicsMaterialID(rawValue: 2)
    nonisolated static let secondBubbleMaterial = PhysicsMaterialID(rawValue: 3)
    nonisolated static let style = RenderMaterialID(rawValue: 1)

    struct Kind: Sendable {
        var radius: Float
        var mass: Float
    }

    nonisolated static func gameMass(_ n: Double) -> Float { Float(pow(n / 2, 1 / 2.25)) }
    nonisolated static let two = Kind(radius: 24, mass: 1)
    nonisolated static let b128 = Kind(radius: 64, mass: gameMass(128))
    nonisolated static let b7168 = Kind(radius: 148, mass: gameMass(7168))

    nonisolated static func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }

    // MARK: świat

    static func configuration(half: Float) throws -> WorldConfiguration {
        try WorldConfiguration(simulationRegion: WorldRectangle(min: [-half, -half], max: [half, half]), fixedTimeStep: step,
                               eventBufferCapacity: 4096)
    }

    /// Świat z materiałami (bańka K_c, γ; opcjonalnie druga bańka o innym K_c; sztywna bryła) i sceną z `build`. Bez Metal test się pomija.
    static func makeWorld(half: Float = 2000, damping: Float = 0, stiffness: Float = ForceScene.stiffness, secondStiffness: Float? = nil,
                          region: WorldRectangle? = nil, native: NativeMetalConfiguration = .default,
                          build: (WorldTransaction) throws -> WorldTransaction) throws -> BubbleWorld {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("brak urządzenia Metal") }
        let configuration = try region.map { try WorldConfiguration(simulationRegion: $0, fixedTimeStep: step, eventBufferCapacity: 4096) }
            ?? self.configuration(half: half)
        let world = try BubbleWorld.makeBenchmarkWorld(configuration: configuration, device: device, native: native)
        var setup = WorldTransaction()
            .updatePhysicsMaterial(bubbleMaterial, material: try PhysicsMaterial(kind: .bubble, contactStiffness: stiffness, damping: damping))
            .updatePhysicsMaterial(wallMaterial, material: try PhysicsMaterial(kind: .rigid))
            .updateRenderMaterial(style, material: try RenderMaterial())
        if let secondStiffness {
            setup = setup.updatePhysicsMaterial(secondBubbleMaterial,
                                                material: try PhysicsMaterial(kind: .bubble, contactStiffness: secondStiffness, damping: damping))
        }
        _ = world.submit(try build(setup))
        return world
    }

    // MARK: obiekty

    static func bubble(_ value: UInt64, at position: WorldPoint, _ kind: Kind = two, velocity: WorldPoint = .zero,
                       radius: Float? = nil, material: PhysicsMaterialID = bubbleMaterial, role: MotionRole = .dynamic,
                       filter: CollisionFilter = .default, drivePolicy: BubbleDrivePolicy? = nil,
                       regionExitPolicy: RegionExitPolicy = .remove, events: EventInterest = []) throws -> WorldObject {
        .bubble(try BubbleDescriptor(id: id(value), position: position, velocity: velocity, targetRadius: radius ?? kind.radius,
                                     mass: kind.mass, motionRole: role, regionExitPolicy: regionExitPolicy, physicsMaterialID: material,
                                     renderMaterialID: style, eventInterest: events, drivePolicy: drivePolicy, filter: filter))
    }

    /// Cienka pionowa ściana wypełniająca x ∈ [x, x + thickness], y ∈ [−halfHeight, halfHeight]; bańka z lewej widzi płaszczyznę x.
    static func wall(_ value: UInt64, x: Float, thickness: Float = 1, halfHeight: Float = 1900,
                     filter: CollisionFilter = .default) throws -> WorldObject {
        .rigidBody(try RigidBodyDescriptor(id: id(value),
            vertices: [[x, -halfHeight], [x + thickness, -halfHeight], [x + thickness, halfHeight], [x, halfHeight]],
            motionRole: .static, physicsMaterialID: wallMaterial, renderMaterialID: style, filter: filter))
    }

    /// Kwadrat o boku `side` o środku w `position`.
    static func square(_ value: UInt64, at position: WorldPoint, side: Float, role: MotionRole = .static, rotation: Float = 0,
                       filter: CollisionFilter = .default) throws -> WorldObject {
        let h = side / 2
        return .rigidBody(try RigidBodyDescriptor(id: id(value), vertices: [[-h, -h], [h, -h], [h, h], [-h, h]], position: position,
            rotation: rotation, mass: 1, motionRole: role, physicsMaterialID: wallMaterial, renderMaterialID: style, filter: filter))
    }

    static func rigid(_ value: UInt64, _ shape: RigidShape, at position: WorldPoint, rotation: Float = 0,
                      role: MotionRole = .static, filter: CollisionFilter = .default) throws -> WorldObject {
        .rigidBody(try RigidBodyDescriptor(id: id(value), shape: shape, position: position, rotation: rotation, mass: 1,
                                           motionRole: role, physicsMaterialID: wallMaterial, renderMaterialID: style, filter: filter))
    }

    /// Pole kierunkowe działające tylko na `target` (siła stała w całym kole o promieniu 1500 wokół `center`).
    static func push(_ value: UInt64, on target: UInt64, force: WorldPoint, around center: WorldPoint) throws -> WorldObject {
        .forceField(try ForceFieldDescriptor(id: id(value), position: center, geometry: .circle(radius: 1500),
                                             field: .directional(force: force), filter: ObjectFilter(objectIDs: [id(target)])))
    }

    // MARK: przebieg

    struct Recorded {
        var step: Int
        var frame: WorldFrame
        var telemetry: NativeMetalFrameTelemetry?
        /// Podkroki tego kroku (puste bez `captureSubsteps`).
        var samples: [NativeMetalSubstepSample]
        var issue: WorldAdvanceIssue?

        func position(_ value: UInt64) -> WorldPoint? { frame.objects[ForceScene.id(value)]?.position }
        func velocity(_ value: UInt64) -> WorldPoint? { frame.objects[ForceScene.id(value)]?.velocity }
    }

    /// Kroki po jednym `advance(by: 1/60)`. `before` może dać transakcję wysyłaną przed krokiem o danym numerze (od 0), `until` kończy
    /// przebieg po zapisaniu kroku. Przebieg kończy się też po pierwszym kroku z `lastAdvanceIssue` (ten krok jest zapisany), a pierwszy krok
    /// bez potwierdzenia sceny kończy go z błędem testu. Wywołujący sam ocenia `world.diagnostics`.
    static func run(_ world: BubbleWorld, frames: Int, before: ((Int) throws -> WorldTransaction?)? = nil,
                    until: ((Recorded) -> Bool)? = nil, file: StaticString = #filePath, line: UInt = #line) async throws -> [Recorded] {
        var recorded: [Recorded] = []
        for index in 0..<frames {
            if let transaction = try before?(index) { _ = world.submit(transaction) }
            let frame = await world.advance(by: step)
            let item = Recorded(step: index, frame: frame, telemetry: world.benchmarkTelemetry,
                                samples: world.benchmarkCapturedSubsteps, issue: world.diagnostics.lastAdvanceIssue)
            recorded.append(item)
            if index == 0, item.issue == nil, frame.transactionReceipts.isEmpty {
                XCTFail("scena odrzucona w kroku 0: \(frame.events)", file: file, line: line)
                break
            }
            if item.issue != nil || until?(item) == true { break }
        }
        return recorded
    }

    /// Asercja zdrowia świata po przebiegu: bez odrzucenia i bez `worldFailed`.
    static func assertHealthy(_ world: BubbleWorld, _ context: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let d = world.diagnostics
        XCTAssertNil(d.lastAdvanceIssue, "\(context) issue=\(String(describing: d.lastAdvanceIssue)) reason=\(String(describing: d.failureReason)) detail=\(String(describing: d.failureDetail))", file: file, line: line)
        XCTAssertNil(d.failureReason, context, file: file, line: line)
    }

    /// Ocena warunku w pętli: pierwsze złamanie zgłasza jeden błąd z opisem i zwraca `false`, żeby pętla mogła przerwać.
    @discardableResult
    static func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String, file: StaticString = #filePath,
                      line: UInt = #line) -> Bool {
        if condition() { return true }
        XCTFail(message(), file: file, line: line)
        return false
    }

    // MARK: geometria sceny

    static func length(_ v: WorldPoint) -> Float { (v.x * v.x + v.y * v.y).squareRoot() }

    /// Punkt w kwadracie o środku `center`, obrocie `rotation` i połowie boku `half` (brzeg liczy się jako wnętrze).
    static func isInsideSquare(_ point: WorldPoint, center: WorldPoint, rotation: Float, half: Float) -> Bool {
        let delta = point - center, c = cos(rotation), s = sin(rotation)
        let local = WorldPoint(c * delta.x + s * delta.y, -s * delta.x + c * delta.y)
        return abs(local.x) <= half && abs(local.y) <= half
    }

    /// Największy moduł prędkości wskazanych obiektów po wszystkich zapisanych krokach.
    static func maximumSpeed(_ recorded: [Recorded], ids: [UInt64]) -> Float {
        var maximum: Float = 0
        for item in recorded { for value in ids { maximum = max(maximum, length(item.velocity(value) ?? .zero)) } }
        return maximum
    }

    /// Odległość od środka do najdalszego punktu konturu w kierunku `direction` (wektor jednostkowy): przy kontakcie to położenie cięciwy.
    static func chord(of contour: [WorldPoint], center: WorldPoint, toward direction: WorldPoint) -> Float {
        contour.map { ($0.x - center.x) * direction.x + ($0.y - center.y) * direction.y }.max() ?? 0
    }

}

// MARK: bilans energii (G4-AC2)

/// Bilans energii z zapisu podkroków dla bańki uderzającej prostopadle w ścianę: E = ½ m v² + U(ε), ubytek w oknie [t₀, t₀ + 3 s],
/// gdzie t₀ to 0,1 s przed pierwszym kontaktem, i całka ∫ γ m v² dt liczona trapezami po tych samych podkrokach.
/// Kolejność próbek: stan początkowy (h = 0), potem stan po każdym podkroku. Niezależne od silnika, sprawdzone na odniesieniu w Double.
enum EnergyBalance {
    struct Sample {
        var h: Double
        /// Odległość środka od powierzchni ściany.
        var distance: Double
        /// Składowa prędkości normalna do ściany (znak bez znaczenia, liczy się kwadrat).
        var velocity: Double
    }

    struct Result {
        var firstContactTime: Double
        var windowStart: Double
        var windowEnd: Double
        /// Czy próbki sięgają do końca okna.
        var coversWindow: Bool
        var initialEnergy: Double
        var energyLoss: Double
        var dissipated: Double
    }

    static func evaluate(_ samples: [Sample], radius: Double, mass: Double, stiffness: Double, damping: Double,
                         window: Double = 3, lead: Double = 0.1) -> Result? {
        guard samples.count > 1 else { return nil }
        var times: [Double] = [0]
        for sample in samples.dropFirst() { times.append(times.last! + sample.h) }
        guard let contact = samples.indices.first(where: { samples[$0].distance < radius }) else { return nil }
        let t0 = max(0, times[contact] - lead)
        let start = times.lastIndex(where: { $0 <= t0 }) ?? 0
        let endTime = times[start] + window
        let covers = times.last! >= endTime - 1e-9
        let end = times.lastIndex(where: { $0 <= endTime + 1e-9 }) ?? samples.count - 1
        func energy(_ index: Int) -> Double {
            let s = samples[index]
            let epsilon = max(0, 1 - s.distance / radius)
            return 0.5 * mass * s.velocity * s.velocity + ContactLawReference.energy(epsilon: epsilon, stiffness: stiffness, radius: radius)
        }
        var dissipated = 0.0
        if end > start {
            for index in (start + 1)...end {
                let previous = samples[index - 1].velocity, next = samples[index].velocity
                dissipated += samples[index].h * damping * mass * 0.5 * (previous * previous + next * next)
            }
        }
        return Result(firstContactTime: times[contact], windowStart: times[start], windowEnd: times[end], coversWindow: covers,
                      initialEnergy: energy(start), energyLoss: energy(start) - energy(end), dissipated: dissipated)
    }

    /// Próbki z podkroków silnika dla bańki `value` uderzającej w ścianę o płaszczyźnie x = `wallX` (bańka z lewej).
    /// `initial` to stan sprzed pierwszego kroku (pozycja i prędkość z deskryptora).
    @MainActor
    static func samples(of value: UInt64, in recorded: [ForceScene.Recorded], wallX: Float, initialX: Float, initialVx: Float) -> [Sample] {
        var result = [Sample(h: 0, distance: Double(wallX) - Double(initialX), velocity: Double(initialVx))]
        for item in recorded {
            for sample in item.samples {
                guard let body = sample.bubbles[value] else { continue }
                result.append(Sample(h: Double(sample.h), distance: Double(wallX) - Double(body.position.x),
                                     velocity: Double(body.velocity.x)))
            }
        }
        return result
    }
}
