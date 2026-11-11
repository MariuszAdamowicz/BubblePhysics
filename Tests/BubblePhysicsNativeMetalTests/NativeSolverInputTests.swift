import XCTest
import Metal
@testable import BubblePhysicsNativeMetal

/// Neutralne wejście i wynik solvera: żadnego typu `BubblePhysicsReference`.
@MainActor
final class NativeSolverInputTests: XCTestCase {
    private func input(_ bubbles: [NativeSolverBubble], segments: [NativeSolverSegment] = []) -> NativeSolverInput {
        NativeSolverInput(configuration: .init(timeStep: 0.5, linearDamping: 0, angularDamping: 0),
                          bubbles: bubbles, segments: segments)
    }

    private func bubble(_ id: Int, x: Float, y: Float = 0, vx: Float = 0, radius: Float = 1) -> NativeSolverBubble {
        NativeSolverBubble(id: .init(rawValue: id), center: [x, y], velocity: [vx, 0], mass: 1, targetRadius: radius)
    }

    func testExecuteFrameAdvancesNeutralBubbleAndPublishesContour() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let frame = try await solver.executeFrame(input: input([bubble(7, x: 0, vx: 2)]), scenarioStep: 1)
        XCTAssertTrue(frame.isComplete)
        XCTAssertEqual(frame.bubbles.map(\.id), [.init(rawValue: 7)])
        XCTAssertEqual(frame.bubbles[0].center.x, 1, accuracy: 1e-5)
        XCTAssertEqual(frame.bubbles[0].previousCenter.x, 0, accuracy: 1e-5)
        XCTAssertEqual(frame.renderData.count, 1)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(frame.contours[.init(rawValue: 7)]).count, 32)
        XCTAssertEqual(try XCTUnwrap(frame.effectiveRadii[.init(rawValue: 7)]), 1, accuracy: 1e-5)
        XCTAssertTrue(frame.contacts.isEmpty)
    }

    func testOverlappingBubblesProduceNeutralBubbleContact() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let frame = try await solver.executeFrame(
            input: input([bubble(1, x: 0), bubble(2, x: 1.5)]), scenarioStep: 1)
        let contact = try XCTUnwrap(frame.contacts.first)
        XCTAssertEqual(contact.kind, .bubbleBubble)
        XCTAssertEqual(Set([contact.bubbleA, try XCTUnwrap(contact.bubbleB)]),
                       [.init(rawValue: 1), .init(rawValue: 2)])
        XCTAssertNil(contact.segment)
        XCTAssertEqual(frame.report.generatedContactCount, frame.contacts.count)
        XCTAssertFalse(frame.report.hasNonFiniteState)
    }

    func testBubbleMeetsStaticSegmentAsNeutralSegmentContact() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let wall = NativeSolverSegment.fixed(id: 40, a: [-5, 0.5], b: [5, 0.5])
        let frame = try await solver.executeFrame(input: input([bubble(1, x: 0)], segments: [wall]), scenarioStep: 1)
        let contact = try XCTUnwrap(frame.contacts.first)
        XCTAssertEqual(contact.kind, .bubbleSegment)
        XCTAssertEqual(contact.segment, 40)
        XCTAssertNil(contact.bubbleB)
    }

    func testSnapshotOfUnchangedInputHasNoBubbleChanges() throws {
        let value = input([bubble(1, x: 0), bubble(2, x: 4)])
        let first = NativeMetalSnapshot(input: value)
        XCTAssertEqual(first.bubbleChanges.count, 2)
        let second = NativeMetalSnapshot(input: value, previous: first)
        XCTAssertTrue(second.bubbleChanges.isEmpty)
        var moved = value
        moved.bubbles[1].center.x = 5
        XCTAssertEqual(NativeMetalSnapshot(input: moved, previous: first).bubbleChanges.map(\.index), [1])
    }

    func testSnapshotKeepsSegmentSideAndKinematicFlagsInABI() {
        var segment = NativeSolverSegment.fixed(id: 3, a: [0, 0], b: [1, 0], ownerID: 9)
        segment.allowedSide = -1
        segment.isKinematic = true
        let record = NativeMetalSegment(segment)
        XCTAssertEqual(record.identity, SIMD2(3, 9))
        XCTAssertEqual(record.flags, SIMD4(1, 1, 1, 0))
        XCTAssertEqual(record.collision.x, -1)
    }
}
