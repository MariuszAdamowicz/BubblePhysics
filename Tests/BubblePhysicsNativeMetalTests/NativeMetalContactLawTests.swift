import Metal
import simd
import XCTest
@testable import BubblePhysicsNativeMetal

/// Prawo kontaktu silnika 4.0.0 na GPU, na poziomie komponentu (wycinek 1, zadanie 7a; P-B-5, P-B-6 i prawo z P-B-4):
/// wspólne funkcje MSL z `NativeForceKernels` (odwrotność prawa, ściana i bryła, para tego samego i różnych K, sztywność kontaktu)
/// oraz jądro `nativeContactForces` dla ściany, wierzchołka i pary. Odniesieniem jest `ContactLawReference` w Double
/// (plik z `BubblePhysicsRuntimeTests`, w tym module jako dowiązanie), a nie wartości przypięte z przebiegu.
@MainActor
final class NativeMetalContactLawTests: XCTestCase {
    // MARK: Wspólne funkcje: harness

    /// Jądra testowe wołają wspólne funkcje z `NativeForceKernels`, więc test sprawdza ten sam kod, który woła jądro sił i redukcja h.
    private static let harnessSource = """
    kernel void testEpsilon(device float *q [[buffer(0)]], device float *out [[buffer(1)]], uint i [[thread_position_in_grid]]) {
        out[i] = nativeEpsilonFromForceRatio(q[i]);
    }
    // wejście: K, r, d, reserved; wyjście: F, ε, k, reserved
    kernel void testWallLaw(device float4 *input [[buffer(0)]], device float4 *out [[buffer(1)]], uint i [[thread_position_in_grid]]) {
        NativeContactLaw law = nativeWallContactLaw(input[i].x, input[i].y, input[i].z);
        out[i] = float4(law.force, law.epsilonA, law.stiffness, law.epsilonB);
    }
    // wejście: K_a, r_a, K_b, r_b; odległość środków osobno; wyjście: F, ε_a, ε_b, k
    kernel void testPairLaw(device float4 *input [[buffer(0)]], device float *distance [[buffer(1)]], device float4 *out [[buffer(2)]],
                            uint i [[thread_position_in_grid]]) {
        NativeContactLaw law = nativePairContactLaw(input[i].x, input[i].y, input[i].z, input[i].w, distance[i]);
        out[i] = float4(law.force, law.epsilonA, law.epsilonB, law.stiffness);
    }
    """

    private struct Harness {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let library: MTLLibrary
    }

    private func makeHarness() throws -> Harness {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Brak urządzenia Metal") }
        let options = MTLCompileOptions()
        options.fastMathEnabled = false // jak w NativeMetalPipelineCache
        let library = try device.makeLibrary(source: try NativeMetalShaderSource.solverSource() + "\n" + Self.harnessSource, options: options)
        return Harness(device: device, queue: try XCTUnwrap(device.makeCommandQueue()), library: library)
    }

    private func buffer<T>(_ values: [T], _ device: MTLDevice) throws -> MTLBuffer {
        try XCTUnwrap(values.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) })
    }

    private func read<T>(_ buffer: MTLBuffer, count: Int, as: T.Type) -> [T] {
        Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: T.self, capacity: count), count: count))
    }

    /// Uruchamia jądro testowe po jednym wątku na element wejścia.
    private func dispatch(_ harness: Harness, _ name: String, count: Int, buffers: [MTLBuffer]) throws {
        let pipeline = try harness.device.makeComputePipelineState(function: try XCTUnwrap(harness.library.makeFunction(name: name)))
        let command = try XCTUnwrap(harness.queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        for (index, value) in buffers.enumerated() { encoder.setBuffer(value, offset: 0, index: index) }
        encoder.dispatchThreads(.init(width: count, height: 1, depth: 1), threadsPerThreadgroup: .init(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
    }

    private func relative(_ value: Double, _ expected: Double) -> Double {
        abs(value - expected) / max(abs(expected), .leastNormalMagnitude)
    }

    // MARK: ε(q), P-B-5

    func testInverseLawInFloat32MatchesDoubleFromTenToMinusFourToTenToTheSixth() throws {
        let harness = try makeHarness()
        let steps = 600
        let q: [Float] = (0...steps).map { Float(pow(10.0, -4.0 + 10.0 * Double($0) / Double(steps))) }
        let input = try buffer(q, harness.device), output = try buffer([Float](repeating: .nan, count: q.count), harness.device)
        try dispatch(harness, "testEpsilon", count: q.count, buffers: [input, output])
        let result = read(output, count: q.count, as: Float.self)
        var worst = 0.0
        for (index, value) in result.enumerated() {
            let expected = ContactLawReference.epsilon(forForceRatio: Double(q[index]))
            let error = relative(Double(value), expected)
            worst = max(worst, error)
            XCTAssertLessThanOrEqual(error, 1e-3, "q = \(q[index]): ε = \(value), Double \(expected)")
            XCTAssertLessThan(value, 1, "q = \(q[index])")
        }
        XCTAssertLessThanOrEqual(worst, 1e-3)
    }

    func testInverseLawIsTheInverseOfTheForceLaw() throws {
        let harness = try makeHarness()
        let q: [Float] = [1e-4, 1e-3, 0.05, 1, 40, 1e3, 1e6]
        let input = try buffer(q, harness.device), output = try buffer([Float](repeating: .nan, count: q.count), harness.device)
        try dispatch(harness, "testEpsilon", count: q.count, buffers: [input, output])
        for (value, epsilon) in zip(q, read(output, count: q.count, as: Float.self)) {
            // F(ε) / K to q, liczone w Double z ε zaokrąglonego do float32.
            XCTAssertEqual(ContactLawReference.force(epsilon: Double(epsilon), stiffness: 1) / Double(value), 1, accuracy: 2e-3,
                           "q = \(value)")
        }
    }

    // MARK: ściana i bryła

    func testWallLawMatchesTheForceLawAndItsStiffnessInDouble() throws {
        let harness = try makeHarness()
        var inputs: [SIMD4<Float>] = [], expected: [(force: Double, epsilon: Double, stiffness: Double)] = []
        for (stiffness, radius) in [(Float(229), Float(24)), (22, 148), (22_900, 12), (1.5, 7168 / 48)] {
            // d / r od 0,999 (ledwie w kontakcie) do 2e-3 (ε = 0,998, q ≈ 2,5 · 10⁵).
            for fraction in [Float(0.999), 0.99, 0.9, 0.75, 0.5, 0.25, 0.1, 0.03, 0.01, 0.004, 0.002] {
                let distance = radius * fraction
                inputs.append(SIMD4(stiffness, radius, distance, 0))
                let epsilon = 1 - Double(distance) / Double(radius)
                let force = ContactLawReference.force(epsilon: epsilon, stiffness: Double(stiffness))
                // k = dF/dx, x = r · ε: pochodna centralna prawa z odniesienia.
                let h = 1e-6 * (1 - epsilon)
                let slope = (ContactLawReference.force(epsilon: epsilon + h, stiffness: Double(stiffness))
                    - ContactLawReference.force(epsilon: epsilon - h, stiffness: Double(stiffness))) / (2 * h * Double(radius))
                expected.append((force, epsilon, slope))
            }
        }
        let input = try buffer(inputs, harness.device), output = try buffer([SIMD4<Float>](repeating: SIMD4(repeating: .nan), count: inputs.count), harness.device)
        try dispatch(harness, "testWallLaw", count: inputs.count, buffers: [input, output])
        for (index, value) in read(output, count: inputs.count, as: SIMD4<Float>.self).enumerated() {
            let label = "K \(inputs[index].x), r \(inputs[index].y), d \(inputs[index].z)"
            XCTAssertLessThanOrEqual(relative(Double(value.x), expected[index].force), 1e-4, "siła, \(label)")
            XCTAssertLessThanOrEqual(abs(Double(value.y) - expected[index].epsilon), 1e-5, "ε, \(label)")
            XCTAssertLessThanOrEqual(relative(Double(value.z), expected[index].stiffness), 1e-3, "sztywność, \(label)")
            XCTAssertEqual(value.w, 0, "ściana ma jedno ugięcie, \(label)")
        }
    }

    func testWallLawIsZeroWithoutContactAndFiniteAtTheSurface() throws {
        let harness = try makeHarness()
        // d ≥ r: brak kontaktu; d = 0 i d < 0: siła skończona (naruszenie zgłasza asercja, nie prawo); K ≤ 0: bez siły.
        let inputs: [SIMD4<Float>] = [SIMD4(229, 24, 24, 0), SIMD4(229, 24, 30, 0), SIMD4(229, 24, 0, 0), SIMD4(229, 24, -3, 0),
                                      SIMD4(0, 24, 10, 0)]
        let input = try buffer(inputs, harness.device), output = try buffer([SIMD4<Float>](repeating: SIMD4(repeating: .nan), count: inputs.count), harness.device)
        try dispatch(harness, "testWallLaw", count: inputs.count, buffers: [input, output])
        let result = read(output, count: inputs.count, as: SIMD4<Float>.self)
        XCTAssertEqual(result[0].x, 0); XCTAssertEqual(result[1].x, 0); XCTAssertEqual(result[4].x, 0)
        for index in [2, 3] {
            XCTAssertTrue(result[index].x.isFinite && result[index].x > 1e6, "d ≤ 0: F = \(result[index].x)")
            XCTAssertTrue(result[index].z.isFinite, "d ≤ 0: k = \(result[index].z)")
        }
    }

    // MARK: para, P-B-6

    private func pairCases() -> [(a: ContactLawReference.PairBody, b: ContactLawReference.PairBody, fraction: Double)] {
        var cases: [(ContactLawReference.PairBody, ContactLawReference.PairBody, Double)] = []
        // Para tego samego K, pary o różnych K_b / K_a (1,5 do 1000, w obu kierunkach) i promieniach z zakresu gry (24 do 148).
        let radii: [(Double, Double)] = [(24, 24), (24, 148), (148, 24), (12, 148), (60, 60)]
        let stiffnesses: [(Double, Double)] = [(229, 229), (229, 343.5), (229, 2290), (229, 229_000), (229_000, 229), (22, 22_000)]
        // δ / R od 1e-3 (przy K_min q rzędu 10⁻³) do 0,998 (q rzędu 10⁵ dla K_min).
        let fractions: [Double] = [1e-3, 0.01, 0.05, 0.2, 0.5, 0.8, 0.95, 0.99, 0.998]
        for (ra, rb) in radii {
            for (ka, kb) in stiffnesses {
                for fraction in fractions { cases.append((.init(radius: ra, stiffness: ka), .init(radius: rb, stiffness: kb), fraction)) }
            }
        }
        return cases
    }

    func testPairLawMatchesTheDoubleSolutionForTheSameAndDifferentStiffness() throws {
        let harness = try makeHarness()
        let cases = pairCases()
        var inputs: [SIMD4<Float>] = [], distances: [Float] = []
        for item in cases {
            inputs.append(SIMD4(Float(item.a.stiffness), Float(item.a.radius), Float(item.b.stiffness), Float(item.b.radius)))
            distances.append(Float((item.a.radius + item.b.radius) * (1 - item.fraction)))
        }
        let input = try buffer(inputs, harness.device), distance = try buffer(distances, harness.device)
        let output = try buffer([SIMD4<Float>](repeating: SIMD4(repeating: .nan), count: inputs.count), harness.device)
        try dispatch(harness, "testPairLaw", count: inputs.count, buffers: [input, distance, output])
        var worstForce = 0.0
        for (index, value) in read(output, count: inputs.count, as: SIMD4<Float>.self).enumerated() {
            let item = cases[index]
            let overlap = item.a.radius + item.b.radius - Double(distances[index])
            let reference = try XCTUnwrap(ContactLawReference.pairContact(overlap: overlap, a: item.a, b: item.b))
            let label = "K \(item.a.stiffness)/\(item.b.stiffness), r \(item.a.radius)/\(item.b.radius), δ/R \(item.fraction)"
            let error = relative(Double(value.x), reference.force)
            worstForce = max(worstForce, error)
            XCTAssertLessThanOrEqual(error, 1e-2, "siła \(value.x) wobec \(reference.force), \(label)")
            // Suma ugięć równa się nakładaniu (do dokładności float32 względem R).
            let sum = item.a.radius * Double(value.y) + item.b.radius * Double(value.z)
            XCTAssertLessThanOrEqual(abs(sum - overlap), 1e-3 * (item.a.radius + item.b.radius), "suma ugięć, \(label)")
            XCTAssertLessThanOrEqual(abs(Double(value.y) - reference.epsilonA), 1e-3, "ε_a, \(label)")
            XCTAssertLessThanOrEqual(abs(Double(value.z) - reference.epsilonB), 1e-3, "ε_b, \(label)")
        }
        // Wszystkie przypadki mieszczą się w 1 %; sprawdzamy też, że 12 kroków daje zapas, a nie ledwie spełnia próg.
        XCTAssertLessThanOrEqual(worstForce, 2e-3)
    }

    func testPairOfTheSameMaterialUsesTheClosedFormAndSplitsDeflectionByRadius() throws {
        let harness = try makeHarness()
        let radii: [(Float, Float)] = [(24, 24), (24, 148), (148, 24), (12, 60)]
        var inputs: [SIMD4<Float>] = [], distances: [Float] = []
        for (ra, rb) in radii {
            for fraction in [Float(0.01), 0.2, 0.7] {
                inputs.append(SIMD4(229, ra, 229, rb)); distances.append((ra + rb) * (1 - fraction))
            }
        }
        let input = try buffer(inputs, harness.device), distance = try buffer(distances, harness.device)
        let output = try buffer([SIMD4<Float>](repeating: SIMD4(repeating: .nan), count: inputs.count), harness.device)
        try dispatch(harness, "testPairLaw", count: inputs.count, buffers: [input, distance, output])
        for (index, value) in read(output, count: inputs.count, as: SIMD4<Float>.self).enumerated() {
            let ra = Double(inputs[index].y), rb = Double(inputs[index].w), d = Double(distances[index]), r = ra + rb
            // F = K · (R − d) · R / d², jedno ε dla obu baniek, więc wgniecenia r_a ε : r_b ε dzielą się jak promienie.
            XCTAssertLessThanOrEqual(relative(Double(value.x), 229 * (r - d) * r / (d * d)), 1e-5, "siła \(index)")
            XCTAssertEqual(value.y, value.z, "ε_a = ε_b \(index)")
            XCTAssertEqual(ra * Double(value.y) / (rb * Double(value.z)), ra / rb, accuracy: 0.02 * ra / rb, "podział wgnieceń \(index)")
            // k = K · (1 + ε) / (R · (1 − ε)³) (dwie sprężyny szeregowo).
            let epsilon = Double(value.y)
            XCTAssertLessThanOrEqual(relative(Double(value.w), 229 * (1 + epsilon) / (r * pow(1 - epsilon, 3))), 2e-3, "sztywność \(index)")
        }
    }

    func testPairStiffnessIsTheDerivativeOfTheForceWithRespectToApproach() throws {
        let harness = try makeHarness()
        let a = ContactLawReference.PairBody(radius: 24, stiffness: 229), b = ContactLawReference.PairBody(radius: 148, stiffness: 5000)
        let fractions: [Double] = [0.05, 0.3, 0.7, 0.95]
        let inputs = [SIMD4<Float>](repeating: SIMD4(229, 24, 5000, 148), count: fractions.count)
        let distances = fractions.map { Float(172 * (1 - $0)) }
        let input = try buffer(inputs, harness.device), distance = try buffer(distances, harness.device)
        let output = try buffer([SIMD4<Float>](repeating: SIMD4(repeating: .nan), count: inputs.count), harness.device)
        try dispatch(harness, "testPairLaw", count: inputs.count, buffers: [input, distance, output])
        for (index, value) in read(output, count: inputs.count, as: SIMD4<Float>.self).enumerated() {
            let overlap: Double = 172 - Double(distances[index])
            let h: Double = 1e-5 * overlap
            let up = try XCTUnwrap(ContactLawReference.pairContact(overlap: overlap + h, a: a, b: b))
            let down = try XCTUnwrap(ContactLawReference.pairContact(overlap: overlap - h, a: a, b: b))
            XCTAssertLessThanOrEqual(relative(Double(value.w), (up.force - down.force) / (2 * h)), 1e-2, "δ/R \(fractions[index])")
        }
    }

    func testPairLawIsZeroWithoutOverlapAndFiniteWhenCentersCoincide() throws {
        let harness = try makeHarness()
        let inputs = [SIMD4<Float>](repeating: SIMD4(229, 24, 2290, 24), count: 4) + [SIMD4<Float>(229, 24, 229, 24)]
        let distances: [Float] = [48, 60, 0, 1e-9, 48]
        let input = try buffer(inputs, harness.device), distance = try buffer(distances, harness.device)
        let output = try buffer([SIMD4<Float>](repeating: SIMD4(repeating: .nan), count: inputs.count), harness.device)
        try dispatch(harness, "testPairLaw", count: inputs.count, buffers: [input, distance, output])
        let result = read(output, count: inputs.count, as: SIMD4<Float>.self)
        XCTAssertEqual(result[0].x, 0); XCTAssertEqual(result[1].x, 0); XCTAssertEqual(result[4].x, 0)
        for index in [2, 3] {
            XCTAssertTrue(result[index].x.isFinite && result[index].x > 1e6, "środki w jednym punkcie: F = \(result[index].x)")
            XCTAssertTrue(result[index].y.isFinite && result[index].z.isFinite && result[index].w.isFinite)
        }
    }

    // MARK: jądro nativeContactForces

    private typealias Point = SIMD2<Float>

    private struct ForceScene {
        var bubbles: [NativeSolverBubble] = []
        var stiffness: [Float] = []
        var segments: [NativeSolverSegment] = []
        /// Wiersz sąsiedztwa na bańkę: (indeks sąsiada, rodzaj 0 para / 1 odcinek).
        var rows: [[(neighbor: UInt32, kind: UInt32)]] = []

        mutating func addBubble(_ center: Point, radius: Float, stiffness k: Float = 229) {
            bubbles.append(NativeSolverBubble(id: .init(rawValue: bubbles.count + 1), center: center, mass: 0.36, targetRadius: radius))
            stiffness.append(k)
            rows.append([])
        }
    }

    private let limit = 8

    /// Uruchamia `nativeContactForces` z potoku produkcyjnego (`NativeMetalPipelineCache`) na ręcznie zbudowanym sąsiedztwie.
    private func forces(_ scene: ForceScene) throws -> [Point] {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Brak urządzenia Metal") }
        let pipeline = try XCTUnwrap(NativeMetalPipelineCache.pipelines(for: device).stages["nativeContactForces"])
        var bubbles = scene.bubbles.enumerated().map { index, bubble -> NativeMetalBubble in
            var value = NativeMetalBubble(bubble)
            value.contact = SIMD4(0, scene.stiffness[index], 1, 0)
            return value
        }
        if bubbles.isEmpty { bubbles = [NativeMetalBubble(NativeSolverBubble(id: .init(rawValue: 1), center: .zero, mass: 1, targetRadius: 1))] }
        let segments = scene.segments.isEmpty
            ? [NativeMetalSegment(.fixed(id: 1, a: .zero, b: Point(1, 0)))] : scene.segments.map(NativeMetalSegment.init)
        var adjacency = [SIMD4<UInt32>](repeating: .zero, count: bubbles.count * limit)
        var degrees = [UInt32](repeating: 0, count: bubbles.count)
        for (index, row) in scene.rows.enumerated() {
            precondition(row.count <= limit)
            for (slot, item) in row.enumerated() { adjacency[index * limit + slot] = SIMD4(0, item.neighbor, item.kind, 0) }
            degrees[index] = UInt32(row.count)
        }
        let control = NativeMetalControl(counts: SIMD4(UInt32(scene.bubbles.count), UInt32(scene.segments.count), 0, 0),
                                         physics: .zero, contactDamping: .zero)
        let contacts = NativeMetalContactControl(limits: .zero, counts: .zero, cache: SIMD4(0, 0, 0, UInt32(limit)),
                                                 thresholds: .zero, cellWidth: .zero)
        let output = try buffer([Point](repeating: Point(.nan, .nan), count: bubbles.count), device)
        let buffers = [try buffer(bubbles, device), try buffer(segments, device), try buffer([control], device),
                       try buffer([contacts], device), try buffer(adjacency, device), try buffer(degrees, device), output]
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        for (index, value) in buffers.enumerated() { encoder.setBuffer(value, offset: 0, index: index) }
        encoder.dispatchThreads(.init(width: scene.bubbles.count, height: 1, depth: 1),
                                threadsPerThreadgroup: .init(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        return read(output, count: scene.bubbles.count, as: Point.self)
    }

    private func wallForce(_ distance: Double, radius: Double = 24, stiffness: Double = 229) -> Double {
        ContactLawReference.force(epsilon: 1 - distance / radius, stiffness: stiffness)
    }

    private func assertForce(_ value: Point, equals expected: SIMD2<Double>, _ label: String, tolerance: Double = 1e-4,
                             file: StaticString = #filePath, line: UInt = #line) {
        let error = simd_length(SIMD2<Double>(Double(value.x), Double(value.y)) - expected) / max(simd_length(expected), 1e-9)
        XCTAssertLessThanOrEqual(error, tolerance, "\(label): \(value) wobec \(expected)", file: file, line: line)
    }

    private let square: [Point] = [[0, 0], [200, 0], [200, 200], [0, 200]]

    private func polygonScene(_ points: [Point], center: Point, radius: Float = 24) -> ForceScene {
        var scene = ForceScene()
        scene.segments = NativeStaticPolygonEdges.segments(points: points, firstID: 1, ownerID: 100)
        scene.addBubble(center, radius: radius)
        scene.rows[0] = scene.segments.indices.map { (UInt32($0), 1) }
        return scene
    }

    func testBubbleAboveWallEdgeGetsTheLawForceAlongTheOutwardNormalForBothWindings() throws {
        for points in [square, Array(square.reversed())] {
            for distance: Float in [23, 20, 12, 5, 1] {
                // Dolna krawędź kwadratu: normalna zewnętrzna (0, −1), niezależnie od kierunku obiegu.
                let result = try forces(polygonScene(points, center: Point(100, -distance)))
                assertForce(result[0], equals: SIMD2(0, -wallForce(Double(distance))), "d = \(distance)")
            }
        }
    }

    func testBubbleOutsideTheWallRangeAndInsideTheMarginGetsNoForce() throws {
        for distance: Float in [24, 30, 60] {
            let result = try forces(polygonScene(square, center: Point(100, -distance)))
            XCTAssertEqual(result[0], .zero, "d = \(distance)")
        }
    }

    func testConvexVertexGivesOneForceAlongTheLineFromTheVertexAcrossTheWholeSweep() throws {
        // Przegląd kątów wokół wypukłego narożnika (0, 0) kwadratu od normalnej jednej krawędzi do normalnej drugiej, w tym granice
        // obszarów (prostopadłe do krawędzi w wierzchołku). Wzorzec: siła prawa w odległości od najbliższego punktu brzegu, od niego.
        // Gdyby krawędzie dublowały kontakt przy wierzchołku, suma byłaby większa od wzorca.
        let distance: Float = 15
        for degrees in stride(from: 180.0, through: 270.0, by: 7.5) {
            let angle = Float(degrees * .pi / 180)
            let center = Point(cos(angle), sin(angle)) * distance
            for points in [square, Array(square.reversed())] {
                let result = try forces(polygonScene(points, center: center))
                let closest = SIMD2<Double>(0, 0)
                let delta = SIMD2<Double>(Double(center.x), Double(center.y)) - closest
                let d = simd_length(delta)
                assertForce(result[0], equals: delta / d * wallForce(d), "\(degrees)°")
            }
        }
    }

    func testBubbleBesideTheVertexOnTheEdgeLineIsContinuousWithTheEdgeInterior() throws {
        // Dokładnie pod wierzchołkiem (rzut na krawędź = początek): prawo daje to samo, co przy wnętrzu krawędzi.
        let atVertex = try forces(polygonScene(square, center: Point(0, -18)))
        let nearby = try forces(polygonScene(square, center: Point(0.01, -18)))
        assertForce(atVertex[0], equals: SIMD2(0, -wallForce(18)), "pod wierzchołkiem")
        assertForce(nearby[0], equals: SIMD2(0, -wallForce(18)), "tuż obok", tolerance: 1e-3)
    }

    func testCenterBehindTheEdgeLineGetsNoForceFromThatEdgeSoAThinWallDoesNotPushThrough() throws {
        // Cienka ściana 100 × 1: bańka przed dolną krawędzią dostaje siłę tylko od niej, nie od tylnej (górnej) krawędzi,
        // której prosta jest za środkiem (d < 0). To zastępuje krawędź wejścia z v3.0.x.
        let wall: [Point] = [[0, 0], [100, 0], [100, 1], [0, 1]]
        let front = try forces(polygonScene(wall, center: Point(50, -10)))
        assertForce(front[0], equals: SIMD2(0, -wallForce(10)), "przed ścianą")
        let back = try forces(polygonScene(wall, center: Point(50, 11)))
        assertForce(back[0], equals: SIMD2(0, wallForce(10)), "za ścianą")
        // Środek wewnątrz wielokąta: żadna krawędź nie wypycha (naruszenie to sprawa asercji kontaktu).
        let inside = try forces(polygonScene(square, center: Point(100, 10)))
        XCTAssertEqual(inside[0], .zero)
    }

    func testConcaveCornerGivesTwoIndependentEdgeForces() throws {
        // Litera L: wklęsły narożnik (48, 48), środek w kącie o 10 od obu krawędzi, każda krawędź daje własną sprężynę.
        let letterL: [Point] = [[0, 0], [200, 0], [200, 48], [48, 48], [48, 200], [0, 200]]
        let result = try forces(polygonScene(letterL, center: Point(58, 58)))
        let one = wallForce(10)
        assertForce(result[0], equals: SIMD2(one, one), "wklęsły narożnik")
    }

    func testPlainSegmentUsesTheClosestPointOfTheSegment() throws {
        var scene = ForceScene()
        scene.segments = [.fixed(id: 1, a: Point(0, 0), b: Point(100, 0))]
        scene.addBubble(Point(50, 10), radius: 24)
        scene.addBubble(Point(130, 0), radius: 24) // za końcem odcinka: najbliższy punkt to koniec (100, 0)
        scene.rows[0] = [(0, 1)]; scene.rows[1] = [(0, 1)]
        let result = try forces(scene)
        assertForce(result[0], equals: SIMD2(0, wallForce(10)), "nad odcinkiem")
        XCTAssertEqual(result[1], .zero, "za końcem (d = 30 > r)")
    }

    func testPairOfTheSameMaterialPushesApartWithExactlyOppositeForces() throws {
        for (ra, rb) in [(Float(24), Float(24)), (24, 148), (148, 12)] {
            var scene = ForceScene()
            let distance = (ra + rb) * 0.8
            // Bańka o większym indeksie jest pierwsza w wierszu drugiej: kolejność w wierszu nie wpływa na wynik.
            scene.addBubble(Point(10, 20), radius: ra); scene.addBubble(Point(10 + distance * 0.6, 20 + distance * 0.8), radius: rb)
            scene.rows[0] = [(1, 0)]; scene.rows[1] = [(0, 0)]
            let result = try forces(scene)
            let d = Double(simd_distance(scene.bubbles[0].center, scene.bubbles[1].center)), r = Double(ra + rb)
            let force = 229 * (r - d) * r / (d * d)
            let normal = SIMD2<Double>(0.6, 0.8)
            assertForce(result[1], equals: normal * force, "druga bańka, r \(ra)/\(rb)", tolerance: 1e-4)
            // Dokładnie przeciwne wektory (siła pary liczy się raz w kolejności indeksów), więc pęd się zachowuje bit w bit.
            XCTAssertEqual(result[0], -result[1], "r \(ra)/\(rb)")
        }
    }

    func testPairOfDifferentMaterialsMatchesTheDoubleSolutionAndIsSymmetric() throws {
        let cases: [(ka: Float, ra: Float, kb: Float, rb: Float, fraction: Float)] = [
            (229, 24, 2290, 24, 0.3), (229, 24, 229_000, 148, 0.5), (22_900, 12, 22, 148, 0.9), (229, 148, 229, 24, 0.5)]
        for item in cases {
            var scene = ForceScene()
            let distance = (item.ra + item.rb) * (1 - item.fraction)
            scene.addBubble(Point(0, 0), radius: item.ra, stiffness: item.ka)
            scene.addBubble(Point(distance, 0), radius: item.rb, stiffness: item.kb)
            scene.rows[0] = [(1, 0)]; scene.rows[1] = [(0, 0)]
            let result = try forces(scene)
            let reference = try XCTUnwrap(ContactLawReference.pairContact(
                overlap: Double(item.ra + item.rb) - Double(distance),
                a: .init(radius: Double(item.ra), stiffness: Double(item.ka)),
                b: .init(radius: Double(item.rb), stiffness: Double(item.kb))))
            // Bańka 0 jest po lewej: odpychana w −x, bańka 1 w +x.
            assertForce(result[1], equals: SIMD2(reference.force, 0), "K \(item.ka)/\(item.kb)", tolerance: 1e-2)
            XCTAssertEqual(result[0], -result[1], "K \(item.ka)/\(item.kb)")
        }
    }

    func testForcesAddUpOverWallAndPairContactsOfTheSameBubble() throws {
        var scene = ForceScene()
        scene.segments = NativeStaticPolygonEdges.segments(points: square, firstID: 1, ownerID: 100)
        scene.addBubble(Point(100, -20), radius: 24)         // nad dolną krawędzią (w jej wnętrzu)
        scene.addBubble(Point(100 + 30, -20), radius: 24)    // obok, w odległości 30 < 48
        scene.rows[0] = [(1, 0)] + scene.segments.indices.map { (UInt32($0), UInt32(1)) }
        scene.rows[1] = [(0, 0)]
        let result = try forces(scene)
        let pair = 229 * (48 - 30.0) * 48 / (30.0 * 30.0)
        assertForce(result[0], equals: SIMD2(-pair, -wallForce(20)), "bańka przy ścianie i sąsiadce")
        assertForce(result[1], equals: SIMD2(pair, 0), "sąsiadka bez kontaktu ze ścianą w swoim wierszu")
    }

    func testBubbleWithoutContactsGetsAZeroForceRecord() throws {
        var scene = ForceScene()
        scene.addBubble(Point(0, 0), radius: 24)
        scene.addBubble(Point(500, 0), radius: 24)
        let result = try forces(scene)
        XCTAssertEqual(result, [.zero, .zero])
    }
}
