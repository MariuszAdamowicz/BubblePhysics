@testable import BubblePhysics
import BubblePhysicsNativeMetal
import XCTest
import simd

/// Koniec kroku i asercje kontaktu (P-B-22 do P-B-26; G6-AC2 do G6-AC5). Kolejność oceny końca kroku: limit podkroków, potem skończoność, potem
/// region, a asercja kontaktu biegnie po regionie i nie odrzuca kroku (świat przechodzi w `worldFailed`, bez powtórki kroku). Stan wstrzykuje
/// przełącznik pakietowy `injectedSubstepState` po podkroku 0 każdej klatki, z `assertEverySubstep`.
@MainActor
final class ContactAssertionTests: XCTestCase {
    private func injecting(_ object: UInt64, to position: SIMD2<Float>) -> NativeMetalConfiguration {
        var native = NativeMetalConfiguration.default
        native.assertEverySubstep = true
        native.injectedSubstepState = NativeMetalInjectedSubstepState(afterSubstep: 0, objectID: object, position: position)
        return native
    }

    /// Przebieg do pierwszego kroku z problemem; zwraca diagnostykę świata.
    private func runUntilIssue(_ world: BubbleWorld, frames: Int = 5) async throws -> WorldDiagnostics {
        _ = try await ForceScene.run(world, frames: frames)
        return world.diagnostics
    }

    private func assertContactViolation(_ diagnostics: WorldDiagnostics, objects: Set<UInt64>, _ context: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(diagnostics.lastAdvanceIssue, .worldFailed, context, file: file, line: line)
        XCTAssertEqual(diagnostics.failureReason, .contactViolation, context, file: file, line: line)
        XCTAssertNil(diagnostics.lastRejectionReason, "\(context): krok nie jest odrzucany ani powtarzany", file: file, line: line)
        let reported = Set((diagnostics.failureDetail?.objects ?? []).map(\.rawValue))
        XCTAssertTrue(objects.isSubset(of: reported), "\(context): obiekty w diagnostyce \(reported), oczekiwane \(objects)", file: file, line: line)
    }

    // MARK: P-B-22 (G6-AC2)

    func testInjectedCoincidentCentersOfACollidingPairFailTheWorld() async throws {
        let world = try ForceScene.makeWorld(native: injecting(1, to: [200, 0])) {
            try $0.add(ForceScene.bubble(1, at: [0, 0])).add(ForceScene.bubble(2, at: [200, 0]))
        }
        assertContactViolation(try await runUntilIssue(world), objects: [1, 2], "d = 0 w parze")
    }

    func testInjectedCenterInsideAStaticPolygonFailsTheWorld() async throws {
        let world = try ForceScene.makeWorld(native: injecting(1, to: [10, 10])) {
            try $0.add(ForceScene.bubble(1, at: [300, 0])).add(ForceScene.square(2, at: .zero, side: 100))
        }
        assertContactViolation(try await runUntilIssue(world), objects: [1, 2], "środek w wielokącie")
    }

    func testInjectedCenterInsideAStaticCircleFailsTheWorld() async throws {
        let world = try ForceScene.makeWorld(native: injecting(1, to: [0, 20])) {
            try $0.add(ForceScene.bubble(1, at: [300, 0])).add(ForceScene.rigid(2, .circle(radius: 50), at: .zero))
        }
        assertContactViolation(try await runUntilIssue(world), objects: [1, 2], "środek w kole")
    }

    func testInjectedCenterInsideAStaticCapsuleFailsTheWorld() async throws {
        let world = try ForceScene.makeWorld(native: injecting(1, to: [30, 5])) {
            try $0.add(ForceScene.bubble(1, at: [300, 0])).add(ForceScene.rigid(2, .capsule(halfLength: 50, radius: 20), at: .zero))
        }
        assertContactViolation(try await runUntilIssue(world), objects: [1, 2], "środek w kapsule")
    }

    func testInjectedCenterInsideAKinematicBodyFailsTheWorld() async throws {
        let world = try ForceScene.makeWorld(native: injecting(1, to: [10, 10])) {
            try $0.add(ForceScene.bubble(1, at: [300, 0])).add(ForceScene.square(2, at: .zero, side: 100, role: .kinematic))
        }
        assertContactViolation(try await runUntilIssue(world), objects: [1, 2], "środek w bryle kinematycznej")
    }

    /// Zmiana strony krawędzi: bańka w kontakcie z cienką ścianą (kandydat krawędzi, środek 20 j od płaszczyzny) zostaje przeniesiona na drugą stronę,
    /// poza bryłę ściany, więc nie ma środka w bryle, ale znacznik strony krawędzi się zmienił.
    func testInjectedCenterOnTheOtherSideOfAThinWallFailsTheWorld() async throws {
        let world = try ForceScene.makeWorld(native: injecting(1, to: [150, 0])) {
            try $0.add(ForceScene.bubble(1, at: [80, 0])).add(ForceScene.wall(2, x: 100))
        }
        let diagnostics = try await runUntilIssue(world)
        assertContactViolation(diagnostics, objects: [1, 2], "zmiana strony krawędzi")
        XCTAssertNotNil(diagnostics.failureDetail?.edgeIndex, "diagnostyka podaje krawędź")
    }

    /// Dwie bańki z wykluczającymi się filtrami przechodzą przez siebie, a bańka z filtrem wykluczającym bryłę przechodzi przez nią: ten sam
    /// wstrzyknięty stan (d = 0, środek w bryle) nie daje `worldFailed`.
    func testExcludingFiltersLetObjectsPassThroughEachOtherWithoutFailure() async throws {
        let pairWorld = try ForceScene.makeWorld(native: injecting(1, to: [200, 0])) {
            try $0.add(ForceScene.bubble(1, at: [0, 0], filter: CollisionFilter(category: 1, mask: 1)))
                .add(ForceScene.bubble(2, at: [200, 0], filter: CollisionFilter(category: 2, mask: 2)))
        }
        _ = try await ForceScene.run(pairWorld, frames: 30)
        ForceScene.assertHealthy(pairWorld, "bańki z wykluczającymi się filtrami")
        let bodyWorld = try ForceScene.makeWorld(native: injecting(1, to: [10, 10])) {
            try $0.add(ForceScene.bubble(1, at: [300, 0], filter: CollisionFilter(category: 2, mask: 2)))
                .add(ForceScene.square(2, at: .zero, side: 100))
        }
        _ = try await ForceScene.run(bodyWorld, frames: 30)
        ForceScene.assertHealthy(bodyWorld, "bańka z filtrem wykluczającym bryłę")
    }

    /// Stan, którego silnik nie całkuje, nie jest jego błędem: dwie bańki nieruchome (statyczne) z d = 0 i nieruchoma bańka w bryle nie dają
    /// `worldFailed`, a ruchoma bańka w tej samej bryle tak (poprzedni test).
    func testStaticBubblesAreNotAssertedAgainstEachOtherNorBodies() async throws {
        let pair = try ForceScene.makeWorld(native: injecting(1, to: [200, 0])) {
            try $0.add(ForceScene.bubble(1, at: [0, 0], role: .static)).add(ForceScene.bubble(2, at: [200, 0], role: .static))
        }
        _ = try await ForceScene.run(pair, frames: 10)
        ForceScene.assertHealthy(pair, "dwie bańki statyczne")
        let inBody = try ForceScene.makeWorld(native: injecting(1, to: [10, 10])) {
            try $0.add(ForceScene.bubble(1, at: [300, 0], role: .static)).add(ForceScene.square(2, at: .zero, side: 100))
        }
        _ = try await ForceScene.run(inBody, frames: 10)
        ForceScene.assertHealthy(inBody, "bańka statyczna w bryle")
    }

    // MARK: P-B-23 (G6-AC3)

    func testNonFinitePositionFailsTheWorldWithNonFiniteValues() async throws {
        let world = try ForceScene.makeWorld(native: injecting(1, to: [.nan, 0])) {
            try $0.add(ForceScene.bubble(1, at: [0, 0]))
        }
        let diagnostics = try await runUntilIssue(world)
        XCTAssertEqual(diagnostics.lastAdvanceIssue, .worldFailed)
        XCTAssertEqual(diagnostics.failureReason, .nonFiniteValues)
    }

    // MARK: P-B-24 (G6-AC4, wrap)

    /// Bańka z `.wrap` wylatuje górą z regionu 2000 × 2000 (wyjście całej bryły w jednym kroku: 1000 + 60 j) i wraca dołem przy y = −988, czyli
    /// wewnątrz regionu. `rest` to obiekty sceny dla trzech przypadków zawinięcia.
    private func wrapScene(_ rest: @escaping (WorldTransaction) throws -> WorldTransaction) throws -> BubbleWorld {
        try ForceScene.makeWorld(half: 1000) {
            try rest($0.add(ForceScene.bubble(1, at: [0, 1000], velocity: [0, 3600], regionExitPolicy: .wrap)))
        }
    }

    func testWrapOntoFreeSpaceKeepsSimulating() async throws {
        let world = try wrapScene { $0 }
        let recorded = try await ForceScene.run(world, frames: 30)
        ForceScene.assertHealthy(world, "zawinięcie na wolne miejsce")
        XCTAssertEqual(recorded.count, 30)
        XCTAssertLessThan(try XCTUnwrap(recorded.first?.position(1)).y, -900, "bańka ma być zawinięta na dół")
    }

    /// Zawinięcie na miejsce nakładające się z inną bańką przy d = 30 > 0: świat żyje, a para rozsuwa się siłą kontaktu (środki w poprzek
    /// prędkości, więc kontakt działa tylko wzdłuż normalnej).
    func testWrapOntoAnOverlappingBubbleKeepsSimulatingAndTheContactForcePushesThemApart() async throws {
        let world = try wrapScene { try $0.add(ForceScene.bubble(2, at: [30, -988])) }
        let recorded = try await ForceScene.run(world, frames: 30)
        ForceScene.assertHealthy(world, "zawinięcie na nakładającą się bańkę")
        XCTAssertEqual(recorded.count, 30)
        // Zawinięta bańka mija stojącą z prędkością 3600 j/s, więc kontakt trwa ok. 0,01 s, a jego impuls (całka siły K·δ·R/d², w poprzek
        // toru d rośnie od 30 do R = 48) to ok. 1,1 pędu stojącej bańki o masie 1: odepchnięta w +x z prędkością rzędu 1 j/s.
        let item = try XCTUnwrap(recorded.dropFirst(3).first)
        let b = try XCTUnwrap(item.position(2)), v = try XCTUnwrap(item.velocity(2))
        XCTAssertGreaterThan(b.x, 30.05, "bańka stojąca ma być odepchnięta od zawiniętej, jest w \(b)")
        XCTAssertGreaterThan(v.x, 0.5, "pęd z siły kontaktu pary, prędkość \(v)")
        XCTAssertLessThan(v.x, 3, "impuls ograniczony czasem kontaktu, prędkość \(v)")
    }

    /// Asercja biegnie po regionie: bańka zawinięta tak, że jej środek trafia do wnętrza bryły, przełącza świat w `worldFailed`.
    func testWrapIntoARigidBodyFailsTheWorldWithContactViolation() async throws {
        let world = try wrapScene { try $0.add(ForceScene.square(2, at: [0, -988], side: 20)) }
        assertContactViolation(try await runUntilIssue(world, frames: 5), objects: [1, 2], "zawinięcie w bryłę")
    }

    // MARK: P-B-25 i P-B-26 (G6-AC5)

    /// Bryła kinematyczna jedzie 100 j/s prostopadle do ściany i wciska w nią „2” przy współrzędnych rzędu 360 j. W ciągu 1 s od pierwszego
    /// kontaktu świat przechodzi w `worldFailed` z przyczyną limitu podkroków, diagnostyka podaje obiekt, który wyznaczał h, a żadna klatka nie
    /// przekracza limitu 1024 podkroków.
    func testKinematicBodySqueezingABubbleAgainstTheWallExceedsTheSubstepLimit() async throws {
        let world = try ForceScene.makeWorld {
            try $0.add(ForceScene.bubble(1, at: [300, 0])).add(ForceScene.wall(2, x: 360))
                .add(ForceScene.square(3, at: [150, 0], side: 100, role: .kinematic))
                .setKinematicDrive(ForceScene.id(3), drive: .velocity(linear: [100, 0], angular: 0))
        }
        // Pierwszy kontakt po (276 − 200) / 100 = 0,76 s, czyli w klatce 46; limit musi zadziałać najpóźniej 1 s później.
        let recorded = try await ForceScene.run(world, frames: 46 + 60 + 5)
        let diagnostics = world.diagnostics
        XCTAssertEqual(diagnostics.lastAdvanceIssue, .worldFailed, "świat ma paść z limitu podkroków, ostatni krok \(recorded.count - 1)")
        XCTAssertEqual(diagnostics.failureReason, .substepLimitExceeded)
        let detail = try XCTUnwrap(diagnostics.failureDetail)
        XCTAssertFalse(detail.objects.isEmpty, "diagnostyka podaje obiekt, który wyznaczał h")
        XCTAssertNotNil(detail.limitingTerm, "diagnostyka podaje człon h z ostatniego podkroku")
        for item in recorded.dropLast() {
            XCTAssertLessThanOrEqual(item.telemetry?.substepCount ?? 0, 1024, "krok \(item.step) przekracza limit podkroków")
        }
    }

    /// Limit 1024 nie daje fałszywych alarmów w zakresie gry: obracająca się bryła kinematyczna, uderzenia 3 · 10³ j/s i tłum zderzony z szybką
    /// bańką przechodzą bez `worldFailed`, a żadna klatka nie ma więcej niż 1024 podkroków.
    private func assertWithinTheLimit(_ world: BubbleWorld, frames: Int, _ context: String, until: ((ForceScene.Recorded) -> Bool)? = nil) async throws {
        let recorded = try await ForceScene.run(world, frames: frames, until: until)
        ForceScene.assertHealthy(world, context)
        let counts = recorded.compactMap { $0.telemetry?.substepCount }
        XCTAssertEqual(counts.count, recorded.count, "\(context): telemetria każdej klatki")
        XCTAssertGreaterThan(counts.max() ?? 0, 0, "\(context): telemetria podkroków jest pusta")
        XCTAssertLessThanOrEqual(counts.max() ?? 0, 1024, "\(context): największa liczba podkroków")
    }

    func testGameScenesNeverExceedTheSubstepLimit() async throws {
        let spinning = try ForceScene.makeWorld {
            try $0.add(ForceScene.bubble(1, at: [360, 0])).add(ForceScene.square(2, at: [250, 0], side: 50, role: .kinematic))
                .setKinematicDrive(ForceScene.id(2), drive: .velocity(linear: [1000, 0], angular: 20))
        }
        try await assertWithinTheLimit(spinning, frames: 30, "obracająca się bryła")
        for (name, kind) in [("„2”", ForceScene.two), ("128", ForceScene.b128), ("7168", ForceScene.b7168)] {
            let world = try ForceScene.makeWorld {
                try $0.add(ForceScene.bubble(1, at: [360 - kind.radius - 100, 0], kind, velocity: [3000, 0])).add(ForceScene.wall(2, x: 360))
            }
            try await assertWithinTheLimit(world, frames: 200, "uderzenie 3000 j/s, \(name)", until: { item in
                guard let x = item.position(1), let v = item.velocity(1) else { return true }
                return v.x < 0 && x.x < 360 - kind.radius
            })
        }
        let crowd = try ForceScene.makeWorld(damping: 1) { setup in
            var transaction = setup
            for row in 0..<4 {
                for column in 0..<4 {
                    transaction = transaction.add(try ForceScene.bubble(UInt64(1 + row * 4 + column), at: [80 + Float(column) * 50, Float(row) * 50 - 75]))
                }
            }
            return transaction.add(try ForceScene.bubble(100, at: [0, 0], velocity: [3000, 0]))
        }
        try await assertWithinTheLimit(crowd, frames: 120, "tłum zderzony z bańką 3000 j/s")
    }
}
