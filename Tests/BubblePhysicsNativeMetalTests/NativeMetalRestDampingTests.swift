import XCTest
import Metal
import BubblePhysicsReference
@testable import BubblePhysicsNativeMetal

@MainActor
final class NativeMetalRestDampingTests: XCTestCase {
    private struct ContactTrace {
        let actualBackend: ReferenceSimulationBackend
        let counts: [Int]
        let identifiers: [[UInt64]]
        let maximumSpeed: [ReferenceBubbleID: Float]
        let bubbleContacts: [ReferenceBubbleID: [[UInt64]]]

        var summary: String {
            let uniqueCounts = Array(Set(counts)).sorted()
            let bubbleSummary = maximumSpeed.keys.sorted().map { id in
                let trace = bubbleContacts[id] ?? []
                let changes = zip(trace, trace.dropFirst()).filter { $0 != $1 }.count
                return "id=\(id.rawValue):speed=\(maximumSpeed[id] ?? 0):switches=\(changes)"
            }.joined(separator: ",")
            let switches = zip(identifiers, identifiers.dropFirst()).filter { $0 != $1 }.count
            return "contact_counts=\(uniqueCounts) contact_switches=\(switches) bubbles=[\(bubbleSummary)]"
        }
    }

    func testNativeContactDampingLimitsShortReleaseFlapping() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let cpu = try await measure(backend: .cpu, targetX: 240, settleFrames: 30)
        let gpu = try await measure(backend: .nativeMetal, targetX: 240, settleFrames: 30)
        let cpuSwitches = zip(cpu.identifiers, cpu.identifiers.dropFirst()).filter { $0 != $1 }.count
        let gpuSwitches = zip(gpu.identifiers, gpu.identifiers.dropFirst()).filter { $0 != $1 }.count
        print("short_release_contact_switches cpu=\(cpuSwitches) gpu=\(gpuSwitches)")
        XCTAssertEqual(gpu.actualBackend, .nativeMetal)
        XCTAssertLessThanOrEqual(gpuSwitches, 15,
                                 "GPU graph flaps: cpu=\(cpuSwitches), gpu=\(gpuSwitches)")
    }

    // Sonda na tej samej scenie i granicach ruchu co aplikacja. Celowo nie
    // narzuca jeszcze warunku jakości: wskazuje, przy którym zatrzymanym
    // położeniu trójkąta zestaw kontaktów przełącza się między klatkami.
    func testProbeReportsContactOscillationAfterPolygonStops() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        // Tylko położenia z flappingiem z krótkiej próby. Najpierw dajemy
        // układowi dziesięć sekund po zatrzymaniu trójkąta: nie mierzymy tu
        // zwykłego, przejściowego zderzania po przeciągnięciu przeszkody.
        for targetX: Float in [240, 285, 330] {
            let cpu = try await measure(backend: .cpu, targetX: targetX)
            let gpu = try await measure(backend: .nativeMetal, targetX: targetX)
            print("static_polygon_probe target_x=\(targetX) cpu {\(cpu.summary)} gpu {\(gpu.summary)}")
            XCTAssertEqual(cpu.actualBackend, .cpu)
            XCTAssertEqual(gpu.actualBackend, .nativeMetal)
        }
    }

    private func measure(
        backend: ReferenceSimulationBackend,
        targetX: Float,
        settleFrames: Int = 600
    ) async throws -> ContactTrace {
        let driver = try VisualSimulationDriver(backend: backend, density: .six)
        driver.movePolygon(to: .init(x: targetX, y: ReferenceVisualSceneFactory.initialPolygonCenter.y))
        _ = await driver.advance(to: 0)
        for frame in 1...settleFrames { _ = await driver.advance(to: Double(frame) / 60) }
        var counts: [Int] = []
        var identifiers: [[UInt64]] = []
        var maximumSpeed: [ReferenceBubbleID: Float] = [:]
        var bubbleContacts: [ReferenceBubbleID: [[UInt64]]] = [:]
        for frame in (settleFrames + 1)...(settleFrames + 120) {
            let result = await driver.advance(to: Double(frame) / 60)
            counts.append(result.snapshot.contacts.count)
            identifiers.append(result.snapshot.contacts.map { $0.id.rawValue })
            for bubble in result.snapshot.bubbles {
                maximumSpeed[bubble.id] = max(maximumSpeed[bubble.id] ?? 0, bubble.velocity.length)
                let contacts = result.snapshot.contacts.compactMap { contact -> UInt64? in
                    contact.bubbleA == bubble.id || contact.bubbleB == bubble.id ? contact.id.rawValue : nil
                }
                bubbleContacts[bubble.id, default: []].append(contacts)
            }
        }
        return .init(actualBackend: driver.frame.actualBackend, counts: counts, identifiers: identifiers,
                     maximumSpeed: maximumSpeed, bubbleContacts: bubbleContacts)
    }
}
