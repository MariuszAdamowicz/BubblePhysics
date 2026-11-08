import XCTest
import Metal
@testable import BubblePhysicsNativeMetal

/// Porównuje układ rekordów Swift z układem, jaki kompilator Metal tworzy dla struktur shaderów.
/// Kernel-sonda jest kompilowany razem z produkcyjnymi źródłami shaderów, więc pole dodane tylko
/// po jednej stronie kończy się błędem tutaj, a nie uszkodzeniem buforów GPU w czasie działania.
@MainActor
final class NativeMetalShaderABITests: XCTestCase {
    private struct Probe {
        let name: String
        let mslSize: String
        let swiftSize: Int
        let fields: [(msl: String, swift: Int?)]
    }

    private func source(_ name: String) throws -> String { try NativeMetalShaderSource.load(name) }

    private func measure(_ probes: [Probe], sources: [String], device: MTLDevice) throws -> [UInt32] {
        var body = "kernel void abiProbe(device uint *out [[buffer(0)]]) {\n"
        var slot = 0
        for probe in probes {
            body += "    out[\(slot)] = sizeof(\(probe.mslSize));\n"; slot += 1
            for field in probe.fields {
                body += "    out[\(slot)] = __builtin_offsetof(\(probe.mslSize), \(field.msl));\n"; slot += 1
            }
        }
        body += "}\n"
        let library = try device.makeLibrary(source: sources.joined(separator: "\n") + "\n" + body, options: nil)
        let pipeline = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "abiProbe")))
        let output = try XCTUnwrap(device.makeBuffer(length: max(1, slot) * 4, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.dispatchThreads(.init(width: 1, height: 1, depth: 1), threadsPerThreadgroup: .init(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        let values = output.contents().bindMemory(to: UInt32.self, capacity: slot)
        return (0..<slot).map { values[$0] }
    }

    private func assertMatches(_ probes: [Probe], _ measured: [UInt32], file: StaticString = #filePath, line: UInt = #line) {
        var slot = 0
        for probe in probes {
            XCTAssertEqual(Int(measured[slot]), probe.swiftSize, "sizeof(\(probe.mslSize))", file: file, line: line)
            slot += 1
            for field in probe.fields {
                if let expected = field.swift {
                    XCTAssertEqual(Int(measured[slot]), expected, "\(probe.mslSize).\(field.msl)", file: file, line: line)
                }
                slot += 1
            }
        }
    }

    func testSolverShaderStructsMatchSwiftLayouts() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let sources = try NativeMetalShaderSource.solverFiles.map(source)
        let probes: [Probe] = [
            Probe(name: "bubble", mslSize: "NativeBubble", swiftSize: MemoryLayout<NativeMetalBubble>.stride, fields: [
                ("identity", MemoryLayout<NativeMetalBubble>.offset(of: \.identity)),
                ("position", MemoryLayout<NativeMetalBubble>.offset(of: \.position)),
                ("motion", MemoryLayout<NativeMetalBubble>.offset(of: \.motion)),
                ("physical", MemoryLayout<NativeMetalBubble>.offset(of: \.physical)),
                ("deformation", MemoryLayout<NativeMetalBubble>.offset(of: \.deformation)),
                ("publicFlags", MemoryLayout<NativeMetalBubble>.offset(of: \.publicFlags)),
                ("material", MemoryLayout<NativeMetalBubble>.offset(of: \.material)),
                ("resources", MemoryLayout<NativeMetalBubble>.offset(of: \.resources)),
                ("eventData", MemoryLayout<NativeMetalBubble>.offset(of: \.eventData)),
                ("bounds", MemoryLayout<NativeMetalBubble>.offset(of: \.bounds))]),
            Probe(name: "segment", mslSize: "NativeSegment", swiftSize: MemoryLayout<NativeMetalSegment>.stride, fields: [
                ("identity", MemoryLayout<NativeMetalSegment>.offset(of: \.identity)),
                ("flags", MemoryLayout<NativeMetalSegment>.offset(of: \.flags)),
                ("previous", MemoryLayout<NativeMetalSegment>.offset(of: \.previous)),
                ("current", MemoryLayout<NativeMetalSegment>.offset(of: \.current)),
                ("velocity", MemoryLayout<NativeMetalSegment>.offset(of: \.velocity)),
                ("collision", MemoryLayout<NativeMetalSegment>.offset(of: \.collision))]),
            Probe(name: "cache", mslSize: "NativeContactCache", swiftSize: MemoryLayout<NativeContactCacheRecord>.stride, fields: [
                ("participants", MemoryLayout<NativeContactCacheRecord>.offset(of: \.participants)),
                ("metadata", MemoryLayout<NativeContactCacheRecord>.offset(of: \.metadata)),
                ("geometry", MemoryLayout<NativeContactCacheRecord>.offset(of: \.geometry)),
                ("response", MemoryLayout<NativeContactCacheRecord>.offset(of: \.response))]),
            Probe(name: "candidate", mslSize: "NativeCandidate", swiftSize: MemoryLayout<NativeMetalCandidate>.stride, fields: [
                ("metadata", MemoryLayout<NativeMetalCandidate>.offset(of: \.metadata))]),
            Probe(name: "grid", mslSize: "NativeGridEntry", swiftSize: MemoryLayout<NativeMetalGridEntry>.stride, fields: [
                ("metadata", MemoryLayout<NativeMetalGridEntry>.offset(of: \.metadata))]),
            Probe(name: "contactControl", mslSize: "NativeContactControl", swiftSize: MemoryLayout<NativeMetalContactControl>.stride, fields: [
                ("counts", MemoryLayout<NativeMetalContactControl>.offset(of: \.counts)),
                ("cache", MemoryLayout<NativeMetalContactControl>.offset(of: \.cache)),
                ("thresholds", MemoryLayout<NativeMetalContactControl>.offset(of: \.thresholds)),
                ("cellWidth", MemoryLayout<NativeMetalContactControl>.offset(of: \.cellWidth))]),
            Probe(name: "control", mslSize: "NativeControl", swiftSize: MemoryLayout<NativeMetalControl>.stride, fields: [
                ("physics", MemoryLayout<NativeMetalControl>.offset(of: \.physics)),
                ("contactDamping", MemoryLayout<NativeMetalControl>.offset(of: \.contactDamping)),
                ("region", MemoryLayout<NativeMetalControl>.offset(of: \.region))]),
            Probe(name: "renderPacket", mslSize: "NativeRenderPacket", swiftSize: MemoryLayout<NativeMetalRenderPacket>.stride, fields: [
                ("geometry", MemoryLayout<NativeMetalRenderPacket>.offset(of: \.geometry)),
                ("deformation", MemoryLayout<NativeMetalRenderPacket>.offset(of: \.deformation))]),
            Probe(name: "rigidBody", mslSize: "NativeRigidBody", swiftSize: MemoryLayout<NativeRigidBody>.stride, fields: [
                ("pose", MemoryLayout<NativeRigidBody>.offset(of: \.pose)),
                ("previous", MemoryLayout<NativeRigidBody>.offset(of: \.previous)),
                ("motion", MemoryLayout<NativeRigidBody>.offset(of: \.motion)),
                ("physical", MemoryLayout<NativeRigidBody>.offset(of: \.physical)),
                ("ranges", MemoryLayout<NativeRigidBody>.offset(of: \.ranges)),
                ("flags", MemoryLayout<NativeRigidBody>.offset(of: \.flags))]),
            Probe(name: "structuralHeader", mslSize: "NativeStructuralHeader", swiftSize: MemoryLayout<NativeStructuralHeader>.stride, fields: [
                ("origin", MemoryLayout<NativeStructuralHeader>.offset(of: \.origin))]),
            Probe(name: "structuralSource", mslSize: "NativeStructuralSource", swiftSize: MemoryLayout<NativeStructuralSourceRecord>.stride, fields: [
                ("geometry", MemoryLayout<NativeStructuralSourceRecord>.offset(of: \.geometry)),
                ("clips", MemoryLayout<NativeStructuralSourceRecord>.offset(of: \.clips))]),
            Probe(name: "solverControl", mslSize: "NativeSolverControl", swiftSize: MemoryLayout<NativeMetalSolverControl>.stride, fields: [
                ("physics", MemoryLayout<NativeMetalSolverControl>.offset(of: \.physics))]),
            Probe(name: "contourControl", mslSize: "NativeContourControl", swiftSize: MemoryLayout<NativeMetalContourControl>.stride, fields: [
                ("shape", MemoryLayout<NativeMetalContourControl>.offset(of: \.shape))]),
            Probe(name: "event", mslSize: "NativeEventRecord", swiftSize: MemoryLayout<NativeMetalEventRecord>.stride, fields: [
                ("point", MemoryLayout<NativeMetalEventRecord>.offset(of: \.point)),
                ("metadata", MemoryLayout<NativeMetalEventRecord>.offset(of: \.metadata))]),
            Probe(name: "sensor", mslSize: "NativeSensorRecord", swiftSize: MemoryLayout<NativeMetalSensorRecord>.stride, fields: [
                ("geometry", MemoryLayout<NativeMetalSensorRecord>.offset(of: \.geometry)),
                ("range", MemoryLayout<NativeMetalSensorRecord>.offset(of: \.range))]),
            Probe(name: "sensorPair", mslSize: "NativeSensorPair", swiftSize: MemoryLayout<NativeMetalSensorPair>.stride, fields: [
                ("state", MemoryLayout<NativeMetalSensorPair>.offset(of: \.state))])
        ]
        assertMatches(probes, try measure(probes, sources: sources, device: device))
    }

    func testRenderBubbleMatchesSolverBubbleLayout() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let probes = [Probe(name: "render", mslSize: "RenderBubble", swiftSize: NativeMetalRenderHandoff.bubbleRecordByteCount, fields: [
            ("position", MemoryLayout<NativeMetalBubble>.offset(of: \.position)),
            ("physical", MemoryLayout<NativeMetalBubble>.offset(of: \.physical)),
            ("deformation", MemoryLayout<NativeMetalBubble>.offset(of: \.deformation)),
            ("material", MemoryLayout<NativeMetalBubble>.offset(of: \.material)),
            ("eventData", MemoryLayout<NativeMetalBubble>.offset(of: \.eventData)),
            ("bounds", MemoryLayout<NativeMetalBubble>.offset(of: \.bounds))])]
        assertMatches(probes, try measure(probes, sources: [try source("NativeRenderKernels")], device: device))
    }
}
