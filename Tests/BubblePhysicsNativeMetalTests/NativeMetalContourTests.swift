import XCTest
import Metal
import BubblePhysicsReference
@testable import BubblePhysicsNativeMetal

@MainActor
final class NativeMetalContourTests: XCTestCase {
    // Usunięcie walidacji rzeczywistych punktów dopuści krawędzie dłuższe od
    // limitu, gdy rozdzielczość float32 w dużych współrzędnych przekracza limit.
    func testUnrepresentableContourEdgeRejectsFrameAndPreservesPublishedState() async throws {
        let solver = try makeSolver()
        var world = try makeWorld()
        let approved = try await solver.executeFrame(world: world, scenarioStep: 1)
        var bubble = world.bubbles[0]
        bubble.center = .init(x: 10_000_000, y: 10_000_000)
        world.updateBubble(bubble)
        do {
            _ = try await solver.executeFrame(world: world, scenarioStep: 2)
            XCTFail("Contour edges exceeding the configured limit must reject the GPU frame")
        } catch let failure as NativeMetalSafetyFailure {
            guard case .invalidFrame = failure.reason else {
                return XCTFail("Unexpected safety failure: \(failure.reason)")
            }
            XCTAssertFalse(failure.telemetry.didEncounterNonFinite)
            XCTAssertEqual(failure.telemetry.commandBufferCount, 1)
        }
        XCTAssertEqual(solver.publishedFrame?.bubbles, approved.bubbles)
        XCTAssertEqual(solver.publishedFrame?.contours, approved.contours)
    }

    func testDeepNarrowContactHonorsEveryEdgeLengthWithAndWithoutSurfaceTension() async throws {
        for tension: Float in [20, 0] {
            let solver = try makeSolver()
            var world = ReferenceWorld(configuration: .init(timeStep: 1 / 60, linearDamping: 0,
                angularDamping: 0, maxContourSegmentLength: 0.1, contourSurfaceTension: tension),
                broadPhase: BruteForceBroadPhase())
            world.addBubble(try .init(id: .init(rawValue: 1), center: .init(x: -0.001, y: 0), mass: 1, targetRadius: 1))
            world.addSegment(.staticSegment(id: .init(rawValue: 1), a: .init(x: 0, y: -0.001), b: .init(x: 0, y: 0.001)))
            let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
            let bubble = frame.bubbles[0]
            let points = try XCTUnwrap(frame.contours[bubble.id])
            XCTAssertTrue(frame.isComplete)
            XCTAssertLessThan((points[0] - bubble.center).length, 0.1)
            XCTAssertTrue(points.contains { abs($0.y) > 0.5 && ($0 - bubble.center).length > 0.9 })
            for index in points.indices {
                XCTAssertLessThanOrEqual((points[(index + 1) % points.count] - points[index]).length,
                    0.1, "tension=\(tension), edge=\(index)")
            }
        }
    }

    func testDefaultHardContactDoesNotLeaveCacheDrivenContourDeformation() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var world = try makeWorld()
        world.addSegment(wall())
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        let points = try XCTUnwrap(frame.contours[.init(rawValue: 1)])
        let bubble = frame.bubbles[0]
        XCTAssertEqual(bubble.center.x, -1, accuracy: 0.00001)
        XCTAssertLessThanOrEqual(frame.contacts[0].penetration, 0.0001)
        XCTAssertGreaterThan(frame.contacts[0].accumulatedCompression, 0.3)
        XCTAssertEqual((points[0] - bubble.center).length, 1, accuracy: 0.001)
        XCTAssertEqual((points[points.count / 2] - bubble.center).length, 1, accuracy: 0.001)
        // Raport liczy również śladową, wygaszaną pamięć po poprzedniej
        // geometrii. Kontrakt wizualny to brak widocznego odkształcenia, nie
        // bezwzględne wyzerowanie tej pomocniczej wartości float32.
        XCTAssertLessThanOrEqual(frame.report.solver.maximumRelativeDeformation, 0.001)
    }

    // Brak nacisku kierunkowego pozostawi naturalny promień po stronie ściany.
    func testContactFlattensContourAlongContactNormal() async throws {
        let solver = try makeSolver()
        var world = try makeWorld()
        world.addSegment(wall())
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        let points = try XCTUnwrap(frame.contours[.init(rawValue: 1)])
        let center = frame.bubbles[0].center
        XCTAssertGreaterThanOrEqual(points.count, 32)
        XCTAssertTrue(points.allSatisfy { $0.isFinite && $0.x <= 0.0001 })
        XCTAssertLessThan(points[0].x - center.x, 0.9)
        XCTAssertEqual((points[points.count / 2] - center).length, 1, accuracy: 0.001)
        XCTAssertLessThanOrEqual(maximumEdge(points), world.configuration.maxContourSegmentLength)
    }

    // Zgubienie pamięci deformacji przy zmianie wejścia CPU dałoby natychmiastowy skok do koła.
    func testReleasedContourReturnsWithinTwoPercentAfterThirtyFrames() async throws {
        let solver = try makeSolver()
        var world = try makeWorld()
        world.addSegment(wall())
        let loaded = try await solver.executeFrame(world: world, scenarioStep: 1)
        let loadedPoints = try XCTUnwrap(loaded.contours[.init(rawValue: 1)])
        let loadedDeficit = 1 - (loadedPoints[0] - loaded.bubbles[0].center).length
        XCTAssertGreaterThan(loadedDeficit, 0.1)
        world.removeSegment(id: .init(rawValue: 1))
        var bubble = loaded.bubbles[0]; bubble.velocity = .zero; world.updateBubble(bubble)
        let released = try await solver.executeFrame(world: world, scenarioStep: 2)
        let firstPoints = try XCTUnwrap(released.contours[bubble.id])
        let firstDeficit = 1 - (firstPoints[0] - released.bubbles[0].center).length
        XCTAssertGreaterThan(firstDeficit, 0)
        XCTAssertLessThan(firstDeficit, loadedDeficit)
        var final = released
        for step in 3...31 { final = try await solver.executeFrame(world: world, scenarioStep: step) }
        let points = try XCTUnwrap(final.contours[bubble.id])
        XCTAssertTrue(points.allSatisfy { abs(($0 - final.bubbles[0].center).length - 1) <= 0.02 })
    }

    // Akumulacja nacisku co klatkę nie może pompować spoczynkowego konturu.
    func testRestingContourDoesNotGainOscillationAmplitude() async throws {
        let solver = try makeSolver()
        var world = try makeWorld()
        world.addSegment(wall())
        let first = try await solver.executeFrame(world: world, scenarioStep: 1)
        let firstPoints = try XCTUnwrap(first.contours[.init(rawValue: 1)])
        let firstAmplitude = firstPoints.map { abs(($0 - first.bubbles[0].center).length - 1) }.max()!
        var bubble = first.bubbles[0]; bubble.velocity = .zero; world.updateBubble(bubble)
        for step in 2...32 {
            let frame = try await solver.executeFrame(world: world, scenarioStep: step)
            let points = try XCTUnwrap(frame.contours[bubble.id])
            XCTAssertTrue(points.allSatisfy(\.isFinite))
            XCTAssertLessThanOrEqual(points.map { abs(($0 - frame.bubbles[0].center).length - 1) }.max()!, firstAmplitude + 0.001)
        }
    }

    // Pakowanie ze stanu predykcji zamiast wyniku guardów publikuje zły środek.
    func testPublishedRenderDataMatchesApprovedCenters() async throws {
        let solver = try makeSolver()
        var world = try makeWorld()
        var bubble = world.bubbles[0]; bubble.velocity.x = 100; world.updateBubble(bubble)
        world.addSegment(wall())
        let runner = NativeMetalWorldRunner(executor: solver)
        _ = await runner.step(world: &world, scenarioStep: 1)
        let frame = try XCTUnwrap(solver.publishedFrame)
        XCTAssertTrue(frame.isComplete)
        XCTAssertEqual(frame.renderData.count, 1)
        XCTAssertEqual(frame.renderData.first, SIMD4(frame.bubbles[0].center.x, frame.bubbles[0].center.y, 1, 0))
        XCTAssertEqual(runner.telemetry.backend, .nativeMetal)
        XCTAssertNil(runner.telemetry.fallbackReason)
        XCTAssertEqual(world.bubbles, frame.bubbles)
        XCTAssertEqual(world.contour(for: bubble.id), frame.contours[bubble.id])
    }

    func testNaturalCircleAndFiniteVertexEnvelope() async throws {
        let solver = try makeSolver()
        var world = try makeWorld()
        let natural = try await solver.executeFrame(world: world, scenarioStep: 1)
        XCTAssertTrue(try XCTUnwrap(natural.contours[.init(rawValue: 1)]).allSatisfy {
            abs(($0 - natural.bubbles[0].center).length - 1) < 0.00001
        })
        // Krótka krawędź nie może ciąć pełnej półpłaszczyzny jak nieskończona ściana.
        world.addSegment(.staticSegment(id: .init(rawValue: 1), a: .init(x: 0, y: -0.1), b: .init(x: 0, y: 0.1)))
        let frame = try await solver.executeFrame(world: world, scenarioStep: 2)
        let points = try XCTUnwrap(frame.contours[.init(rawValue: 1)])
        XCTAssertTrue(points.allSatisfy(\.isFinite))
        XCTAssertLessThanOrEqual(points[0].x, 0.0001)
        XCTAssertTrue(points.contains { $0.x > 0 && abs($0.y) > 0.5 })
        XCTAssertLessThanOrEqual(maximumEdge(points), world.configuration.maxContourSegmentLength)
    }

    func testDeformationFollowsIDThroughInsertionRemovalAndContourCapacityGrowth() async throws {
        let solver = try makeSolver()
        var world = try makeWorld()
        world.addSegment(wall())
        let loaded = try await solver.executeFrame(world: world, scenarioStep: 1)
        world.removeSegment(id: .init(rawValue: 1))
        var bubble = loaded.bubbles[0]; bubble.velocity = .zero; world.updateBubble(bubble)
        world.addBubble(try .init(id: .init(rawValue: 0), center: .init(x: 10, y: 10), mass: 1, targetRadius: 3))
        let inserted = try await solver.executeFrame(world: world, scenarioStep: 2)
        let original = inserted.bubbles.first { $0.id == bubble.id }!
        let points = try XCTUnwrap(inserted.contours[bubble.id])
        XCTAssertLessThan((points[0] - original.center).length, 0.9)
        let added = inserted.bubbles[0]
        XCTAssertTrue(try XCTUnwrap(inserted.contours[added.id]).allSatisfy { abs(($0 - added.center).length - 3) < 0.00001 })
        world = ReferenceWorld(configuration: world.configuration, broadPhase: BruteForceBroadPhase())
        world.addBubble(added)
        world.addBubble(try .init(id: .init(rawValue: 2), center: .init(x: -5, y: 0), mass: 1, targetRadius: 1))
        let replaced = try await solver.executeFrame(world: world, scenarioStep: 3)
        let fresh = replaced.bubbles.first { $0.id.rawValue == 2 }!
        XCTAssertTrue(try XCTUnwrap(replaced.contours[fresh.id]).allSatisfy { abs(($0 - fresh.center).length - 1) < 0.00001 })
    }

    func testBubblePairUsesFiniteSharedChordAndCornerStaysInEnvelope() async throws {
        let solver = try makeSolver()
        var world = try makeWorld()
        world.addBubble(try .init(id: .init(rawValue: 2), center: .init(x: 0.8, y: 0), mass: 1, targetRadius: 1))
        let pair = try await solver.executeFrame(world: world, scenarioStep: 1)
        let first = pair.bubbles[0], second = pair.bubbles[1]
        let points = try XCTUnwrap(pair.contours[first.id])
        XCTAssertLessThanOrEqual(points[0].x, (first.center.x + second.center.x) * 0.5 + 0.0001)
        XCTAssertEqual((points[points.count / 2] - first.center).length, 1, accuracy: 0.001)
        var cornerWorld = try makeWorld()
        cornerWorld.addSegment(wall())
        cornerWorld.addSegment(.staticSegment(id: .init(rawValue: 2), a: .init(x: -10, y: 0.6), b: .init(x: 10, y: 0.6)))
        let corner = try await makeSolver().executeFrame(world: cornerWorld, scenarioStep: 1)
        let cornerPoints = try XCTUnwrap(corner.contours[first.id])
        XCTAssertTrue(cornerPoints.allSatisfy { $0.isFinite && $0.x <= 0.0001 && $0.y <= 0.6001 })
        XCTAssertLessThanOrEqual(maximumEdge(cornerPoints), cornerWorld.configuration.maxContourSegmentLength)
    }

    private func makeSolver() throws -> NativeMetalSolver {
        try .init(device: XCTUnwrap(MTLCreateSystemDefaultDevice()), configuration: .init(contactCompliance: 0.01))
    }

    private func makeWorld() throws -> ReferenceWorld {
        var world = ReferenceWorld(configuration: .init(timeStep: 1 / 60, linearDamping: 0,
            angularDamping: 0, maxContourSegmentLength: 0.1), broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 1), center: .init(x: -0.6, y: 0), mass: 1, targetRadius: 1))
        return world
    }

    private func wall() -> ReferenceSegment {
        .staticSegment(id: .init(rawValue: 1), a: .init(x: 0, y: -10), b: .init(x: 0, y: 10))
    }

    private func maximumEdge(_ points: [ReferenceVector2]) -> Float {
        points.indices.map { (points[($0 + 1) % points.count] - points[$0]).length }.max() ?? 0
    }
}
