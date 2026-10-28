import Foundation
import XCTest

final class PublicWorldStressViewLayoutTests: XCTestCase {
    func testStartControlPrecedesResizableDrawable() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Benchmarks/iOS/BubblePhysicsBench/App/PublicWorldStressView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let start = try XCTUnwrap(source.range(of: "Button(\"Start\")"))
        let progress = try XCTUnwrap(source.range(of: "ProgressView(value:"))
        let drawable = try XCTUnwrap(source.range(of: "StressDrawableView(source: drawableSource)"))

        XCTAssertLessThan(start.lowerBound, drawable.lowerBound)
        XCTAssertLessThan(progress.lowerBound, drawable.lowerBound)
        XCTAssertFalse(source.contains(".frame(width: 375, height: 700)"))
    }
}
