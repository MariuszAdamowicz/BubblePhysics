import BubblePhysics
import XCTest

/// Scena tłoku dla testów wycinków 2 i 3 zmiany ściskania (`docs/sdlc/changes/2026-11-14-crowd-solver-compression`):
/// rama z czterech statycznych brył prostokątnych, tłok rosnących baniek, docisk przez `MotorDrive`.
/// Cel Runtime nie widzi `SceneBuilders`, więc rama i napęd są tu (wzór: `PhysicsSceneBuilders.box`, `KinematicStagingTests`).
///
/// Wnętrze ram to prostokąt 360 × 640, ściany mają grubość 48, a `simulationRegion` to ich zewnętrzny prostokąt (456 × 736).
/// Ściany boczne mają pełną wysokość, górna i dolna leżą między nimi, więc bryły stykają się krawędziami bez nakładania.
@MainActor
enum CrowdScene {
    static let step = 1.0 / 60
    static let wallThickness: Float = 48
    static let interiorHalfSize = WorldPoint(180, 320)
    static let interiorArea = Double(360 * 640)
    /// Margines strażnika środka: środek zrzutowany na krawędź ściany leży o `margin` w głąb wnętrza.
    static let guardMargin: Float = 1e-3

    static let bubbleMaterial = PhysicsMaterialID(rawValue: 1)
    static let wallMaterial = PhysicsMaterialID(rawValue: 2)
    static let style = RenderMaterialID(rawValue: 1)
    static let wallIDs = (1...4).map { ObjectID(rawValue: 9_000 + UInt64($0)) }

    static func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }

    static func region() throws -> WorldRectangle {
        let outer = interiorHalfSize + WorldPoint(repeating: wallThickness)
        return try WorldRectangle(min: -outer, max: outer)
    }

    static func configuration(step: TimeInterval = CrowdScene.step) throws -> WorldConfiguration {
        try WorldConfiguration(simulationRegion: region(), fixedTimeStep: step, eventBufferCapacity: 4096)
    }

    /// Materiał baniek sceny: `maximumLinearSpeed` = 600 jak w specyfikacji sceny tłoku.
    static func bubblePhysics(maximumLinearSpeed: Float? = 600, damping: Float = 0) throws -> PhysicsMaterial {
        try PhysicsMaterial(kind: .bubble, damping: damping, maximumLinearSpeed: maximumLinearSpeed)
    }

    static func resources(bubble: PhysicsMaterial) throws -> WorldTransaction {
        WorldTransaction()
            .updatePhysicsMaterial(bubbleMaterial, material: bubble)
            .updatePhysicsMaterial(wallMaterial, material: try PhysicsMaterial(kind: .rigid))
            .updateRenderMaterial(style, material: try RenderMaterial())
    }

    /// Cztery ściany jako statyczne bryły prostokątne.
    static func walls() throws -> [WorldObject] {
        let inner = interiorHalfSize, outer = inner + WorldPoint(repeating: wallThickness)
        let rectangles: [(WorldPoint, WorldPoint)] = [
            ([-outer.x, -outer.y], [-inner.x, outer.y]),   // lewa, pełna wysokość
            ([inner.x, -outer.y], [outer.x, outer.y]),     // prawa, pełna wysokość
            ([-inner.x, -outer.y], [inner.x, -inner.y]),   // dolna, między bocznymi
            ([-inner.x, inner.y], [inner.x, outer.y])]     // górna, między bocznymi
        return try zip(wallIDs, rectangles).map { wallID, corners in
            let (low, high) = corners
            return .rigidBody(try RigidBodyDescriptor(id: wallID,
                vertices: [low, [high.x, low.y], high, [low.x, high.y]], motionRole: .static,
                physicsMaterialID: wallMaterial, renderMaterialID: style))
        }
    }

    static func bubble(_ value: UInt64, at position: WorldPoint, radius: Float, velocity: WorldPoint = .zero,
                       mass: Float? = nil, interest: EventInterest = [.didAdd, .didExitSimulationRegion]) throws -> WorldObject {
        .bubble(try BubbleDescriptor(id: id(value), position: position, velocity: velocity, targetRadius: radius,
                                     mass: mass ?? radius * radius / 400, physicsMaterialID: bubbleMaterial,
                                     renderMaterialID: style, eventInterest: interest))
    }

    /// Docisk: stała siła przez `MotorDrive`; po transakcji bańka ma rolę `motorDriven`.
    static func press(_ value: UInt64, force: WorldPoint) throws -> WorldTransaction {
        WorldTransaction().setMotorDrive(id(value), drive: try MotorDrive(force: force))
    }

    /// Świat z ramą ścian i zasobami, po jednym kroku przyjmującym przygotowanie sceny.
    static func makeWorld(bubble material: PhysicsMaterial? = nil, extra: (WorldTransaction) throws -> WorldTransaction = { $0 },
                          file: StaticString = #filePath, line: UInt = #line) async throws -> BubbleWorld {
        let world = try BubbleWorld(configuration: configuration())
        var setup = try resources(bubble: material ?? bubblePhysics())
        for wall in try walls() { setup = setup.add(wall) }
        _ = world.submit(try extra(setup))
        let frame = await world.advance(by: step)
        XCTAssertNil(world.diagnostics.lastAdvanceIssue, "przygotowanie sceny", file: file, line: line)
        XCTAssertEqual(frame.transactionReceipts.count, 1, "przygotowanie sceny musi zostać przyjęte", file: file, line: line)
        return world
    }

    /// Środek w prostokącie ograniczonym wewnętrznymi krawędziami ścian, z tolerancją `guardMargin`.
    static func isInsideFrame(_ point: WorldPoint) -> Bool {
        abs(point.x) <= interiorHalfSize.x + guardMargin && abs(point.y) <= interiorHalfSize.y + guardMargin
    }

    // MARK: generator

    /// Deterministyczny generator (SplitMix64); stałe ziarno daje ten sam tłok w każdym przebiegu.
    struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: tłok

    /// Wynik przebiegu tłoku: wszystko, co G1 i G2 każą sprawdzić w każdej klatce.
    struct CrowdReport {
        var steps = 0
        var addedCount = 0
        var balance = 0.0
        /// Pierwsza klatka z `lastAdvanceIssue` (odrzucony krok albo awaria), z powodem.
        var firstIssue: (step: Int, issue: WorldAdvanceIssue, rejection: WorldRejectionReason?)?
        var failureReason: WorldFailureReason?
        var exitEvents = 0
        var vanishedBubbles = 0
        var placementRejections = 0
        /// Środki poza ramą (klatka, bańka, położenie).
        var outsideFrame: [(step: Int, id: ObjectID, position: WorldPoint)] = []
        var minimumContainedPairs = Int.max
        var maximumContainedPairs = 0
        var wasContainedCountFinite = true
    }

    /// Stawia bańki co 0,25 s w losowym punkcie wnętrza (radius z [12, 48], rośnie od 10% do pełnego w 1 s), aż bilans pól
    /// B dojdzie do `balance`, i robi jeszcze `extraSteps` kroków. Przerywa przy pierwszym odrzuconym kroku,
    /// bo odrzucony krok blokuje kolejkę i dalsze kroki nic nie wnoszą.
    static func runCrowd(world: BubbleWorld, balance target: Double, seed: UInt64 = 2_500, extraSteps: Int = 600, maximumSteps: Int = 8_000,
                         pressingForceFor: ((WorldPoint) -> WorldPoint)? = nil) async throws -> CrowdReport {
        var generator = SeededGenerator(seed: seed)
        var report = CrowdReport()
        var areas = 0.0
        var nextID: UInt64 = 1
        var added: [ObjectID] = []
        var pendingAdd: (token: TransactionToken, id: UInt64, radius: Float)?
        var stepsToNextAdd = 0
        var stepsAfterLastAdd: Int?
        while true {
            var transaction: WorldTransaction?
            if pendingAdd == nil, areas / interiorArea < target {
                if stepsToNextAdd == 0 { transaction = WorldTransaction(); stepsToNextAdd = 14 } else { stepsToNextAdd -= 1 }
            }
            if let started = transaction {
                let radius = Float.random(in: 12...48, using: &generator)
                let initial = radius * 0.1
                let limit = interiorHalfSize - WorldPoint(repeating: initial)
                let point = WorldPoint(Float.random(in: -limit.x...limit.x, using: &generator),
                                       Float.random(in: -limit.y...limit.y, using: &generator))
                let identifier = nextID
                var staged = started.add(try bubble(identifier, at: point, radius: initial, mass: radius * radius / 400))
                    .startTransition(ParameterTransition(target: .bubbleRadius(id(identifier)), value: .scalar(radius),
                                                         duration: 1))
                if let pressingForceFor { staged = staged.setMotorDrive(id(identifier), drive: try MotorDrive(force: pressingForceFor(point))) }
                pendingAdd = (world.submit(staged), identifier, radius)
            }
            let frame = await world.advance(by: step)
            report.steps += 1
            let diagnostics = world.diagnostics
            report.addedCount = added.count
            report.balance = areas / interiorArea
            if report.firstIssue == nil, let issue = diagnostics.lastAdvanceIssue {
                report.firstIssue = (report.steps, issue, diagnostics.lastRejectionReason)
                report.failureReason = diagnostics.failureReason
                return report
            }
            if let pending = pendingAdd {
                for case .transactionRejected(let token, let rejection) in frame.events where token == pending.token {
                    if case .invalidPlacement = rejection.reason { report.placementRejections += 1 }
                    else { XCTFail("nieoczekiwane odrzucenie transakcji: \(rejection)") }
                    // Punkt odrzucony przez `invalidPlacement` losujemy ponownie od razu, w następnym kroku.
                    pendingAdd = nil; stepsToNextAdd = 0
                }
                if frame.transactionReceipts.contains(where: { $0.token == pending.token }) {
                    added.append(id(pending.id)); nextID += 1
                    areas += Double.pi * Double(pending.radius) * Double(pending.radius)
                    pendingAdd = nil
                    report.addedCount = added.count
                    report.balance = areas / interiorArea
                    if areas / interiorArea >= target { stepsAfterLastAdd = 0 }
                }
            }
            for case .didExitSimulationRegion in frame.events { report.exitEvents += 1 }
            for identifier in added {
                guard let state = frame.objects[identifier] else { report.vanishedBubbles += 1; continue }
                if !isInsideFrame(state.position) { report.outsideFrame.append((report.steps, identifier, state.position)) }
            }
            report.minimumContainedPairs = min(report.minimumContainedPairs, diagnostics.containedBubblePairCount)
            report.maximumContainedPairs = max(report.maximumContainedPairs, diagnostics.containedBubblePairCount)
            if diagnostics.containedBubblePairCount < 0 { report.wasContainedCountFinite = false }
            if let after = stepsAfterLastAdd {
                if after >= extraSteps { break }
                stepsAfterLastAdd = after + 1
            }
            if report.steps >= maximumSteps { XCTFail("tłok nie dobił do bilansu \(target) w \(maximumSteps) krokach"); break }
        }
        return report
    }
}
