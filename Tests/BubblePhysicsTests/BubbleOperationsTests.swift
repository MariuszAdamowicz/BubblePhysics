import XCTest
@testable import BubblePhysics

final class BubbleOperationsTests: XCTestCase {
    func testResizeChangesRestAreaAndEmitsEvent() {
        var world = BubbleWorld(configuration: .default)
        let bubble = world.addBubble(center: .zero, restArea: .pi * 16)

        XCTAssertTrue(world.resizeBubble(bubble, toRestArea: .pi * 64))

        XCTAssertEqual(world.bubble(bubble)!.restArea, .pi * 64)
        XCTAssertEqual(world.operationEvents, [.resized(bubble, restArea: .pi * 64)])
    }

    func testMergeConservesAreaAndProducesDeterministicEvent() {
        var world = BubbleWorld(configuration: .default)
        let first = world.addBubble(center: .zero, restArea: .pi * 9)
        let second = world.addBubble(center: Vector2(x: 10, y: 0), restArea: .pi * 16)

        let output = world.merge(second, first)!

        XCTAssertEqual(world.bubble(output)!.restArea, .pi * 25, accuracy: 0.0001)
        XCTAssertEqual(world.operationEvents.last, .merged(inputs: [first, second], output: output))
    }

    func testSplitConservesAreaAndProducesOrderedOutputs() {
        var world = BubbleWorld(configuration: .default)
        let input = world.addBubble(center: .zero, restArea: .pi * 32)

        let outputs = world.split(input)!

        XCTAssertEqual(outputs.count, 2)
        XCTAssertEqual(world.bubble(outputs[0])!.restArea + world.bubble(outputs[1])!.restArea, .pi * 32, accuracy: 0.0001)
        XCTAssertEqual(world.operationEvents.last, .split(input: input, outputs: outputs))
    }
}
