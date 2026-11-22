import XCTest
import Metal
import simd
@testable import BubblePhysicsNativeMetal

/// Strażnik środka i krawędź wejścia (poprawka 3.0.2, BF-D-1 – BF-D-4) na jądrach uruchamianych bezpośrednio, ze źródeł jak
/// `ContainmentKernelFixture`. Ściana to statyczny prostokąt (360, −500)…(408, 500), właściciel 9, krawędzie 1 (dolna), 2 (prawa),
/// 3 (górna), 4 (lewa). Bańka r 74,1337 jak w śladzie z gry (`seed1-base301-repB`): w 3.0.1 wynik solvera dokładnie na lewej
/// krawędzi dawał bity 2|8 i środek przerzucony wzdłuż krawędzi na (360; 500,002), a każdy wynik za krawędzią cofnięcie na 359,998.
@MainActor
final class NativeMetalCenterGuardEdgeTests: XCTestCase {
    private static let owner = 9
    private static let bubbleID = 1
    private static let radius: Float = 74.1337
    /// Margines strażnika: 2 · contactTolerance.
    private static let margin: Float = 0.002
    private static let frame: UInt32 = 7

    /// Krawędź ściany: identyfikator, normalna zewnętrzna, współrzędna prostej wzdłuż normalnej i punkt na środku odcinka.
    private struct Edge {
        let id: Int
        let outward: SIMD2<Float>
        let anchor: SIMD2<Float>
        var name: String { ["dolna", "prawa", "górna", "lewa"][id - 1] }
        /// Współrzędna prostej przesunięta o `ulps` kroków float32 w głąb bryły (ujemne: na zewnątrz).
        func point(ulps: Int) -> SIMD2<Float> {
            var point = anchor
            let axis = outward.x != 0 ? 0 : 1
            for _ in 0..<abs(ulps) {
                // W głąb bryły to przeciwnie do normalnej zewnętrznej.
                let inward = (ulps > 0) == (outward[axis] < 0)
                point[axis] = inward ? point[axis].nextUp : point[axis].nextDown
            }
            return point
        }
    }

    private static let edges: [Edge] = [
        Edge(id: 1, outward: [0, -1], anchor: [391.3, -500]),
        Edge(id: 2, outward: [1, 0], anchor: [408, 81.7742]),
        Edge(id: 3, outward: [0, 1], anchor: [391.3, 500]),
        Edge(id: 4, outward: [-1, 0], anchor: [360, 81.7742])]

    private static func wall() -> [NativeMetalSegment] {
        NativeStaticPolygonEdges.segments(points: [[360, -500], [408, -500], [408, 500], [360, 500]], firstID: 1, ownerID: owner)
            .map(NativeMetalSegment.init)
    }

    /// Rekord cache kontaktu bańka–krawędź z cechą `feature`, widziany w klatce `seen`.
    private static func record(edge: Int, feature: Float = 1, seen: UInt32) -> NativeContactCacheRecord {
        NativeContactCacheRecord(participants: SIMD2(Int64(bubbleID), Int64(edge)), metadata: SIMD4(1, 1, seen, 0),
                                 geometry: .zero, response: SIMD4(0, radius + 1, 0, feature))
    }

    // MARK: strażnik środka (BF-D-2, BF-D-4)

    /// Krawędź wejścia aktywna w tym kroku (rekord cechy 1 z bieżącej klatki, przewidziany środek miękkiej bańki za prostą): wynik
    /// solvera od −3 do +3 ulp wokół prostej każdej z czterech krawędzi zostaje bez zmian, bez bitów 2|8, bez przesunięcia wzdłuż
    /// krawędzi i bez cofnięcia.
    func testCenterAtTheEntryEdgeWithinThreeUlpsStaysWithoutRejection() async throws {
        let fixture = try await GuardKernelFixture()
        for edge in Self.edges {
            let start = edge.anchor + edge.outward * Self.margin - SIMD2(edge.outward.y, -edge.outward.x) * 0.0196
            for ulps in -3...3 {
                let end = edge.point(ulps: ulps)
                let result = try await fixture.guardCenter(start: start, predicted: edge.anchor - edge.outward * 0.05, end: end,
                    segments: Self.wall(), cache: [Self.record(edge: edge.id, seen: Self.frame)], frame: Self.frame)
                XCTAssertEqual(result.bits & 10, 0, "\(edge.name), \(ulps) ulp: bity \(result.bits)")
                XCTAssertEqual(result.position, end, "\(edge.name), \(ulps) ulp: strażnik przesunął środek")
            }
        }
    }

    /// Rekord cechy 1 z bieżącej klatki nie jest krawędzią wejścia, gdy przewidziany środek stał przed prostą (zwykły docisk od
    /// zewnątrz) albo bańka jest twarda (c = 0, ε = c · F / r_ref = 0): przejście krawędzi jest cofane jak w 3.0.1, bez odrzucenia.
    func testEntryEdgeNeedsASoftBubbleWhosePredictedCenterIsBehindTheEdge() async throws {
        let fixture = try await GuardKernelFixture()
        for edge in Self.edges {
            let start = edge.anchor + edge.outward * Self.margin
            for (predicted, compliance, label) in [(edge.anchor + edge.outward * 0.05, Float(0.04), "przewidziany przed prostą"),
                                                   (edge.anchor - edge.outward * 0.05, 0, "bańka twarda")] {
                let end = edge.point(ulps: 2)
                let result = try await fixture.guardCenter(start: start, predicted: predicted, end: end, compliance: compliance,
                    segments: Self.wall(), cache: [Self.record(edge: edge.id, seen: Self.frame)], frame: Self.frame)
                XCTAssertEqual(result.bits & 10, 0, "\(edge.name), \(label): bity \(result.bits)")
                XCTAssertEqual(simd_dot(result.position - edge.anchor, edge.outward), Self.margin, accuracy: 1e-4,
                               "\(edge.name), \(label): \(result.position)")
            }
        }
    }

    /// Bez krawędzi wejścia (brak rekordu albo rekord z poprzedniej klatki) środek dokładnie na prostej nie jest odrzucany ani
    /// przesuwany wzdłuż krawędzi: zostaje albo wychodzi wzdłuż normalnej zewnętrznej najwyżej o margines.
    func testCenterExactlyOnTheEdgeWithoutEntryEdgeLeavesAlongTheOutwardNormal() async throws {
        let fixture = try await GuardKernelFixture()
        for edge in Self.edges {
            let start = edge.anchor + edge.outward * Self.margin
            for cache in [[], [Self.record(edge: edge.id, seen: Self.frame - 1)]] {
                let end = edge.point(ulps: 0)
                let result = try await fixture.guardCenter(start: start, end: end, segments: Self.wall(), cache: cache, frame: Self.frame)
                let label = "\(edge.name), rekordów \(cache.count)"
                XCTAssertEqual(result.bits & 10, 0, "\(label): bity \(result.bits), wynik \(result.position)")
                let offset = result.position - end
                let tangent = SIMD2(-edge.outward.y, edge.outward.x)
                XCTAssertEqual(simd_dot(offset, tangent), 0, accuracy: 1e-3, "\(label): przesunięcie wzdłuż krawędzi \(result.position)")
                XCTAssertGreaterThanOrEqual(simd_dot(offset, edge.outward), 0, "\(label): środek w bryle \(result.position)")
                XCTAssertLessThanOrEqual(simd_dot(offset, edge.outward), Self.margin * 1.5, "\(label): \(result.position)")
            }
        }
    }

    /// Bez krawędzi wejścia przejście krawędzi z zewnątrz do środka jest cofane jak w 3.0.1: na krawędź + margines po stronie
    /// zewnętrznej, bez odrzucenia.
    func testCrossingWithoutEntryEdgeIsReturnedOutsideAsBefore() async throws {
        let fixture = try await GuardKernelFixture()
        for edge in Self.edges {
            let start = edge.anchor + edge.outward * Self.margin
            for ulps in [1, 3] {
                let end = edge.point(ulps: ulps)
                let result = try await fixture.guardCenter(start: start, end: end, segments: Self.wall(), cache: [], frame: Self.frame)
                XCTAssertEqual(result.bits & 10, 0, "\(edge.name), \(ulps) ulp: bity \(result.bits)")
                XCTAssertEqual(simd_dot(result.position - edge.anchor, edge.outward), Self.margin, accuracy: 1e-4,
                               "\(edge.name), \(ulps) ulp: \(result.position)")
            }
        }
    }

    /// Środek z wnętrza ściany dociśnięty przez krawędź wejścia (lewą) aż za tylną krawędź (prawą) zostaje po wewnętrznej stronie
    /// tylnej krawędzi (408 − margines), krok przyjęty (BF-D-3).
    func testCenterBehindTheEntryEdgeStopsInsideTheBackEdge() async throws {
        let fixture = try await GuardKernelFixture()
        for (start, end) in [(SIMD2<Float>(380, 81.7742), SIMD2<Float>(410, 81.7742)),
                             (SIMD2<Float>(359.998, 81.7742), SIMD2<Float>(420, 81.7742))] {
            let result = try await fixture.guardCenter(start: start, end: end, segments: Self.wall(),
                cache: [Self.record(edge: 4, seen: Self.frame)], frame: Self.frame)
            XCTAssertEqual(result.bits & 10, 0, "start \(start): bity \(result.bits)")
            XCTAssertEqual(result.position.x, 408 - Self.margin, accuracy: 1e-4, "start \(start): \(result.position)")
            XCTAssertEqual(result.position.y, end.y, "start \(start): \(result.position)")
        }
    }

    // MARK: pamięć krawędzi wejścia (BF-D-1)

    /// Środek, który już na początku kroku był za lewą krawędzią, dostaje cechę 1 tej krawędzi tylko wtedy, gdy poprzedni
    /// opublikowany cache ma jej rekord cechy 1 z poprzedniej klatki. Tylna (prawa) krawędź cechy nie dostaje.
    func testCenterBehindTheEdgeKeepsTheEntryEdgeRememberedFromThePreviousStep() async throws {
        let fixture = try await GuardKernelFixture()
        let center = SIMD2<Float>(362, 81.7742), previous = SIMD2<Float>(361.5, 81.7)
        let cases: [(edge: Int, cache: [NativeContactCacheRecord], feature: Float, label: String)] = [
            (4, [Self.record(edge: 4, seen: Self.frame - 1)], 1, "rekord z poprzedniej klatki"),
            (4, [], 0, "bez rekordu"),
            (4, [Self.record(edge: 4, seen: Self.frame - 2)], 0, "rekord sprzed dwóch klatek"),
            (4, [Self.record(edge: 4, feature: 2, seen: Self.frame - 1)], 0, "rekord wierzchołka"),
            (2, [Self.record(edge: 4, seen: Self.frame - 1)], 0, "tylna krawędź")]
        for item in cases {
            let contact = try await fixture.buildContact(center: center, previous: previous, segments: Self.wall(),
                                                         edge: item.edge, previousCache: item.cache, frame: Self.frame)
            XCTAssertEqual(contact.response.w, item.feature, item.label)
            if item.feature == 1 {
                XCTAssertEqual(contact.geometry.x, -1, item.label)
                XCTAssertEqual(contact.response.y, Self.radius + 2, accuracy: 1e-3, "\(item.label): wgniecenie")
            }
        }
    }

    /// Środek, który wszedł do ściany przez lewą krawędź (zapamiętana krawędź wejścia) i wychodzi przez tylną (prawą), nie dostaje
    /// kontaktu tylnej krawędzi: wypychałaby go dalej za ścianę (BF-D-3). Bez zapamiętanej krawędzi wejścia (wejście i wyjście
    /// w jednym kroku, bańka twarda) tylna krawędź dostaje kontakt jak w 3.0.1. Droga z powrotem przez zapamiętaną krawędź wejścia
    /// zostaje zwykłym kontaktem tej krawędzi, a środek wychodzący przy narożniku nad końcem odcinka też go dostaje.
    func testCenterLeavingTheWallThroughTheBackEdgeGetsNoBackEdgeContact() async throws {
        let fixture = try await GuardKernelFixture()
        let remembered = [Self.record(edge: 4, seen: Self.frame - 1)]
        let cases: [(center: SIMD2<Float>, previous: SIMD2<Float>, edge: Int, cache: [NativeContactCacheRecord], feature: Float,
                     label: String)] = [
            ([408.2, 81.7742], [407.5, 81.7742], 2, remembered, 0, "tylna krawędź z wnętrza po wejściu lewą"),
            ([408.2, 81.7742], [407.5, 81.7742], 2, [Self.record(edge: 4, seen: Self.frame - 2)], 1,
             "tylna krawędź po wygasłej pamięci"),
            ([408.2, 81.7742], [359.5, 81.7742], 2, [], 1, "tylna krawędź z drogi przez całą ścianę w jednym kroku"),
            ([359.5, 81.7742], [360.5, 81.7742], 4, remembered, 1, "powrót przez krawędź wejścia"),
            ([408.5, 499.5], [407.5, 501], 2, remembered, 1, "narożnik: przecięcie prostej nad końcem odcinka")]
        for item in cases {
            let contact = try await fixture.buildContact(center: item.center, previous: item.previous, segments: Self.wall(),
                                                         edge: item.edge, previousCache: item.cache, frame: Self.frame)
            XCTAssertEqual(contact.response.w, item.feature, item.label)
        }
    }
}

@MainActor
private final class GuardKernelFixture {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    init() async throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shaders = root.appendingPathComponent("Sources/BubblePhysicsNativeMetal/Shaders")
        let source = try ["NativeGeometryKernels", "NativeXPBDKernels", "NativePostSolveKernels"].map {
            try String(contentsOf: shaders.appendingPathComponent($0 + ".metal-source"), encoding: .utf8)
        }.joined(separator: "\n")
        let options = MTLCompileOptions(); options.fastMathEnabled = false
        library = try await device.makeLibrary(source: source, options: options)
    }

    /// Pusta tablica daje wyzerowany bufor: jądro i tak go wiąże, ale liczba rekordów 0 nie pozwala go czytać.
    func buffer<T>(_ values: [T]) throws -> MTLBuffer {
        if values.isEmpty { return try XCTUnwrap(device.makeBuffer(length: 256, options: .storageModeShared)) }
        return try values.withUnsafeBytes { bytes in
            try XCTUnwrap(device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared))
        }
    }

    func run(_ name: String, buffers: [MTLBuffer]) async throws {
        let pipeline = try await device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: name)))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        for (index, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: index) }
        encoder.dispatchThreads(.init(width: 1, height: 1, depth: 1), threadsPerThreadgroup: .init(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        _ = try await NativeMetalCommandExecutor().complete(command)
    }

    /// Bańka r 74,1337 bez prędkości: przewidziany środek `center` (position.xy z nativePredict), środek z początku kroku `previous`
    /// (position.zw) i podatność kontaktu `compliance` (c₀ 0,0108 · r / r_ref 20 ≈ 0,04; 0 to bańka twarda).
    func bubble(center: SIMD2<Float>, previous: SIMD2<Float>, compliance: Float = 0.04) throws -> NativeMetalBubble {
        var record = NativeMetalBubble(NativeSolverBubble(id: .init(rawValue: 1), center: center, previousCenter: previous,
                                                          mass: 13.7, targetRadius: 74.1337))
        record.position = SIMD4(center.x, center.y, previous.x, previous.y)
        record.contact.x = compliance
        return record
    }

    func contactControl(frame: UInt32, previousCount: Int, candidates: Int, cache: Int) -> NativeMetalContactControl {
        NativeMetalContactControl(limits: SIMD4(frame, 30, 64, UInt32(previousCount)),
                                  counts: SIMD4(UInt32(candidates), 0, UInt32(cache), 0), cache: SIMD4(0, 0, 0, 8),
                                  thresholds: SIMD4(4, 0.5, 0.001, 0.002), cellWidth: .zero)
    }

    /// `nativeApplyCenterGuards` dla jednej bańki: środek z początku kroku `start`, przewidziany środek `predicted` (domyślnie wynik
    /// solvera), wynik solvera `end`; bieżący cache roboczy `cache` (posortowany po kluczu) w buforze 8.
    func guardCenter(start: SIMD2<Float>, predicted: SIMD2<Float>? = nil, end: SIMD2<Float>, compliance: Float = 0.04,
                     segments: [NativeMetalSegment], cache: [NativeContactCacheRecord],
                     frame: UInt32) async throws -> (position: SIMD2<Float>, bits: UInt32) {
        let positions = try buffer([SIMD4<Float>(end.x, end.y, 0, 0)])
        let safety = try buffer([UInt32](repeating: 0, count: 8))
        try await run("nativeApplyCenterGuards", buffers: [
            try buffer([bubble(center: predicted ?? end, previous: start, compliance: compliance)]), try buffer(segments), positions,
            try buffer([NativeMetalControl(counts: SIMD4(1, UInt32(segments.count), 0, 0), physics: SIMD4(1 / 60, 0, 0, 0),
                                           contactDamping: .zero)]),
            try buffer([contactControl(frame: frame, previousCount: 0, candidates: 0, cache: cache.count)]),
            try buffer([UInt32(0)]), safety, try buffer([UInt32](repeating: 0, count: 16)), try buffer(cache)])
        let position = positions.contents().load(as: SIMD4<Float>.self)
        return (SIMD2(position.x, position.y), safety.contents().load(fromByteOffset: 12, as: UInt32.self))
    }

    /// `nativeBuildContacts` dla jednego kandydata (bańka, krawędź `edge`): poprzedni opublikowany cache `previousCache` w buforze 5,
    /// sterowanie świata (liczba odcinków) w buforze 6.
    func buildContact(center: SIMD2<Float>, previous: SIMD2<Float>, segments: [NativeMetalSegment], edge: Int,
                      previousCache: [NativeContactCacheRecord], frame: UInt32) async throws -> NativeContactCacheRecord {
        let index = try XCTUnwrap(segments.firstIndex { $0.identity.x == Int64(edge) })
        let candidate = NativeMetalCandidate(participants: SIMD2(1, Int64(edge)), metadata: SIMD4(1, 0, UInt32(index), 1))
        let contacts = try buffer([NativeContactCacheRecord](repeating: .init(participants: .zero, metadata: .zero,
            geometry: .zero, response: .zero), count: 1))
        try await run("nativeBuildContacts", buffers: [
            try buffer([bubble(center: center, previous: previous)]), try buffer(segments),
            try buffer([contactControl(frame: frame, previousCount: previousCache.count, candidates: 1, cache: 0)]),
            try buffer([candidate]), contacts, try buffer(previousCache),
            try buffer([NativeMetalControl(counts: SIMD4(1, UInt32(segments.count), 0, 0), physics: SIMD4(1 / 60, 0, 0, 0),
                                           contactDamping: .zero)])])
        return contacts.contents().load(as: NativeContactCacheRecord.self)
    }
}
