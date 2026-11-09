import BubblePhysics
import BubblePhysicsAssets
import BubblePhysicsMetalRender
import CoreGraphics
import Metal
import XCTest

/// P-B-61 na Macu: skład sceny akceptacyjnej, rozmiar celu renderu, pola raportu i bramka sceny.
/// Pomiar na iPhonie X należy do właściciela; te testy pilnują, że to, co mierzy, jest tą sceną.
@MainActor
final class AcceptanceSceneTests: XCTestCase {
    private typealias Scene = PublicWorldStressBenchmark.Scene

    private func acceptanceOperations() throws -> [WorldOperation] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let scene = Scene.acceptance
        let world = try BubbleWorld.makeBenchmarkWorld(configuration: scene.configuration(), device: device, solverIterationLimit: 4)
        return try scene.initialTransaction(assets: XCTUnwrap(world.assets)).operations
    }

    func testSceneHasThreeHundredTexturedBubblesWithTextDecalsOnTwoLayersOfAlphaMaterials() throws {
        let operations = try acceptanceOperations()
        var materials: [RenderMaterialID: RenderMaterial] = [:]
        var bubbles: [BubbleDescriptor] = []
        for operation in operations {
            switch operation {
            case .updateRenderMaterial(let id, let material): materials[id] = material
            case .add(.bubble(let bubble)): bubbles.append(bubble)
            default: break
            }
        }
        XCTAssertEqual(bubbles.count, 300)
        for bubble in bubbles {
            guard case .text? = bubble.decal?.content else { XCTFail("bańka \(bubble.id) bez naklejki tekstowej"); continue }
            let material = try XCTUnwrap(materials[bubble.renderMaterialID], "materiał bańki \(bubble.id)")
            XCTAssertNotNil(material.texture, "bańka \(bubble.id) ma teksturę")
            XCTAssertEqual(material.bubbleMapping, .attached)
            XCTAssertEqual(material.blend, .alpha, "bańka \(bubble.id) na warstwie \(bubble.layer) ma materiał alfa")
        }
        XCTAssertEqual(Set(bubbles.map(\.layer)), [0, 1])
        XCTAssertEqual(bubbles.filter { $0.layer == 1 }.count, 150)
        XCTAssertEqual(bubbles.filter { $0.layer == 0 }.count, 150)
    }

    func testSceneHasFourWallsAndAKinematicTriangleWithADrive() throws {
        let operations = try acceptanceOperations()
        var statics: [RigidBodyDescriptor] = []
        var kinematic: [RigidBodyDescriptor] = []
        var drives: [ObjectID: KinematicDrive] = [:]
        for operation in operations {
            switch operation {
            case .add(.rigidBody(let body)):
                if body.motionRole == .kinematic { kinematic.append(body) } else { statics.append(body) }
            case .setKinematicDrive(let id, let drive): drives[id] = drive
            default: break
            }
        }
        XCTAssertEqual(statics.count, 4)
        XCTAssertTrue(statics.allSatisfy { $0.motionRole == .static })
        XCTAssertEqual(kinematic.count, 1)
        let triangle = try XCTUnwrap(kinematic.first)
        guard case .polygon(let geometry) = triangle.shape else { return XCTFail("trójkąt jest wielokątem") }
        XCTAssertEqual(geometry.vertices.count, 3)
        XCTAssertNotNil(drives[triangle.id], "trójkąt kinematyczny ma KinematicDrive")
    }

    /// Rozmiar celu renderu czytany z tekstury, którą benchmark faktycznie utworzył, a nie z pól raportu.
    private func renderTargetSize(device: MTLDevice, size: CGSize?) async throws -> (width: Int, height: Int) {
        var observed: [(Int, Int)] = []
        let report = try await PublicWorldStressBenchmark.run(device: device, scene: .acceptance, renderSize: size,
            renderTargetObserver: { observed.append(($0.width, $0.height)) },
            warmupFrames: 0, measuredFrames: 2, progress: { _, _ in })
        XCTAssertEqual(report.failedFrames, 0)
        XCTAssertEqual(observed.count, 1, "jeden cel renderu na przebieg")
        let texture = try XCTUnwrap(observed.first)
        XCTAssertEqual(report.renderWidth, texture.0, "raport zgadza się z celem")
        XCTAssertEqual(report.renderHeight, texture.1, "raport zgadza się z celem")
        XCTAssertTrue(report.text.contains("render_px=\(texture.0)x\(texture.1)"))
        return texture
    }

    func testRenderTargetSizeFollowsTheRequestAndDefaultsToTheRegionAtWidth375() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let native = try await renderTargetSize(device: device, size: CGSize(width: 1125, height: 2436))
        XCTAssertEqual(native.width, 1125)
        XCTAssertEqual(native.height, 2436)
        let standard = try await renderTargetSize(device: device, size: nil)
        XCTAssertEqual(standard.width, 375)
        XCTAssertEqual(standard.height, 700, "region sceny akceptacyjnej ma 700 jednostek wysokości")
    }

    func testInvalidRenderSizeThrowsADedicatedErrorInsteadOfTrapping() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let invalid: [CGSize] = [
            CGSize(width: 0, height: 100), CGSize(width: 100, height: 0), CGSize(width: -375, height: 700),
            CGSize(width: CGFloat.nan, height: 700), CGSize(width: 375, height: CGFloat.nan),
            CGSize(width: CGFloat.infinity, height: 700), CGSize(width: 375, height: -CGFloat.infinity),
            CGSize(width: 1e30, height: 700), CGSize(width: 0.5, height: 700)
        ]
        for size in invalid {
            do {
                _ = try await PublicWorldStressBenchmark.run(device: device, scene: .acceptance, renderSize: size,
                    warmupFrames: 0, measuredFrames: 1, progress: { _, _ in })
                XCTFail("rozmiar \(size) powinien zostać odrzucony")
            } catch let error as StressBenchmarkError {
                guard case .invalidRenderSize = error else { XCTFail("rozmiar \(size): \(error)"); continue }
            }
        }
    }

    func testFiveFramesKeepCandidateMarginAndReadNoContours() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let report = try await PublicWorldStressBenchmark.run(device: device, scene: .acceptance,
            warmupFrames: 0, measuredFrames: 5, progress: { _, _ in })
        XCTAssertEqual(report.scene, "acceptance")
        XCTAssertEqual(report.measuredFrames, 5)
        XCTAssertEqual(report.failedFrames, 0)
        XCTAssertEqual(report.nonFiniteFrames, 0)
        XCTAssertEqual(report.contourCPUReadbacks, 0)
        XCTAssertEqual(report.contactCandidateOverflow, 0)
        XCTAssertEqual(report.candidateLimit, BubbleWorld.contactCandidateLimit)
        XCTAssertGreaterThan(report.maximumCandidatesPerObject, 0, "scena ma kontakty, więc licznik coś zmierzył")
        XCTAssertLessThanOrEqual(report.maximumCandidatesPerObject * 2, report.candidateLimit)
        XCTAssertTrue(report.text.contains("scene=acceptance"))
        XCTAssertTrue(report.text.contains("contact_candidate_overflow=0; max_candidates_per_object=\(report.maximumCandidatesPerObject); candidate_limit=128"))
    }

    func testAcceptanceGateIs16Point67AndOtherScenesKeepTheirGate() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let acceptance = try await PublicWorldStressBenchmark.run(device: device, scene: .acceptance,
            warmupFrames: 0, measuredFrames: 2, progress: { _, _ in })
        XCTAssertEqual(acceptance.gateMilliseconds, 16.67, accuracy: 1e-9)
        XCTAssertTrue(acceptance.text.contains("p95_gate_ms=16.6700"))
        XCTAssertEqual(acceptance.passesP95Gate, acceptance.p95Milliseconds <= 16.67)
        let stress = try await PublicWorldStressBenchmark.run(device: device, scene: .stress300,
            warmupFrames: 0, measuredFrames: 2, progress: { _, _ in })
        XCTAssertEqual(stress.gateMilliseconds, PublicWorldStressBenchmark.p95GateMilliseconds, accuracy: 1e-9)
        XCTAssertTrue(stress.text.contains("p95_gate_ms=10.4568"))
    }
}
