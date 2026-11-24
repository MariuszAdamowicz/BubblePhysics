import Metal
import XCTest

/// Próba barier jądra jednej grupy (plan wycinka 3, zadanie 26). Jądro pętli podkroków (`nativeSubstepLoopSingleGroup`) rozdziela fazy
/// przez `threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup)` i czyta zapisy sąsiednich wątków z bufora urządzenia
/// oraz z pamięci grupy. Repozytorium tej bariery jeszcze nie używało, więc test sprawdza ją osobno, na sprzęcie: jedna grupa o największej
/// szerokości potoku, 1000 rund zapis, bariera, odczyt zapisu sąsiada, bariera. Niezaliczona próba wstrzymuje wycinek.
/// Próba biegnie tylko na GPU z testu (Mac); iPhone X (inna rodzina GPU) sprawdza się pomiarem w wycinku 4.
final class NativeMetalSingleGroupBarrierTests: XCTestCase {
    private static let rounds: UInt32 = 1000
    /// Tyle pamięci grupy ma jądro pętli według R2 (siatka, redukcja i skan korzystają z jednej tablicy współdzielonej).
    private static let requiredThreadgroupMemory = 32_768
    /// Tablica pamięci grupy: `width · 8` słów po 4 bajty, czyli przy 1024 wątkach dokładnie 32 768 bajtów.
    private static let stride = 8

    private func source(expectedRoundShift: String) -> String {
        """
        #include <metal_stdlib>
        using namespace metal;
        kernel void barrierProbe(device uint* cells [[buffer(0)]],
                                 device atomic_uint* failures [[buffer(1)]],
                                 constant uint& rounds [[buffer(2)]],
                                 threadgroup uint* local [[threadgroup(0)]],
                                 uint tid [[thread_position_in_threadgroup]],
                                 uint width [[threads_per_threadgroup]]) {
            const uint neighbour = (tid + 1) % width;
            uint bad = 0;
            for (uint round = 1; round <= rounds; ++round) {
                cells[tid] = round * 2654435761u + tid;
                local[tid * \(Self.stride)] = round ^ tid;
                threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup);
                const uint seen = round \(expectedRoundShift);
                if (cells[neighbour] != seen * 2654435761u + neighbour) { bad += 1; }
                if (local[neighbour * \(Self.stride)] != (seen ^ neighbour)) { bad += 1; }
                threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup);
            }
            if (bad != 0) { atomic_fetch_add_explicit(failures, bad, memory_order_relaxed); }
        }
        """
    }

    private struct Outcome {
        let width: Int
        let failures: UInt32
    }

    private func probe(device: MTLDevice, expectedRoundShift: String) throws -> Outcome {
        let library = try device.makeLibrary(source: source(expectedRoundShift: expectedRoundShift), options: nil)
        let pipeline = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "barrierProbe")))
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, 1024)
        XCTAssertGreaterThan(width, 1)
        let cells = try XCTUnwrap(device.makeBuffer(length: width * 4, options: .storageModeShared))
        let failures = try XCTUnwrap(device.makeBuffer(length: 4, options: .storageModeShared))
        failures.contents().storeBytes(of: UInt32(0), as: UInt32.self)
        var rounds = Self.rounds
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(cells, offset: 0, index: 0)
        encoder.setBuffer(failures, offset: 0, index: 1)
        encoder.setBytes(&rounds, length: 4, index: 2)
        encoder.setThreadgroupMemoryLength(width * Self.stride * 4, index: 0)
        encoder.dispatchThreadgroups(.init(width: 1, height: 1, depth: 1), threadsPerThreadgroup: .init(width: width, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
        return Outcome(width: width, failures: failures.contents().load(as: UInt32.self))
    }

    /// Z barierą każdy wątek widzi zapis sąsiada z tej samej rundy, w buforze urządzenia i w pamięci grupy, przez wszystkie 1000 rund.
    func testDeviceAndThreadgroupWritesOfTheNeighbourAreVisibleAfterTheBarrier() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "brak urządzenia Metal")
        XCTAssertGreaterThanOrEqual(device.maxThreadgroupMemoryLength, Self.requiredThreadgroupMemory,
                                    "jądro jednej grupy potrzebuje 32 KB pamięci grupy")
        let outcome = try probe(device: device, expectedRoundShift: "+ 0")
        XCTAssertEqual(outcome.failures, 0, "wątki widziały nieaktualny zapis sąsiada po barierze (szerokość grupy \(outcome.width))")
    }

    /// Kontrola próby: ta sama próba z błędnym oczekiwaniem (zapis z następnej rundy) musi liczyć niezgodności w każdej rundzie
    /// każdego wątku, inaczej odczyt nic nie sprawdzał.
    func testProbeCountsEveryMismatchWhenTheExpectationIsWrong() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "brak urządzenia Metal")
        let outcome = try probe(device: device, expectedRoundShift: "+ 1")
        XCTAssertEqual(Int(outcome.failures), outcome.width * Int(Self.rounds) * 2,
                       "oba odczyty każdego wątku w każdej rundzie mają się nie zgadzać")
    }
}
