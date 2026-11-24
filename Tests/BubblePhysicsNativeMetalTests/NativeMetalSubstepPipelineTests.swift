import BubblePhysicsModel
import Metal
import simd
import XCTest
@testable import BubblePhysicsNativeMetal

/// Jądra łączące broadphase z pętlą podkroków silnika 4.0.0 (wycinek 1, zadanie 7c): początek kroku, obwiednie z zapasem i sąsiedztwo
/// zbudowane z kandydatów (a nie z kontaktów aktywnych na początku kroku, bo bańka w podkroku dochodzi do kandydata, który jeszcze
/// nie dotykał). Jądra biegną na ręcznie zbudowanych buforach; oczekiwania liczy test z definicji, nie z przebiegu.
@MainActor
final class NativeMetalSubstepPipelineTests: XCTestCase {
    private let limit = NativeMetalSolver.candidateLimitPerObject

    private func makeBuffer<T>(_ values: [T], device: MTLDevice) throws -> MTLBuffer {
        try XCTUnwrap(values.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) })
    }

    private func run(device: MTLDevice, _ body: (MTLComputeCommandEncoder) throws -> Void) throws {
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        try body(encoder)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, _ buffers: [MTLBuffer], threads: Int) {
        encoder.memoryBarrier(scope: .buffers)
        encoder.setComputePipelineState(pipeline)
        for (index, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: index) }
        encoder.dispatchThreads(.init(width: threads, height: 1, depth: 1),
                                threadsPerThreadgroup: .init(width: min(pipeline.threadExecutionWidth, max(1, threads)), height: 1, depth: 1))
    }

    private func bubble(_ id: Int, at position: SIMD2<Float>, previous: SIMD2<Float>? = nil, velocity: SIMD2<Float> = .zero,
                        radius: Float = 12, isStatic: Bool = false) -> NativeMetalBubble {
        var value = NativeMetalBubble(NativeSolverBubble(id: .init(rawValue: id), center: position, previousCenter: previous ?? position,
            velocity: velocity, mass: 0.36, inverseMass: isStatic ? 0 : nil, targetRadius: radius))
        value.publicFlags = SIMD4(1, isStatic ? 1 : 0, 0, 3)
        value.contact = SIMD4(0, 229, 0, 1)
        return value
    }

    // MARK: początek kroku

    /// `position.zw` to środek z początku kroku (kontur, interpolacja i zapas liczą od niego), a wynik regionu z poprzedniego kroku się
    /// czyści. Bańka statyczna dostaje zerową prędkość liniową i kątową.
    func testBeginStepStoresStartCentersClearsRegionResultAndStopsStaticBubbles() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let pipelines = try NativeMetalPipelineCache.pipelines(for: device).stages
        let pipeline = try XCTUnwrap(pipelines["nativeBeginStep"], "brak jądra nativeBeginStep")
        var moving = bubble(1, at: [5, 6], previous: [1, 2], velocity: [30, 0])
        moving.motion.w = 0.5
        var resting = bubble(2, at: [9, 9], previous: [8, 8], velocity: [7, 7], isStatic: true)
        resting.motion.w = 2
        let bubbles = try makeBuffer([moving, resting], device: device)
        let control = try makeBuffer([NativeMetalControl(counts: SIMD4(2, 0, 0, 0), physics: SIMD4(1.0 / 60, 0, 0, 0), contactDamping: .zero)],
                                     device: device)
        try run(device: device) { dispatch($0, pipeline, [bubbles, control], threads: 2) }
        let result = bubbles.contents().bindMemory(to: NativeMetalBubble.self, capacity: 2)
        XCTAssertEqual(result[0].position, SIMD4(5, 6, 5, 6))
        XCTAssertEqual(result[0].publicFlags.w, 0)
        XCTAssertEqual(result[0].motion, SIMD4(30, 0, 0, 0.5), "bańka ruchoma zachowuje prędkości")
        XCTAssertEqual(result[1].position, SIMD4(9, 9, 9, 9))
        XCTAssertEqual(result[1].publicFlags.w, 0)
        XCTAssertEqual(SIMD2(result[1].motion.x, result[1].motion.y), SIMD2<Float>.zero)
        XCTAssertEqual(result[1].motion.w, 0)
    }

    // MARK: sąsiedztwo z kandydatów

    private func candidate(kind: UInt32, a: Int, other: Int, ids: (Int64, Int64)) -> NativeMetalCandidate {
        NativeMetalCandidate(participants: SIMD2(ids.0, ids.1), metadata: SIMD4(kind, UInt32(a), UInt32(other), 1))
    }

    /// Każdy kandydat trafia do wiersza obu końców pary i jednego końca (bańki) kandydata odcinka, niezależnie od tego, czy już
    /// dotyka: wiersz niesie (indeks kandydata, sąsiad, rodzaj) i jest posortowany po rodzaju, a potem po sąsiedzie.
    func testCandidateAdjacencyListsEveryCandidateInTheRowsOfBothEnds() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let pipelines = try NativeMetalPipelineCache.pipelines(for: device).stages
        let clear = try XCTUnwrap(pipelines["nativeClearAdjacency"])
        let emit = try XCTUnwrap(pipelines["nativeEmitCandidateAdjacency"], "brak jądra nativeEmitCandidateAdjacency")
        let build = try XCTUnwrap(pipelines["nativeBuildAdjacency"])
        let candidates = [candidate(kind: 0, a: 0, other: 1, ids: (10, 11)), candidate(kind: 0, a: 0, other: 2, ids: (10, 12)),
                          candidate(kind: 1, a: 0, other: 3, ids: (10, 700)), candidate(kind: 1, a: 2, other: 1, ids: (12, 600)),
                          candidate(kind: 0, a: 1, other: 2, ids: (11, 12))]
        let count = 3
        let candidateBuffer = try makeBuffer(candidates, device: device)
        let control = try makeBuffer([NativeMetalControl(counts: SIMD4(UInt32(count), 4, 0, 0), physics: .zero, contactDamping: .zero)],
                                     device: device)
        let contacts = try makeBuffer([NativeMetalContactControl(limits: .zero, counts: SIMD4(UInt32(candidates.count), 0, 0, 0),
            cache: SIMD4(0, 0, 0, UInt32(limit)), thresholds: .zero, cellWidth: .zero)], device: device)
        let adjacency = try makeBuffer([SIMD4<UInt32>](repeating: SIMD4(UInt32.max, UInt32.max, UInt32.max, UInt32.max),
                                                       count: count * limit), device: device)
        let degrees = try makeBuffer([UInt32](repeating: 99, count: count), device: device)
        let overflow = try makeBuffer([UInt32](repeating: 0, count: 4), device: device)
        try run(device: device) { encoder in
            dispatch(encoder, clear, [control, degrees], threads: count)
            dispatch(encoder, emit, [contacts, candidateBuffer, adjacency, degrees, overflow], threads: candidates.count)
            dispatch(encoder, build, [control, contacts, adjacency, degrees, overflow], threads: count)
        }
        let rows = adjacency.contents().bindMemory(to: SIMD4<UInt32>.self, capacity: count * limit)
        let counts = degrees.contents().bindMemory(to: UInt32.self, capacity: count)
        func row(_ bubble: Int) -> [[UInt32]] {
            (0..<Int(counts[bubble])).map { [rows[bubble * limit + $0].x, rows[bubble * limit + $0].y, rows[bubble * limit + $0].z] }
        }
        XCTAssertEqual(Array(UnsafeBufferPointer(start: counts, count: count)), [3, 2, 3])
        XCTAssertEqual(row(0), [[0, 1, 0], [1, 2, 0], [2, 3, 1]], "pary rosnąco po sąsiedzie, potem odcinek")
        XCTAssertEqual(row(1), [[0, 0, 0], [4, 2, 0]])
        XCTAssertEqual(row(2), [[1, 0, 0], [4, 1, 0], [3, 1, 1]])
        XCTAssertEqual(overflow.contents().bindMemory(to: UInt32.self, capacity: 4)[0], 0)
        XCTAssertEqual(overflow.contents().bindMemory(to: UInt32.self, capacity: 4)[1], 3, "największy stopień przed obcięciem")
    }

    /// Wiersz pełny odrzuca nadmiar i liczy go w liczniku przepełnienia, jak sąsiedztwo z kontaktów.
    func testCandidateAdjacencyCountsRowsOverTheLimitAsOverflow() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let pipelines = try NativeMetalPipelineCache.pipelines(for: device).stages
        let clear = try XCTUnwrap(pipelines["nativeClearAdjacency"])
        let emit = try XCTUnwrap(pipelines["nativeEmitCandidateAdjacency"], "brak jądra nativeEmitCandidateAdjacency")
        let small = 2
        let candidates = (0..<4).map { candidate(kind: 1, a: 0, other: $0, ids: (10, Int64(100 + $0))) }
        let candidateBuffer = try makeBuffer(candidates, device: device)
        let control = try makeBuffer([NativeMetalControl(counts: SIMD4(1, 4, 0, 0), physics: .zero, contactDamping: .zero)], device: device)
        let contacts = try makeBuffer([NativeMetalContactControl(limits: .zero, counts: SIMD4(4, 0, 0, 0),
            cache: SIMD4(0, 0, 0, UInt32(small)), thresholds: .zero, cellWidth: .zero)], device: device)
        let adjacency = try makeBuffer([SIMD4<UInt32>](repeating: .zero, count: small), device: device)
        let degrees = try makeBuffer([UInt32(7)], device: device)
        let overflow = try makeBuffer([UInt32](repeating: 0, count: 4), device: device)
        try run(device: device) { encoder in
            dispatch(encoder, clear, [control, degrees], threads: 1)
            dispatch(encoder, emit, [contacts, candidateBuffer, adjacency, degrees, overflow], threads: candidates.count)
        }
        XCTAssertEqual(overflow.contents().bindMemory(to: UInt32.self, capacity: 4)[0], 2)
    }

    // MARK: obwiednie z zapasem

    private struct Broadphase {
        var rows: [NativeMetalCandidate]
        var cellWidth: Float
    }

    /// Siatka i kandydaci dwóch baniek `a`, `b` (indeksy 0, 1) z zapasem wskazanym w buforze; tolerancja rozdzielenia `slack`.
    private func broadphase(_ a: NativeMetalBubble, _ b: NativeMetalBubble, margins: [Float], slack: Float, wall: NativeMetalSegment? = nil) throws -> Broadphase {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let pipelines = try NativeMetalPipelineCache.pipelines(for: device).stages
        let prepare = try XCTUnwrap(pipelines["nativePrepareGrid"]), emit = try XCTUnwrap(pipelines["nativeEmitCandidates"])
        let bubbles = try makeBuffer([a, b], device: device)
        let segments = try makeBuffer([wall ?? NativeMetalSegment(NativeSolverSegment(id: 1, previousA: .zero, previousB: .zero, currentA: .zero, currentB: .zero))],
                                      device: device)
        let control = try makeBuffer([NativeMetalControl(counts: SIMD4(2, wall == nil ? 0 : 1, 0, 0), physics: .zero, contactDamping: .zero)],
                                     device: device)
        let contacts = try makeBuffer([NativeMetalContactControl(limits: .zero, counts: .zero, cache: SIMD4(0, 0, 0, UInt32(limit)),
            thresholds: SIMD4(0, 0, 0, slack), cellWidth: .zero)], device: device)
        let marginBuffer = try makeBuffer(margins, device: device)
        try run(device: device) { encoder in
            encoder.memoryBarrier(scope: .buffers)
            encoder.setComputePipelineState(prepare)
            for (index, buffer) in [bubbles, control, contacts, marginBuffer].enumerated() { encoder.setBuffer(buffer, offset: 0, index: index) }
            encoder.dispatchThreadgroups(.init(width: 1, height: 1, depth: 1), threadsPerThreadgroup: .init(width: 256, height: 1, depth: 1))
        }
        let width = contacts.contents().bindMemory(to: NativeMetalContactControl.self, capacity: 1).pointee.cellWidth.x
        func cell(_ value: NativeMetalBubble) -> SIMD2<Int64> {
            SIMD2(Int64((value.position.x / width).rounded(.down)), Int64((value.position.y / width).rounded(.down)))
        }
        let grid = [NativeMetalGridEntry(cell: cell(a), metadata: SIMD4(0, 1, 0, 0)), NativeMetalGridEntry(cell: cell(b), metadata: SIMD4(1, 1, 0, 0))]
            .sorted { ($0.cell.x, $0.cell.y, $0.metadata.x) < ($1.cell.x, $1.cell.y, $1.metadata.x) }
        let rows = try makeBuffer([NativeMetalCandidate](repeating: NativeMetalCandidate(participants: .zero, metadata: .zero), count: 2 * limit),
                                  device: device)
        let rowCounts = try makeBuffer([UInt32](repeating: 0, count: 4), device: device)
        let overflow = try makeBuffer([UInt32](repeating: 0, count: 4), device: device)
        try run(device: device) { encoder in
            encoder.setComputePipelineState(emit)
            let buffers: [MTLBuffer] = [bubbles, control, contacts, try makeBuffer(grid, device: device), segments, rows, rowCounts, overflow,
                try makeBuffer([SIMD4<UInt32>](repeating: .zero, count: 2), device: device), try makeBuffer([UInt64(0)], device: device), marginBuffer]
            for (index, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: index) }
            encoder.dispatchThreads(.init(width: 2, height: 1, depth: 1), threadsPerThreadgroup: .init(width: 2, height: 1, depth: 1))
        }
        let counts = rowCounts.contents().bindMemory(to: UInt32.self, capacity: 4)
        let records = rows.contents().bindMemory(to: NativeMetalCandidate.self, capacity: 2 * limit)
        var result: [NativeMetalCandidate] = []
        for owner in 0..<2 { for slot in 0..<Int(counts[owner * 2] + counts[owner * 2 + 1]) { result.append(records[owner * limit + slot]) } }
        return Broadphase(rows: result, cellWidth: width)
    }

    /// Zapas poszerza zasięg pary o sumę zapasów obu baniek i szerokość komórki siatki o dwa największe zapasy: para dalsza niż
    /// r_a + r_b + tolerancja, a bliższa niż r_a + r_b + m_a + m_b + tolerancja, jest kandydatem tylko z zapasem.
    func testMarginWidensBubblePairCandidatesAndTheGridCell() throws {
        let a = bubble(1, at: [0, 0]), b = bubble(2, at: [60, 0])
        let natural = try broadphase(a, b, margins: [0, 0], slack: 0.5)
        XCTAssertEqual(natural.rows.count, 0, "bez zapasu 60 > 12 + 12 + 0,5")
        XCTAssertEqual(natural.cellWidth, 24.5, accuracy: 1e-5, "2 r + tolerancja")
        let padded = try broadphase(a, b, margins: [20, 20], slack: 0.5)
        XCTAssertEqual(padded.cellWidth, 2 * (12 + 20) + 0.5, accuracy: 1e-5, "2 (r + zapas) + tolerancja")
        XCTAssertEqual(padded.rows.count, 1, "60 ≤ 12 + 12 + 20 + 20 + 0,5")
        XCTAssertEqual(padded.rows.first?.metadata.x, 0)
        XCTAssertEqual(padded.rows.first?.metadata.y, 0)
        XCTAssertEqual(padded.rows.first?.metadata.z, 1)
        let tooFar = try broadphase(a, bubble(2, at: [90, 0]), margins: [20, 20], slack: 0.5)
        XCTAssertEqual(tooFar.rows.count, 0, "90 > 64,5")
        let asymmetric = try broadphase(a, b, margins: [40, 0], slack: 0.5)
        XCTAssertEqual(asymmetric.rows.count, 1, "wystarczy zapas jednej bańki: 60 ≤ 24 + 40 + 0,5")
    }

    /// Odcinek: zasięg to r + zapas bańki (środek w prostokącie obwiedni odcinka poszerzonej o ten zasięg).
    func testMarginWidensBubbleSegmentCandidates() throws {
        let wall = NativeMetalSegment(NativeSolverSegment(id: 5, previousA: [100, -50], previousB: [100, 50], currentA: [100, -50], currentB: [100, 50]))
        let a = bubble(1, at: [0, 0]), far = bubble(2, at: [-5000, 0])
        let natural = try broadphase(a, far, margins: [0, 0], slack: 0.5, wall: wall)
        XCTAssertEqual(natural.rows.count, 0, "100 > 12 + 0,5")
        let padded = try broadphase(a, far, margins: [90, 0], slack: 0.5, wall: wall)
        XCTAssertEqual(padded.rows.map { [$0.metadata.x, $0.metadata.y, $0.metadata.z] }, [[1, 0, 0]], "100 ≤ 12 + 90 + 0,5")
    }

    // MARK: jądro pętli jednej grupy (CD-D-27)

    /// Jądro `nativeSubstepLoopSingleGroup` jest jedynym jądrem jednej grupy (osobny broadphase jednej grupy znika), a jego pamięć grupy,
    /// statyczna razem z dynamiczną, mieści się w 16 KB, czyli w tym, co dają A11 i Mac M1 Pro (32 KB), z zapasem na wariant sprzętu.
    func testSubstepLoopKernelIsTheOnlySingleGroupKernelAndFitsSixteenKilobytes() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let pipelines = try NativeMetalPipelineCache.pipelines(for: device).stages
        let pipeline = try XCTUnwrap(pipelines["nativeSubstepLoopSingleGroup"], "brak jądra nativeSubstepLoopSingleGroup")
        XCTAssertNil(pipelines["nativeBroadphaseSingleGroup"], "broadphase jednej grupy ma być tylko funkcją urządzenia")
        let total = pipeline.staticThreadgroupMemoryLength + NativeMetalSubstep.singleGroupMemoryLength
        XCTAssertLessThanOrEqual(total, 16 * 1024, "pamięć grupy jądra pętli: statyczna \(pipeline.staticThreadgroupMemoryLength) + dynamiczna")
        XCTAssertLessThanOrEqual(total, device.maxThreadgroupMemoryLength)
        XCTAssertGreaterThanOrEqual(NativeMetalSolver.singleGroupWidth(pipeline), 1)
    }
}
