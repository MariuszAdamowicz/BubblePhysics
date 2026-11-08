import BubblePhysics
import BubblePhysicsMetalRender
import Metal
import XCTest

/// Sonda determinizmu (G10-AC5, P-B-9): ta sama scena z tymi samymi transakcjami, dwa razy na tym samym
/// urządzeniu, daje identyczny opublikowany stan. Hashuje bity liczb, więc różnica o 1 ULP zostaje wykryta.
/// Hash obejmuje `frame.objects` (bańki i bryły: pozycja, prędkość, obrót, prędkość kątowa, AABB, promień)
/// oraz kontury baniek.
@MainActor
final class PublishedStateDeterminismTests: XCTestCase {
    private struct Run {
        let hash: UInt64
        let completedSteps: UInt64
        let bubbleCount: Int
        let objectCount: Int
        let objectHash: UInt64
    }

    private func fnv1a(_ values: some Sequence<UInt32>, into hash: inout UInt64) {
        for value in values {
            for shift in stride(from: 0, to: 32, by: 8) {
                hash = (hash ^ UInt64((value >> UInt32(shift)) & 0xFF)) &* 0x100_0000_01B3
            }
        }
    }

    private func run(steps: Int, device: MTLDevice) async throws -> Run {
        let world = try BubbleWorld.makeBenchmarkWorld(configuration: try Stress300Scene.configuration(),
            device: device, solverIterationLimit: 4)
        world.submit(try Stress300Scene.initialTransaction())
        var frame = WorldFrame(transactionReceipts: [], events: [])
        for index in 0..<steps {
            if index > 0 { world.submit(try Stress300Scene.triangleReplacement(step: index)) }
            frame = await world.advance(by: 1.0 / 60)
        }
        var objectHash: UInt64 = 0xCBF2_9CE4_8422_2325
        for id in frame.objects.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let object = frame.objects[id] else { continue }
            let kind: [UInt32]
            switch object.kind {
            case .bubble(let radius): kind = [1, radius.bitPattern]
            case .polygon: kind = [2, 0]
            }
            fnv1a([UInt32(truncatingIfNeeded: id.rawValue), UInt32(truncatingIfNeeded: id.rawValue >> 32)] + kind
                + [object.position.x, object.position.y, object.velocity.x, object.velocity.y,
                   object.rotation, object.angularVelocity,
                   object.bounds.min.x, object.bounds.min.y, object.bounds.max.x, object.bounds.max.y]
                    .map(\.bitPattern), into: &objectHash)
        }
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        let contours = world.debugContourSnapshot()
        for id in contours.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            fnv1a([UInt32(truncatingIfNeeded: id.rawValue)], into: &hash)
            for point in contours[id] ?? [] { fnv1a([point.x.bitPattern, point.y.bitPattern], into: &hash) }
        }
        return Run(hash: hash, completedSteps: frame.stepIndex, bubbleCount: contours.count,
                   objectCount: frame.objects.count, objectHash: objectHash)
    }

    func testStress300PublishedStateIsIdenticalAcrossTwoRunsOf300Steps() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let first = try await run(steps: 300, device: device)
        let second = try await run(steps: 300, device: device)
        XCTAssertEqual(first.completedSteps, 300)
        XCTAssertEqual(first.bubbleCount, 300)
        // 300 baniek, 4 ściany i trójkąt.
        XCTAssertEqual(first.objectCount, 305)
        XCTAssertEqual(second.objectCount, 305)
        XCTAssertEqual(first.hash, second.hash, "kontury po 300 krokach różnią się między przebiegami")
        XCTAssertEqual(first.objectHash, second.objectHash,
                       "stan obiektów (frame.objects) po 300 krokach różni się między przebiegami")
    }

    func testHashReactsToStateChange() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let early = try await run(steps: 1, device: device)
        let late = try await run(steps: 300, device: device)
        XCTAssertNotEqual(early.hash, late.hash)
        XCTAssertNotEqual(early.objectHash, late.objectHash)
    }

    // MARK: - Zwolnienie po przepełnieniu kandydatów (P-B-64, G10-AC5)

    private struct SqueezeRun {
        var overflow: [Int] = []
        var hashes: [UInt64] = []
        var published = 0
    }

    /// 300 baniek na siatce (kroki 1-10 bez kontaktów), potem transakcja `replace` ściska je w kwadracie 30×30,
    /// gdzie wiersz kandydatów przekracza limit k.
    private func squeezeRun(steps: Int, device: MTLDevice) async throws -> SqueezeRun {
        let material = PhysicsMaterialID(rawValue: 1), style = RenderStyleID(rawValue: 1)
        let world = try BubbleWorld.makeBenchmarkWorld(configuration: WorldConfiguration(
            simulationRegion: WorldRectangle(min: [0, 0], max: [700, 500]), fixedTimeStep: 1.0 / 60),
            device: device, solverIterationLimit: 4)
        func descriptor(_ id: Int, _ position: WorldPoint, radius: Float) throws -> WorldObject {
            .bubble(try BubbleDescriptor(id: ObjectID(rawValue: UInt64(id)), position: position, targetRadius: radius,
                physicsMaterialID: material, renderStyleID: style))
        }
        var initial = try WorldTransaction()
            .updatePhysicsMaterial(material, material: PhysicsMaterial(kind: .bubble))
            .updateRenderStyle(style, style: RenderStyle())
        for index in 0..<300 {
            initial = initial.add(try descriptor(index + 1, [Float(index % 20) * 30 + 40, Float(index / 20) * 30 + 40], radius: 5))
        }
        world.submit(initial)
        var seed: UInt64 = 0x2B60F5
        func unit() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(seed >> 40) / Float(1 << 24)
        }
        var run = SqueezeRun()
        for index in 0..<steps {
            if index == 10 {
                var squeeze = WorldTransaction()
                for id in 1...300 {
                    squeeze = squeeze.replace(ObjectID(rawValue: UInt64(id)),
                        with: try descriptor(id, [335 + unit() * 30, 235 + unit() * 30], radius: 2))
                }
                world.submit(squeeze)
            }
            let frame = await world.advance(by: 1.0 / 60)
            run.published += frame.stepIndex == UInt64(index + 1) ? 1 : 0
            run.overflow.append(world.diagnostics.contactCandidateOverflow)
            var hash: UInt64 = 0xCBF2_9CE4_8422_2325
            for id in frame.objects.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard let object = frame.objects[id] else { continue }
                fnv1a([UInt32(truncatingIfNeeded: id.rawValue), object.position.x.bitPattern, object.position.y.bitPattern,
                       object.velocity.x.bitPattern, object.velocity.y.bitPattern], into: &hash)
            }
            run.hashes.append(hash)
        }
        return run
    }

    /// Krok, w którym licznik po raz pierwszy wzrósł (indeks od 0), albo `nil`.
    private func firstOverflowStep(_ overflow: [Int]) -> Int? {
        var previous = 0
        for (index, value) in overflow.enumerated() {
            if value > previous { return index }
            previous = value
        }
        return nil
    }

    func testStateIsComparedOnlyBeforeCandidateOverflowStep() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let steps = 40
        let first = try await squeezeRun(steps: steps, device: device)
        let second = try await squeezeRun(steps: steps, device: device)
        XCTAssertEqual(first.published, steps, "klatka po przepełnieniu jest opublikowana")
        XCTAssertEqual(second.published, steps)
        let overflowStep = [firstOverflowStep(first.overflow), firstOverflowStep(second.overflow)].compactMap { $0 }.min()
        let step = try XCTUnwrap(overflowStep, "ściśnięcie 300 baniek musi zwiększyć licznik przepełnienia kandydatów")
        XCTAssertGreaterThanOrEqual(step, 10, "przed ściśnięciem nie ma przepełnienia")
        // Kroki przed pierwszym przepełnieniem muszą być identyczne; od niego porównanie jest pominięte.
        for index in 0..<step {
            XCTAssertEqual(first.hashes[index], second.hashes[index], "stan po kroku \(index + 1) różni się, a przepełnienia jeszcze nie było")
        }
    }
}
