import BubblePhysicsModel
import Metal
@testable import BubblePhysicsNativeMetal
import XCTest

/// P-B-20, P-B-21 (G12-AC2): pamięć kontaktów baniek i odcinków rośnie liniowo (O(n·k)), a wymuszone
/// przepełnienie limitu k zwiększa licznik, publikuje klatkę i nie daje wartości nieskończonych.
@MainActor
final class NativeMetalContactMemoryTests: XCTestCase {
    private let bubbleMaterial = PhysicsMaterialID(rawValue: 1)
    private let polygonMaterial = PhysicsMaterialID(rawValue: 2)
    private let style = RenderStyleID(rawValue: 1)
    private var limit: Int { NativeMetalSolver.candidateLimitPerObject }

    private struct LCG {
        var state: UInt64 = 0x2B60F5
        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24)
        }
    }

    private func bubble(_ id: UInt64, _ position: WorldPoint, radius: Float) throws -> NativePublicObject {
        NativePublicObject(descriptor: .bubble(try BubbleDescriptor(id: ObjectID(rawValue: id), position: position,
            targetRadius: radius, physicsMaterialID: bubbleMaterial, renderStyleID: style)))
    }

    private func box(_ id: UInt64, _ center: WorldPoint, half: Float) throws -> NativePublicObject {
        NativePublicObject(descriptor: .polygon(try PolygonDescriptor(id: ObjectID(rawValue: id),
            vertices: [[-half, -half], [half, -half], [half, half], [-half, half]], position: center,
            physicsMaterialID: polygonMaterial, renderStyleID: style)))
    }

    /// Bańki na siatce co 30 (promień 5, bez kontaktów) i co dziesiąta komórka ze statycznym pudełkiem (4 odcinki).
    private func sparseScene(bubbles n: Int, boxes: Int) throws -> [NativePublicObject] {
        var objects: [NativePublicObject] = []
        let columns = 40
        for index in 0..<n {
            objects.append(try bubble(UInt64(index + 1), [Float(index % columns) * 30 + 15, Float(index / columns) * 30 + 15], radius: 5))
        }
        for index in 0..<boxes {
            let cell = index * 10
            objects.append(try box(UInt64(100_000 + index), [Float(cell % columns) * 30 + 30, Float(cell / columns) * 30 + 30], half: 2))
        }
        return objects
    }

    private func step(_ world: NativePublicWorld, _ objects: [NativePublicObject]) async throws -> NativePublicFrame {
        try await world.step(objects: objects,
            materials: [bubbleMaterial: try PhysicsMaterial(kind: .bubble), polygonMaterial: try PhysicsMaterial(kind: .polygon)],
            styles: [style: try RenderStyle()], region: WorldRectangle(min: [0, 0], max: [1400, 1100]), duration: 1.0 / 60)
    }

    private func memory(bubbles n: Int, boxes: Int) async throws -> Int {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        _ = try await step(world, sparseScene(bubbles: n, boxes: boxes))
        return world.contactMemoryBytes
    }

    // Zachowanie O(n²) daje ok. 16× przy 4× większej scenie; liniowe daje 4×.
    func testBubbleAndSegmentContactMemoryGrowsLinearlyFrom300To1200() async throws {
        let small = try await memory(bubbles: 300, boxes: 30)
        let large = try await memory(bubbles: 1200, boxes: 120)
        XCTAssertGreaterThan(small, 0)
        XCTAssertLessThanOrEqual(Double(large) / Double(small), 5.0,
            "pamięć kontaktów: \(small) B dla 300 baniek i \(large) B dla 1200 rośnie szybciej niż liniowo")
    }

    // Górna granica O(n·k): 2 KiB na parę (obiekt, slot kandydata) to ponad trzykrotny zapas nad zapisem rekordów.
    func testContactMemoryStaysWithinPerObjectCandidateBudget() async throws {
        for (bubbles, boxes) in [(300, 30), (1200, 120)] {
            let bytes = try await memory(bubbles: bubbles, boxes: boxes)
            let budget = (bubbles + boxes * 4) * limit * 2048
            XCTAssertLessThanOrEqual(bytes, budget, "\(bubbles) baniek i \(boxes * 4) odcinków: \(bytes) B > \(budget) B")
        }
    }

    func testSparseSceneStaysWithinLimitWithoutOverflow() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let frame = try await step(world, sparseScene(bubbles: 300, boxes: 30))
        XCTAssertEqual(frame.contactCandidateOverflowCount, 0)
        XCTAssertLessThanOrEqual(frame.maximumContactCandidatesPerObject, limit)
    }

    // P-B-21: 300 baniek ściśniętych w kwadracie 30×30 daje każdej z pierwszych baniek ponad k sąsiadów.
    func testForcedOverflowRaisesCounterPublishesFrameAndStaysFinite() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var random = LCG()
        let squeezed = try (0..<300).map { try bubble(UInt64($0 + 1), [100 + random.next() * 30, 100 + random.next() * 30], radius: 2) }
        var frame = try await step(world, squeezed)
        XCTAssertGreaterThan(frame.contactCandidateOverflowCount, 0, "przepełnienie k = \(limit) musi zwiększyć licznik")
        XCTAssertGreaterThanOrEqual(frame.maximumContactCandidatesPerObject, limit)
        for _ in 0..<5 { frame = try await step(world, Array(frame.objects.values)) }
        XCTAssertEqual(frame.objects.count, 300, "klatka po przepełnieniu jest opublikowana")
        for object in frame.objects.values {
            XCTAssertTrue(object.position.x.isFinite && object.position.y.isFinite
                && object.velocity.x.isFinite && object.velocity.y.isFinite)
        }
        let sparse = try await memory(bubbles: 300, boxes: 0)
        XCTAssertEqual(world.contactMemoryBytes, sparse, "pamięć nie zależy od gęstości sceny")
    }
}
