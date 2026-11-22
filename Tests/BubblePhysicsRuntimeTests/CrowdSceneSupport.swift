import BubblePhysics
import simd
import XCTest

/// Scena tłoku dla testów wycinków 2 i 3 zmiany ściskania (`docs/sdlc/changes/2026-11-14-crowd-solver-compression`):
/// rama z czterech statycznych brył prostokątnych, tłok rosnących baniek, docisk przez `MotorDrive`.
/// Cel Runtime nie widzi `SceneBuilders`, więc rama i napęd są tu (wzór: `PhysicsSceneBuilders.box`, `KinematicStagingTests`).
/// Wycinek 3 dokłada materiał miękki (`softBubblePhysics`) i docisk baniek do ściany przez `MotorDrive` (`pressedBubble`, `wallPress`).
///
/// Wnętrze ram to prostokąt 360 × 640, ściany mają grubość 48, a `simulationRegion` to ich zewnętrzny prostokąt (456 × 736).
/// Ściany boczne mają pełną wysokość, górna i dolna leżą między nimi, więc bryły stykają się krawędziami bez nakładania.
@MainActor
enum CrowdScene {
    nonisolated static let step = 1.0 / 60
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

    static func configuration() throws -> WorldConfiguration {
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
                       mass: Float? = nil, interest: EventInterest = [.didAdd, .didExitSimulationRegion],
                       material: PhysicsMaterialID? = nil, contactCompliance: Float? = nil,
                       drivePolicy: BubbleDrivePolicy? = nil) throws -> WorldObject {
        .bubble(try BubbleDescriptor(id: id(value), position: position, velocity: velocity, targetRadius: radius,
                                     mass: mass ?? radius * radius / 400, physicsMaterialID: material ?? bubbleMaterial,
                                     renderMaterialID: style, eventInterest: interest, drivePolicy: drivePolicy,
                                     contactCompliance: contactCompliance))
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

    // MARK: materiał miękki i docisk do ściany (wycinek 3)

    /// Drugi materiał baniek sceny, np. twardy obok miękkiego w jednym świecie.
    static let secondBubbleMaterial = PhysicsMaterialID(rawValue: 3)

    /// Materiał baniek z podatnością kontaktu c = base · r / referenceRadius; reszta jak w `bubblePhysics`.
    /// Bez tłumienia, `maximumLinearSpeed` = 600 jak w scenie tłoku. `dampingRatio` to ζ_c kontaktu miękkiego (domyślnie 1, jak w materiale).
    static func softBubblePhysics(base: Float, referenceRadius: Float = 20, maximumLinearSpeed: Float? = 600,
                                  damping: Float = 0, dampingRatio: Float = 1) throws -> PhysicsMaterial {
        try PhysicsMaterial(kind: .bubble, damping: damping, maximumLinearSpeed: maximumLinearSpeed,
                            contactCompliance: BubbleContactCompliance(base: base, referenceRadius: referenceRadius),
                            contactDampingRatio: dampingRatio)
    }

    /// Materiał miękki tłoku z P-B-27 i P-B-28: c₀ = 3,85e-3 przy r_ref = 20. Od v2.3.0 kontakt miękki ugina się
    /// o pełne c · F (CD-D-16), czyli 3,85× mniej niż dawne c₀ = 1e-3 z częściową korektą prędkości; c₀ przeskalowane o ten
    /// współczynnik zachowuje dawny wygląd: kontakt realnie ustępuje, a bańki nie wchodzą w siebie bez granic.
    static func softCrowdPhysics() throws -> PhysicsMaterial {
        try softBubblePhysics(base: 3.85e-3)
    }

    /// Ściana, w którą bańka jest dociskana.
    enum WallSide {
        case left, right
        var sign: Float { self == .left ? -1 : 1 }
    }

    /// Bańka dociśnięta do wewnętrznej krawędzi ściany: środek stoi w odległości r od płaszczyzny ściany, a `MotorDrive` pcha ją
    /// w ścianę stałą siłą `force`. W stanie ustalonym wgniecenie wynosi δ = c · force (XPBD: podatność razy siła),
    /// niezależnie od masy.
    static func pressedBubble(_ transaction: WorldTransaction, _ value: UInt64, y: Float, radius: Float, force: Float,
                              side: WallSide = .left, mass: Float = 1, material: PhysicsMaterialID? = nil,
                              contactCompliance: Float? = nil) throws -> WorldTransaction {
        let position = WorldPoint(side.sign * (interiorHalfSize.x - radius), y)
        return transaction
            .add(try bubble(value, at: position, radius: radius, mass: mass, material: material,
                            contactCompliance: contactCompliance))
            .setMotorDrive(id(value), drive: try MotorDrive(force: [side.sign * force, 0]))
    }

    /// Bańka przy ścianie chwycona gumką zamiast `MotorDrive` (v2.3.0, G1-AC3): środek stoi w odległości r od płaszczyzny ściany,
    /// a cel leży o `stretch` głębiej w ścianie. Siła gumki to K · naciągnięcie, obcięta do `maximumForce`; w spoczynku wgniecenie
    /// wynosi δ = c · F. Cel zostaje w miejscu, więc naciągnięcie maleje o samo wgniecenie (zaniedbywalne wobec `stretch`).
    static func bandPressedBubble(_ transaction: WorldTransaction, _ value: UInt64, y: Float, radius: Float, stretch: Float,
                                  policy: BubbleDrivePolicy, side: WallSide = .left, mass: Float = 1,
                                  material: PhysicsMaterialID? = nil) throws -> WorldTransaction {
        let position = WorldPoint(side.sign * (interiorHalfSize.x - radius), y)
        return transaction
            .add(try bubble(value, at: position, radius: radius, mass: mass, material: material, drivePolicy: policy))
            .beginPlayerDrive(id(value), target: WorldPoint(position.x + side.sign * stretch, y))
    }

    /// Wgniecenie δ = r − d, gdzie d to odległość środka od płaszczyzny ściany (może być ujemne, gdy bańka nie dotyka ściany).
    static func wallDepth(of state: ObjectState, targetRadius: Float, side: WallSide = .left) -> Float {
        targetRadius - (interiorHalfSize.x - side.sign * state.position.x)
    }

    /// Promień efektywny bańki z klatki.
    static func effectiveRadius(of state: ObjectState) -> Float {
        if case .bubble(let radius) = state.kind { return radius }
        return 0
    }

    /// Przebieg docisku: δ każdej wskazanej bańki w każdym z `steps` kroków. Krok odrzucony kończy przebieg niepowodzeniem.
    static func wallPress(world: BubbleWorld, _ bubbles: [(id: UInt64, radius: Float, side: WallSide)], steps: Int,
                          file: StaticString = #filePath, line: UInt = #line) async -> [UInt64: [Float]] {
        var series: [UInt64: [Float]] = [:]
        for index in 0..<steps {
            let frame = await world.advance(by: step)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue, "krok \(index): \(String(describing: world.diagnostics.lastRejectionReason))",
                         file: file, line: line)
            if world.diagnostics.lastAdvanceIssue != nil { break }
            for bubble in bubbles {
                guard let state = frame.objects[id(bubble.id)] else {
                    XCTFail("bańka \(bubble.id) zniknęła w kroku \(index)", file: file, line: line); continue
                }
                series[bubble.id, default: []].append(wallDepth(of: state, targetRadius: bubble.radius, side: bubble.side))
            }
        }
        return series
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
        /// Środki poza ramą (klatka, bańka, położenie).
        var outsideFrame: [(step: Int, id: ObjectID, position: WorldPoint)] = []
        /// Najgłębsze położenie środka za wewnętrzną krawędzią ramy, w promieniach docelowych bańki (ε − 1 względem bliższej ściany);
        /// 0, gdy każdy środek był w ramie.
        @MainActor var deepestCenterBehindFrame: Float {
            outsideFrame.map { sample in
                max(abs(sample.position.x) - interiorHalfSize.x, abs(sample.position.y) - interiorHalfSize.y)
                    / (targetRadii[sample.id] ?? 1)
            }.max() ?? 0
        }
        /// `containedBubblePairCount` z ostatniego kroku przebiegu (-1, dopóki żaden krok się nie wykonał).
        var lastContainedPairs = -1
        /// Największy `containedBubblePairCount` w przebiegu: odróżnia spadek licznika do 0 od licznika, który nigdy nie wzrósł.
        var peakContainedPairs = 0
        /// Promienie docelowe dodanych baniek.
        var targetRadii: [ObjectID: Float] = [:]
        /// Stany baniek z ostatnich `lastSecondSteps` klatek przebiegu (po jednej tablicy na klatkę).
        var lastSecond: [[(id: ObjectID, position: WorldPoint, effectiveRadius: Float)]] = []

        /// Liczba par o nachodzących na siebie kołach promieni docelowych, średnio na klatkę ostatniej sekundy.
        var overlappingPairsPerFrameInLastSecond: Double {
            var count = 0
            for frame in lastSecond {
                for first in 0..<frame.count {
                    for second in (first + 1)..<max(first + 1, frame.count) {
                        let a = frame[first], b = frame[second]
                        if (targetRadii[a.id] ?? 0) + (targetRadii[b.id] ?? 0) - simd_distance(a.position, b.position) > 0 { count += 1 }
                    }
                }
            }
            return lastSecond.isEmpty ? 0 : Double(count) / Double(lastSecond.count)
        }

        /// Największe nakładanie pary (r_i + r_j − d, promienie docelowe) w ostatniej sekundzie; 0, gdy żadna para nie nachodzi.
        var maximumOverlapInLastSecond: Float {
            var maximum: Float = 0
            for frame in lastSecond {
                for first in 0..<frame.count {
                    for second in (first + 1)..<max(first + 1, frame.count) {
                        let a = frame[first], b = frame[second]
                        maximum = max(maximum, (targetRadii[a.id] ?? 0) + (targetRadii[b.id] ?? 0) - simd_distance(a.position, b.position))
                    }
                }
            }
            return maximum
        }

        /// Średni stosunek promienia efektywnego do docelowego, po wszystkich bańkach i klatkach ostatniej sekundy.
        var meanEffectiveRadiusRatioInLastSecond: Float {
            var total = 0.0, count = 0
            for frame in lastSecond {
                for bubble in frame {
                    guard let target = targetRadii[bubble.id], target > 0 else { continue }
                    total += Double(bubble.effectiveRadius / target); count += 1
                }
            }
            return count == 0 ? 0 : Float(total / Double(count))
        }
    }

    static let lastSecondSteps = 60

    /// Stawia bańki co 0,25 s w losowym punkcie wnętrza (radius z [12, 48], rośnie od 10% do pełnego w 1 s), aż bilans pól
    /// B dojdzie do `balance`, i robi jeszcze `extraSteps` kroków. Przerywa przy pierwszym odrzuconym kroku,
    /// bo odrzucony krok blokuje kolejkę i dalsze kroki nic nie wnoszą.
    static func runCrowd(world: BubbleWorld, balance target: Double, seed: UInt64 = 2_500, extraSteps: Int = 600, maximumSteps: Int = 8_000) async throws -> CrowdReport {
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
                let staged = started.add(try bubble(identifier, at: point, radius: initial, mass: radius * radius / 400))
                    .startTransition(ParameterTransition(target: .bubbleRadius(id(identifier)), value: .scalar(radius),
                                                         duration: 1))
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
                    if case .invalidPlacement = rejection.reason {} else { XCTFail("nieoczekiwane odrzucenie transakcji: \(rejection)") }
                    // Punkt odrzucony przez `invalidPlacement` losujemy ponownie od razu, w następnym kroku.
                    pendingAdd = nil; stepsToNextAdd = 0
                }
                if frame.transactionReceipts.contains(where: { $0.token == pending.token }) {
                    added.append(id(pending.id)); nextID += 1
                    report.targetRadii[id(pending.id)] = pending.radius
                    areas += Double.pi * Double(pending.radius) * Double(pending.radius)
                    pendingAdd = nil
                    report.addedCount = added.count
                    report.balance = areas / interiorArea
                    if areas / interiorArea >= target { stepsAfterLastAdd = 0 }
                }
            }
            for case .didExitSimulationRegion in frame.events { report.exitEvents += 1 }
            var sample: [(id: ObjectID, position: WorldPoint, effectiveRadius: Float)] = []
            for identifier in added {
                guard let state = frame.objects[identifier] else { report.vanishedBubbles += 1; continue }
                if !isInsideFrame(state.position) { report.outsideFrame.append((report.steps, identifier, state.position)) }
                sample.append((identifier, state.position, effectiveRadius(of: state)))
            }
            report.lastSecond.append(sample)
            if report.lastSecond.count > lastSecondSteps { report.lastSecond.removeFirst() }
            report.lastContainedPairs = diagnostics.containedBubblePairCount
            report.peakContainedPairs = max(report.peakContainedPairs, diagnostics.containedBubblePairCount)
            if let after = stepsAfterLastAdd {
                if after >= extraSteps { break }
                stepsAfterLastAdd = after + 1
            }
            if report.steps >= maximumSteps { XCTFail("tłok nie dobił do bilansu \(target) w \(maximumSteps) krokach"); break }
        }
        return report
    }
}
