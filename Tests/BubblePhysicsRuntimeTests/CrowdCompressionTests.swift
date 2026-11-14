import BubblePhysics
import simd
import XCTest

/// Tłok i narożnik przy kontakcie twardym (P-B-13, P-B-14): krok nie jest odrzucany, środki zostają w ramie ścian,
/// a bańki nie znikają. Scena z `CrowdSceneSupport.swift`; wszystko idzie przez publiczny `BubbleWorld` na urządzeniu Metal.
/// Miękki materiał dochodzi w wycinku 3.
@MainActor
final class CrowdCompressionTests: XCTestCase {
    // P-B-13
    func testHardCrowdBalance2_5KeepsStepsAcceptedAndCentersInTheFrame() async throws {
        let world = try await CrowdScene.makeWorld()
        let report = try await CrowdScene.runCrowd(world: world, balance: 2.5, seed: 2_500, extraSteps: 600)
        XCTAssertNil(report.firstIssue?.issue,
                     "krok \(report.firstIssue?.step ?? 0) odrzucony: \(String(describing: report.firstIssue?.rejection)), bańk: \(report.addedCount)")
        XCTAssertNil(report.failureReason)
        XCTAssertNil(world.diagnostics.failureReason)
        XCTAssertEqual(report.exitEvents, 0, "didExitSimulationRegion")
        XCTAssertEqual(report.vanishedBubbles, 0, "bańki, które zniknęły z klatki")
        XCTAssertTrue(report.outsideFrame.isEmpty, "środek poza ramą: \(report.outsideFrame.prefix(3))")
        XCTAssertGreaterThanOrEqual(report.balance, 2.5)
        XCTAssertTrue(report.wasContainedCountFinite)
        XCTAssertGreaterThanOrEqual(report.minimumContainedPairs, 0)
        XCTAssertGreaterThanOrEqual(report.steps, 600, "przebieg obejmuje 600 kroków po ostatniej bańce")
    }

    // P-B-14
    func testHardCornerPushedByTenBubblesKeepsStepsAcceptedAndCenterInTheFrame() async throws {
        let force = simd_normalize(WorldPoint(1, 1)) * 3_000
        let world = try await CrowdScene.makeWorld { setup in
            var setup = setup.add(try CrowdScene.bubble(1, at: [140, 280], radius: 20))
                .setMotorDrive(CrowdScene.id(1), drive: try MotorDrive(force: force))
            // Tłok za bańką: 10 baniek r = 20 na siatce, każda napiera na narożnik.
            for index in 0..<10 {
                let identifier = UInt64(2 + index)
                let position = WorldPoint(20 + Float(index % 4) * 45, 150 + Float(index / 4) * 45)
                setup = setup.add(try CrowdScene.bubble(identifier, at: position, radius: 20))
                    .setMotorDrive(CrowdScene.id(identifier), drive: try MotorDrive(force: force))
            }
            return setup
        }
        for index in 0..<300 {
            let frame = await world.advance(by: CrowdScene.step)
            let diagnostics = world.diagnostics
            XCTAssertNil(diagnostics.lastAdvanceIssue,
                         "krok \(index) odrzucony: \(String(describing: diagnostics.lastRejectionReason))")
            if diagnostics.lastAdvanceIssue != nil { return }
            for identifier in 1...11 {
                let state = try XCTUnwrap(frame.objects[CrowdScene.id(UInt64(identifier))],
                                          "bańka \(identifier) zniknęła w kroku \(index)")
                XCTAssertTrue(CrowdScene.isInsideFrame(state.position), "krok \(index), bańka \(identifier): \(state.position)")
            }
        }
    }
}
