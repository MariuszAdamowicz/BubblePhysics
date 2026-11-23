import BubblePhysics
@testable import BubblePhysicsRuntime
import XCTest

/// Próg stabilności gumki (P-B-15, stager; CD-D-20, G4-AC4): K_band ≤ m / (16 · dt²), czyli ω_band · dt ≤ 0,25, co przy dt = 1/60
/// daje ok. 225 · m. Większą sztywność stager odrzuca `valueOutOfRange("drive.bandStiffness")`. Granicę liczy się z `fixedTimeStep`
/// typu Float, więc sama wartość 225 · m leży na zaokrągleniu i testy omijają ją o kilka jednostek. Bez GPU.
final class BandStabilityThresholdTests: XCTestCase {
    private let materialID = PhysicsMaterialID(rawValue: 1)
    private let styleID = RenderMaterialID(rawValue: 1)
    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }
    private let rejection = TransactionRejectionReason.invalidValue(.valueOutOfRange("drive.bandStiffness"))

    private func state(fixedTimeStep: Double = 1.0 / 60) throws -> RuntimeState {
        RuntimeState(configuration: try WorldConfiguration(simulationRegion: WorldRectangle(min: [-1000, -1000], max: [1000, 1000]),
                                                           fixedTimeStep: fixedTimeStep))
    }
    private func resources() throws -> WorldTransaction {
        WorldTransaction()
            .updatePhysicsMaterial(materialID, material: try PhysicsMaterial(kind: .bubble, contactStiffness: 1e9))
            .updateRenderMaterial(styleID, material: try RenderMaterial())
    }
    private func bubble(_ value: UInt64, mass: Float, stiffness: Float) throws -> WorldObject {
        .bubble(try BubbleDescriptor(id: id(value), position: [Float(value) * 10, 0], targetRadius: 2, mass: mass,
                                     physicsMaterialID: materialID, renderMaterialID: styleID,
                                     drivePolicy: BubbleDrivePolicy(bandStiffness: stiffness)))
    }
    private func assertThreshold(mass: Float, accepted: [Float], rejected: [Float], fixedTimeStep: Double = 1.0 / 60,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let initial = try TransactionStager.stage(resources(), against: state(fixedTimeStep: fixedTimeStep)).state
        for stiffness in accepted {
            XCTAssertNoThrow(try TransactionStager.stage(WorldTransaction().add(bubble(1, mass: mass, stiffness: stiffness)),
                                                         against: initial), "m = \(mass), K = \(stiffness)", file: file, line: line)
        }
        for stiffness in rejected {
            XCTAssertThrowsError(try TransactionStager.stage(WorldTransaction().add(bubble(1, mass: mass, stiffness: stiffness)),
                                                             against: initial), "m = \(mass), K = \(stiffness)", file: file, line: line) {
                XCTAssertEqual($0 as? TransactionRejection, TransactionRejection(operationIndex: 0, reason: self.rejection),
                               file: file, line: line)
            }
        }
    }

    /// G4-AC4: przy m = 1 stager przyjmuje 22 (gumka gry) i 224, a odrzuca 226.
    func testUnitMassAcceptsTwentyTwoAndTwoHundredTwentyFourAndRejectsTwoHundredTwentySix() throws {
        try assertThreshold(mass: 1, accepted: [22, 224], rejected: [226, 1000, 10_000])
    }

    /// Próg rośnie proporcjonalnie do masy: „2” (m 1) i bańka 7168 (m 38) z tą samą regułą, lekka bańka z niższym progiem.
    func testThresholdScalesWithTheMass() throws {
        try assertThreshold(mass: 38, accepted: [22, 8000, 8540], rejected: [8560, 20_000])
        try assertThreshold(mass: 0.36, accepted: [22, 80], rejected: [82, 1000])
    }

    /// Dawny próg K · dt² / m < 1 (K < 3600 · m) przyjmował 1000 przy m = 2; nowy odrzuca (granica 450).
    func testFormerStabilityBoundIsNowRejected() throws {
        try assertThreshold(mass: 2, accepted: [400, 440], rejected: [460, 1000, 3000])
    }

    /// Próg liczy się z kroku świata: dwa razy dłuższy krok to cztery razy niższa granica (K ≤ m / (16 · dt²)).
    func testThresholdFollowsTheFixedTimeStep() throws {
        try assertThreshold(mass: 1, accepted: [50, 54], rejected: [58, 100], fixedTimeStep: 1.0 / 30)
        try assertThreshold(mass: 1, accepted: [800, 880], rejected: [940, 2000], fixedTimeStep: 1.0 / 120)
    }

    func testReplaceIsCheckedWithTheSameThreshold() throws {
        let initial = try TransactionStager.stage(resources().add(bubble(1, mass: 1, stiffness: 22)), against: state()).state
        XCTAssertThrowsError(try TransactionStager.stage(WorldTransaction().replace(id(1), with: bubble(1, mass: 1, stiffness: 226)),
                                                         against: initial)) {
            XCTAssertEqual($0 as? TransactionRejection, TransactionRejection(operationIndex: 0, reason: self.rejection))
        }
        XCTAssertNoThrow(try TransactionStager.stage(WorldTransaction().replace(id(1), with: bubble(1, mass: 1, stiffness: 224)),
                                                     against: initial))
    }

    func testBubbleWithoutBandIsNeverChecked() throws {
        let light = try BubbleDescriptor(id: id(1), position: .zero, targetRadius: 2, mass: 0.001,
                                         physicsMaterialID: materialID, renderMaterialID: styleID)
        let initial = try TransactionStager.stage(resources(), against: state()).state
        XCTAssertNoThrow(try TransactionStager.stage(WorldTransaction().add(.bubble(light)), against: initial))
    }
}
