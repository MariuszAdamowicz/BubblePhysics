@testable import BubblePhysics
import BubblePhysicsNativeMetal
import XCTest
import simd

/// Wspólne sceny i porównania dla testów ścieżek wykonania pętli podkroków (plan `docs/sdlc/changes/2026-11-23-engine-4-0-0`, wycinek 3,
/// P-B-41 … P-B-46, G8-AC4, CD-D-27, CD-D-29). Scena to opis świata z liczbą klatek; `run` liczy ją wybraną ścieżką (`forceMultipleDispatches`)
/// i zbiera telemetrię, zapis podkroków i przepełnienie kandydatów w każdej klatce. Warunki samych testów (klatka z ≥ 20 podkrokami,
/// przebudowa w klatce kontaktu itd.) są asercjami, więc scena, która ich nie spełnia, nie przechodzi.
@MainActor
enum PathScene {
    typealias Build = (WorldTransaction) throws -> WorldTransaction

    struct Scene {
        var name: String
        var half: Float = 2000
        var damping: Float = 0
        var frames = 60
        /// Bańki, których stan porównuje bliźniak.
        var ids: [UInt64]
        var minimumMarginOnly = false
        var before: ((Int) throws -> WorldTransaction?)?
        var until: ((ForceScene.Recorded) -> Bool)?
        var build: Build
    }

    struct Run {
        var recorded: [ForceScene.Recorded]
        /// Przepełnienie kandydatów w każdej klatce (przyrost licznika z diagnostyki, który rośnie narastająco).
        var overflow: [Int]
        /// Największa liczba kandydatów na obiekt w klatce.
        var maximumCandidates: [Int]
        var diagnostics: WorldDiagnostics

        var telemetry: [NativeMetalFrameTelemetry] { recorded.compactMap(\.telemetry) }
        var substeps: [Int] { recorded.map { $0.telemetry?.substepCount ?? -1 } }
        var rebuilds: [Int] { recorded.map { $0.telemetry?.gridRebuildCount ?? -1 } }
        /// Wszyscy skompaktowani kandydaci kontaktu z ostatniej budowy siatki w każdej klatce (suma po wierszach, nie maksimum na obiekt).
        var candidatePairs: [Int] { recorded.map { $0.telemetry?.candidatePairCount ?? -1 } }
    }

    static func native(forced: Bool, minimumMarginOnly: Bool = false, candidateLimit: Int? = nil, buckets: Int? = nil,
                       capture: Bool = true) -> NativeMetalConfiguration {
        var native = NativeMetalConfiguration.default
        native.captureSubsteps = capture
        native.forceMultipleDispatches = forced
        native.minimumMarginOnly = minimumMarginOnly
        if let candidateLimit { native.candidateLimitPerObject = candidateLimit }
        if let buckets { native.gridHashBucketCount = buckets }
        return native
    }

    static func run(_ scene: Scene, native: NativeMetalConfiguration, file: StaticString = #filePath, line: UInt = #line) async throws -> Run {
        let world = try ForceScene.makeWorld(half: scene.half, damping: scene.damping, native: native, build: scene.build)
        var overflow: [Int] = [], maximum: [Int] = [], total = 0
        func note() {
            let diagnostics = world.diagnostics
            overflow.append(diagnostics.contactCandidateOverflow - total)
            total = diagnostics.contactCandidateOverflow
            maximum.append(diagnostics.maximumContactCandidatesPerObject)
        }
        let recorded = try await ForceScene.run(world, frames: scene.frames, before: scene.before, until: { item in
            note()
            return scene.until?(item) ?? false
        }, file: file, line: line)
        if overflow.count < recorded.count { note() }
        return Run(recorded: recorded, overflow: overflow, maximumCandidates: maximum, diagnostics: world.diagnostics)
    }

    // MARK: sceny

    /// Tłum „2” w spoczynku, bez nakładania i z dala od toru uderzenia (y ≥ 300), rząd po rzędzie od lewej: kolumny co 56 j (odstęp 8 j między
    /// bańkami, czyli kandydaci w zapasie obwiedni bez aktywnego kontaktu).
    static func restingCrowd(_ transaction: WorldTransaction, count: Int, firstID: UInt64 = 1000) throws -> WorldTransaction {
        var result = transaction
        for index in 0..<count {
            let column = index % 30, row = index / 30
            result = result.add(try ForceScene.bubble(firstID + UInt64(index), at: [-1800 + Float(column) * 56, 300 + Float(row) * 56]))
        }
        return result
    }

    static let wallX: Float = 360

    /// Uderzenie „2” w ścianę z 3 · 10³ j/s (G3-AC1) w świecie z tłumem `crowd` baniek w spoczynku. Start w odległości 390 j od ściany (faza dobrana tak, żeby klatka z ≥ 20 podkrokami nie wyczerpała zapasu), więc
    /// pierwsze klatki mają 1 podkrok.
    static func wallShot(crowd: Int, speed: Float = 3000, name: String = "uderzenie 3·10³ j/s") -> Scene {
        let wallX = self.wallX
        return Scene(name: name, half: 3000, frames: 120, ids: [1],
                     until: { item in
                         guard let x = item.position(1), let v = item.velocity(1) else { return true }
                         return item.step > 1 && v.x < 0 && x.x < wallX - 24
                     },
                     build: { setup in
                         try restingCrowd(setup.add(ForceScene.bubble(1, at: [wallX - 24 - 390, 0], velocity: [speed, 0]))
                             .add(ForceScene.wall(2, x: wallX)), count: crowd)
                     })
    }

    /// Bańka „2” wystrzelona z 10³ j/s w statyczne koło (promień 50, środek w początku układu) albo kapsułę (promień 20, długość 100, obrót 90°).
    static func bodyShot(_ shape: RigidShape, rotation: Float = 0, name: String) -> Scene {
        Scene(name: name, frames: 60, ids: [1], minimumMarginOnly: true, build: {
            try $0.add(ForceScene.bubble(1, at: [-250, 0], velocity: [1000, 0])).add(ForceScene.rigid(2, shape, at: .zero, rotation: rotation))
        })
    }

    /// „2” w spoczynku uderzona przez obracającą się bryłę kinematyczną z G3-AC3 (kwadrat 50 j, 10³ j/s, 20 rad/s) przy współrzędnych rzędu 360 j.
    static func kinematicHit() -> Scene {
        Scene(name: "bryła kinematyczna", frames: 30, ids: [1], minimumMarginOnly: true, build: {
            try $0.add(ForceScene.bubble(1, at: [360, 0])).add(ForceScene.square(2, at: [250, 0], side: 50, role: .kinematic))
                .setKinematicDrive(ForceScene.id(2), drive: .velocity(linear: [1000, 0], angular: 20))
        })
    }

    /// Odległość środków środkowej bańki gromady i bańk odlatujących od niej: dotyk (2 · 24) plus szczelina 50 j. Szczelina jest dobrana tak, żeby
    /// odlatująca bańka (3000 j/s, zapas 1,05 · 3000 / 60 = 52,5 j plus r / 4 = 6 j środkowej) była kandydatem środkowej na początku klatki, a po
    /// przesunięciu o niecałe 10 j (ok. 0,2 klatki) już nie.
    static let clusterSpacing: Float = 98

    /// G5-AC3 ze ścianą: 128 uderza „2”, a ta mija ścianę ukrytą poza zapasem. Z `distractors` na początku klatki wybicia dochodzi daleko od
    /// wybicia gromada: bańka w spoczynku i cztery bańki wokół niej odlatujące od niej z 3000 j/s. Środkowa ma na początku klatki 5 kandydatów
    /// (z sobą), więc limit kandydatów nad liczbą z samej sceny wybicia przepełnia pierwszą budowę klatki, a po przebudowie (bańki odleciały
    /// poza zapas) już nie. Gromada nie sąsiaduje z 128, „2” ani ścianą, więc obcięcie jej kandydatów nie zmienia fizyki wybicia.
    static func kick(distractors: Bool, minimumMarginOnly: Bool) -> (scene: Scene, plan: KickScenePlanner.Plan) {
        let plan = KickScenePlanner.plan()
        let planned = KickScenePlanner.build(.wall, plan: plan)
        let scene = Scene(name: "G5-AC3, ściana\(distractors ? ", z gromadą" : "")", frames: plan.frame + 8,
                          ids: [1, 2], minimumMarginOnly: minimumMarginOnly,
                          before: distractors ? { step in
                              guard step == plan.frame else { return nil }
                              let center = WorldPoint(-600, 600), spacing = clusterSpacing, speed: Float = 3000
                              var transaction = try WorldTransaction().add(ForceScene.bubble(4, at: center))
                              for (index, direction) in [WorldPoint(1, 0), WorldPoint(-1, 0), WorldPoint(0, 1), WorldPoint(0, -1)].enumerated() {
                                  transaction = try transaction.add(ForceScene.bubble(UInt64(5 + index), at: center + spacing * direction,
                                                                                      velocity: speed * direction))
                              }
                              return transaction
                          } : nil,
                          build: planned.build)
        return (scene, plan)
    }

    /// Cztery sceny z G4-AC3 (parametry jak w `SubstepForceTests`).
    static func splitScenes() throws -> [Scene] {
        let policy = try BubbleDrivePolicy(bandStiffness: 22)
        let wallX = self.wallX
        return [
            Scene(name: "(a) para czołowa", damping: 1, ids: [1, 2], build: {
                try $0.add(ForceScene.bubble(1, at: [300 - 24 - 30, 0], velocity: [100, 0]))
                    .add(ForceScene.bubble(2, at: [300 + 24 + 30, 0], velocity: [-100, 0]))
            }),
            Scene(name: "(b) odbicie od ściany", damping: 1, ids: [1], build: {
                try $0.add(ForceScene.bubble(1, at: [wallX - 24 - 20, 0], velocity: [100, 0])).add(ForceScene.wall(2, x: wallX))
            }),
            Scene(name: "(c) gumka w tłum", damping: 1, ids: [100] + Array(1...16),
                  before: { step in WorldTransaction().updatePlayerDrive(ForceScene.id(100), target: [Float(step) * 100 / 60, 0]) },
                  build: { setup in
                      var transaction = setup
                      for row in 0..<4 {
                          for column in 0..<4 {
                              transaction = transaction.add(try ForceScene.bubble(UInt64(1 + row * 4 + column),
                                                                                  at: [80 + Float(column) * 50, Float(row) * 50 - 75]))
                          }
                      }
                      return transaction.add(try ForceScene.bubble(100, at: [0, 0], drivePolicy: policy))
                          .beginPlayerDrive(ForceScene.id(100), target: [0, 0])
                  }),
            Scene(name: "(d) pole radialne", ids: [1], build: {
                try $0.add(ForceScene.bubble(1, at: [100, 0], velocity: [0, 100]))
                    .add(.forceField(ForceFieldDescriptor(id: ForceScene.id(2), position: .zero, geometry: .circle(radius: 400),
                                                          field: .radial(strength: -500, falloff: 0))))
            })]
    }

    /// Uderzenie „2” w ścianę z 3 · 10³ j/s bez tłumu (G3-AC1), bliźniak P-B-44.
    static func plainWallShot() -> Scene {
        var scene = wallShot(crowd: 0)
        scene.frames = 60
        scene.until = nil
        return scene
    }

    /// Scena P-B-43 i jej warunek testu: w klatce 0 „2” jedzie 3000 j/s i zaczyna w odległości 36 j od przeszkody (mniej niż zapas obwiedni
    /// 52,5 j, więc przeszkoda jest kandydatem), a po pierwszej parze (2 podkroki, ich h wynika z d / (4 v), d = 60 j do powierzchni, więc bańka robi 0,4375 d = 26 j) nie jest jeszcze w kontakcie.
    @MainActor enum Obstacle {
        case wall, circle
        /// Współrzędna powierzchni przeszkody na osi toru („2” leci w +x po y = 0).
        var surface: Float { self == .wall ? 360 : -50 }
        /// Prędkość „2” i odstęp jej brzegu od przeszkody w klatce 0.
        static let speed: Float = 3000
        static let gap: Float = 36
        func scene() -> Scene {
            let surface = self.surface
            return Scene(name: "para buforów, \(self)", frames: 40, ids: [1], build: {
                let start = try ForceScene.bubble(1, at: [surface - 24 - Obstacle.gap, 0], velocity: [Obstacle.speed, 0])
                switch self {
                case .wall: return try $0.add(start).add(ForceScene.wall(2, x: surface))
                case .circle: return try $0.add(start).add(ForceScene.rigid(2, .circle(radius: 50), at: .zero))
                }
            })
        }
        /// Czy środek „2” jest w obiekcie albo za nim (po stronie, z której nie startowała).
        func isBeyond(_ center: WorldPoint) -> Bool {
            switch self {
            case .wall: center.x >= surface
            case .circle: ForceScene.length(center) <= 50
            }
        }
    }

    // MARK: porównanie

    /// Tolerancje bliźniaka (G8-AC4, G4-AC3): podkroki i przebudowy ±1 na klatkę, suma przebudów ±2, po ostatniej klatce pozycje do 1 j
    /// i prędkości do 2 % największej prędkości w scenie.
    static func assertTwin(_ a: Run, _ b: Run, _ scene: Scene, labels: (String, String), file: StaticString = #filePath, line: UInt = #line) {
        let context = "\(scene.name) (\(labels.0) / \(labels.1))"
        XCTAssertEqual(a.recorded.count, b.recorded.count, "\(context): liczba klatek", file: file, line: line)
        XCTAssertEqual(a.recorded.last?.issue, b.recorded.last?.issue, "\(context): wynik (worldFailed albo brak)", file: file, line: line)
        XCTAssertEqual(a.diagnostics.failureReason, b.diagnostics.failureReason, "\(context): przyczyna", file: file, line: line)
        guard a.recorded.count == b.recorded.count else { return }
        var rebuildDifference = 0
        for index in a.recorded.indices {
            let sa = a.substeps[index], sb = b.substeps[index], ra = a.rebuilds[index], rb = b.rebuilds[index]
            rebuildDifference += ra - rb
            guard ForceScene.check(abs(sa - sb) <= 1, "\(context), klatka \(index): podkroki \(sa) / \(sb)", file: file, line: line),
                  ForceScene.check(abs(ra - rb) <= 1, "\(context), klatka \(index): przebudowy \(ra) / \(rb)", file: file, line: line)
            else { return }
        }
        XCTAssertLessThanOrEqual(abs(rebuildDifference), 2, "\(context): suma przebudów \(a.rebuilds.reduce(0, +)) / \(b.rebuilds.reduce(0, +))",
                                 file: file, line: line)
        guard let last = a.recorded.last, let other = b.recorded.last else { return }
        let maximumSpeed = max(ForceScene.maximumSpeed(a.recorded, ids: scene.ids), ForceScene.maximumSpeed(b.recorded, ids: scene.ids))
        for id in scene.ids {
            guard let pa = last.position(id), let pb = other.position(id), let va = last.velocity(id), let vb = other.velocity(id) else {
                XCTFail("\(context): brak bańki \(id)", file: file, line: line)
                continue
            }
            XCTAssertLessThanOrEqual(simd_distance(pa, pb), 1, "\(context), bańka \(id): pozycje \(pa) / \(pb)", file: file, line: line)
            XCTAssertLessThanOrEqual(simd_distance(va, vb), 0.02 * maximumSpeed,
                                     "\(context), bańka \(id): prędkości \(va) / \(vb), największa \(maximumSpeed)", file: file, line: line)
        }
    }

    /// Przebieg bez odrzucenia kroku i bez `worldFailed`.
    static func assertHealthy(_ run: Run, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        let d = run.diagnostics
        XCTAssertNil(d.lastAdvanceIssue, "\(context) issue=\(String(describing: d.lastAdvanceIssue)) reason=\(String(describing: d.failureReason)) detail=\(String(describing: d.failureDetail))",
                     file: file, line: line)
        XCTAssertNil(d.failureReason, context, file: file, line: line)
    }

    /// Ścieżka każdej klatki zgadza się z oczekiwaną (bez tego bliźniak porównywałby tę samą ścieżkę z samą sobą).
    static func assertPath(_ run: Run, _ path: NativeMetalExecutionPath, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(run.telemetry.count, run.recorded.count, "\(context): telemetria każdej klatki", file: file, line: line)
        for (index, telemetry) in run.telemetry.enumerated() {
            guard ForceScene.check(telemetry.executionPath == path, "\(context), klatka \(index): ścieżka \(telemetry.executionPath), oczekiwana \(path)",
                                   file: file, line: line) else { return }
        }
    }

    /// Środek „2” (ID 1) po każdym podkroku po stronie startowej przeszkody: `isBeyond` nigdy nie jest prawdą.
    static func assertNeverBeyond(_ run: Run, bubble: UInt64 = 1, _ beyond: (WorldPoint) -> Bool, _ context: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        var checked = 0
        for item in run.recorded {
            for sample in item.samples {
                guard let body = sample.bubbles[bubble] else { continue }
                checked += 1
                guard ForceScene.check(!beyond(body.position), "\(context), krok \(item.step): środek \(body.position) poza przeszkodą albo po jej drugiej stronie",
                                       file: file, line: line) else { return }
            }
        }
        XCTAssertGreaterThan(checked, 0, "\(context): zapis podkroków jest pusty", file: file, line: line)
    }

    // MARK: warunki scen

    /// Klatki kontaktu bańki: te, w których jej prędkość zmienia się o więcej niż 1 % największej prędkości w scenie względem klatki poprzedniej
    /// (od klatki 1; w żadnej ze scen bryłowych kontakt nie zaczyna się w klatce 0).
    static func contactFrames(_ run: Run, bubble: UInt64 = 1) -> [Int] {
        let maximum = ForceScene.maximumSpeed(run.recorded, ids: [bubble])
        return run.recorded.indices.dropFirst().filter { index in
            guard let a = run.recorded[index - 1].velocity(bubble), let b = run.recorded[index].velocity(bubble) else { return false }
            return simd_distance(a, b) > 0.01 * maximum
        }
    }

    /// P-B-42 (CD-D-26): scena `kick(distractors:)` z limitem kandydatów równym największej liczbie kandydatów samej sceny wybicia (bez gromady)
    /// przepełnia pierwszą budowę klatki wybicia (gromada), a po przebudowie bańki gromady są poza zapasem, więc ostatnia budowa klatki nie
    /// przepełnia i żadna inna klatka też nie. Licznik klatki ma podać maksimum po budowach, a nie zero ani wartość ostatniej budowy. Bez limitu
    /// przepełnienia nie ma, a świat jest zdrowy w obu ścieżkach.
    static func assertOverflowIsTheMaximumOverBuilds(forced: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let context = forced ? "wiele dyspozycji" : "jedna dyspozycja"
        let (baseScene, _) = kick(distractors: false, minimumMarginOnly: false)
        let base = try await run(baseScene, native: native(forced: forced), file: file, line: line)
        let limit = base.maximumCandidates.max() ?? 0
        XCTAssertGreaterThan(limit, 0, "\(context): scena wybicia ma kandydatów", file: file, line: line)
        let (scene, plan) = kick(distractors: true, minimumMarginOnly: false)
        let free = try await run(scene, native: native(forced: forced), file: file, line: line)
        XCTAssertEqual(free.recorded.count, scene.frames, "\(context): świat padł albo scena odrzucona", file: file, line: line)
        guard free.recorded.count == scene.frames else { return }
        XCTAssertEqual(free.overflow.reduce(0, +), 0, "\(context): limit 128 mieści wszystkich kandydatów", file: file, line: line)
        XCTAssertGreaterThan(free.maximumCandidates[plan.frame], limit,
                             "\(context): gromada ma przekroczyć limit \(limit) w klatce wybicia, kandydaci \(free.maximumCandidates)", file: file, line: line)
        let limited = try await run(scene, native: native(forced: forced, candidateLimit: limit), file: file, line: line)
        XCTAssertEqual(limited.recorded.count, scene.frames, "\(context): świat padł albo scena odrzucona", file: file, line: line)
        guard limited.recorded.count == scene.frames else { return }
        XCTAssertGreaterThanOrEqual(limited.rebuilds[plan.frame], 1,
                                    "\(context): klatka wybicia ma mieć przebudowę po pierwszej budowie, przebudowy \(limited.rebuilds)", file: file, line: line)
        XCTAssertGreaterThan(limited.overflow[plan.frame], 0,
                             "\(context): klatka wybicia ma podać maksimum przepełnienia po budowach, przepełnienie klatek \(limited.overflow)", file: file, line: line)
        for index in limited.overflow.indices where index != plan.frame {
            guard ForceScene.check(limited.overflow[index] == 0, "\(context), klatka \(index): przepełnienie \(limited.overflow[index]) poza klatką wybicia",
                                   file: file, line: line) else { return }
        }
        // Warunek sceny „przepełnia budowę przed przebudową, a po niej nie”, jako asercje. Połowa „przed”: pierwsza budowa klatki wybicia ma gromadę
        // w kandydatach (powyżej, `free.maximumCandidates` > limit). Połowa „po”: (1) ostatnia budowa klatki nie ma w sobie żadnej pary gromady, bo
        // jej łączna liczba kandydatów (telemetria `candidatePairCount`, liczona od zera przy każdej budowie) jest taka jak w scenie samego wybicia
        // bez gromady, i to bez limitu, i z limitem; (2) geometria: na końcu klatki każda bańka gromady (ID 5…8) jest od środkowej (ID 4) dalej niż
        // r + r + zapas + zapas, z zapasami ograniczonymi z pełnego dt i największej prędkości w klatce (max(1,05 · |v| · dt, r / 4), bez sił w
        // gromadzie). Odlatujące bańki oddalają się monotonicznie, więc to, że gromada wyszła z zasięgu, nie zależy od tego, kiedy dokładnie przebudowano.
        // Wynik zwrócony jako ostatnia budowa zamiast maksimum nie przeszedłby bez (1): liczba kandydatów ostatniej budowy jest wtedy zerowa, a pierwsza nie.
        let frame = limited.recorded[plan.frame]
        XCTAssertFalse(frame.samples.isEmpty, "\(context): zapis podkroków klatki wybicia", file: file, line: line)
        let dt = Float(ForceScene.step), radius = ForceScene.two.radius
        func marginBound(_ id: UInt64) -> Float {
            let speed = frame.samples.compactMap { $0.bubbles[id]?.velocity }.map { simd_length($0) }.max() ?? 0
            return max(1.05 * speed * dt, radius / 4)
        }
        if let center = frame.position(4) {
            for id in UInt64(5)...8 {
                guard let position = frame.position(id) else { XCTFail("\(context): brak bańki \(id) gromady", file: file, line: line); continue }
                let reach = 2 * radius + marginBound(4) + marginBound(id)
                XCTAssertGreaterThan(simd_distance(position, center), reach,
                                     "\(context): bańka \(id) na końcu klatki wybicia ma być poza zasięgiem kandydatów środkowej (\(reach))",
                                     file: file, line: line)
            }
        } else { XCTFail("\(context): brak środkowej bańki gromady", file: file, line: line) }
        XCTAssertGreaterThan(base.candidatePairs[plan.frame], 0, "\(context): scena wybicia ma kandydatów w ostatniej budowie", file: file, line: line)
        XCTAssertEqual(free.candidatePairs[plan.frame], base.candidatePairs[plan.frame],
                       "\(context): ostatnia budowa klatki wybicia (bez limitu) nie ma par gromady", file: file, line: line)
        XCTAssertEqual(limited.candidatePairs[plan.frame], base.candidatePairs[plan.frame],
                       "\(context): ostatnia budowa klatki wybicia (z limitem) nie ma par gromady", file: file, line: line)
        XCTAssertNil(free.diagnostics.failureReason, context, file: file, line: line)
        XCTAssertNil(limited.diagnostics.failureReason, context, file: file, line: line)
    }
}
