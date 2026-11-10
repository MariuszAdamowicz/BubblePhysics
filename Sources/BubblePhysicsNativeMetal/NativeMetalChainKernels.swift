import Metal

/// Kodowanie sortowania siatki. Kolejność wpisów jest jednoznaczna (remis rozstrzyga indeks bańki),
/// więc wynik nie zależy od sieci porównań.
enum NativeMetalGridSort {
    /// Największa liczba wpisów sortowanych w pamięci jednej grupy (32 B na wpis).
    static let chunkLimit = 256

    /// Kroki bitoniczne o odległości mniejszej niż grupa idą w pamięci grupy (`nativeSortGridChunk`),
    /// większe w globalnym `nativeSortGrid`. Zwraca liczbę zakodowanych dispatchy.
    @discardableResult
    static func encode(_ encoder: MTLComputeCommandEncoder, pipelines: [String: MTLComputePipelineState],
                       grid: MTLBuffer, capacity: Int) -> Int {
        let chunkPipeline = pipelines["nativeSortGridChunk"]!
        let globalPipeline = pipelines["nativeSortGrid"]!
        var chunk = 1
        while chunk * 2 <= min(capacity, chunkLimit, chunkPipeline.maxTotalThreadsPerThreadgroup) { chunk *= 2 }
        var dispatches = 0
        func local(sizes: ClosedRange<Int>, distanceLimit: Int) {
            encoder.memoryBarrier(scope: .buffers)
            encoder.setComputePipelineState(chunkPipeline)
            encoder.setBuffer(grid, offset: 0, index: 0)
            var pass = SIMD4(UInt32(sizes.lowerBound), UInt32(sizes.upperBound), UInt32(distanceLimit), UInt32(chunk))
            encoder.setBytes(&pass, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 1)
            encoder.setThreadgroupMemoryLength(chunk * MemoryLayout<NativeMetalGridEntry>.stride, index: 0)
            encoder.dispatchThreadgroups(.init(width: capacity / chunk, height: 1, depth: 1),
                threadsPerThreadgroup: .init(width: chunk, height: 1, depth: 1))
            dispatches += 1
        }
        local(sizes: 2...max(2, chunk), distanceLimit: Int(UInt32.max))
        var size = chunk * 2
        while size <= capacity {
            var distance = size / 2
            while distance >= chunk {
                encoder.memoryBarrier(scope: .buffers)
                encoder.setComputePipelineState(globalPipeline)
                encoder.setBuffer(grid, offset: 0, index: 0)
                var pass = SIMD2(UInt32(size), UInt32(distance))
                encoder.setBytes(&pass, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)
                encoder.dispatchThreads(.init(width: capacity, height: 1, depth: 1),
                    threadsPerThreadgroup: .init(width: globalPipeline.threadExecutionWidth, height: 1, depth: 1))
                dispatches += 1
                distance /= 2
            }
            local(sizes: size...size, distanceLimit: chunk / 2)
            size *= 2
        }
        return dispatches
    }
}

/// Kodowanie trzynastu przejść wygładzania konturu (liczba nieparzysta: wynik ląduje w `output`).
enum NativeMetalContourSmoothing {
    static let passCount = 13

    /// `fused`: jedna grupa na bańkę zamiast trzynastu dispatchy, gdy stride mieści się w grupie.
    /// Wersja wielokrokowa zamienia `input` i `output` na przemian, więc `input` traci zawartość.
    /// Zwraca liczbę zakodowanych dispatchy.
    @discardableResult
    static func encode(_ encoder: MTLComputeCommandEncoder, pipelines: [String: MTLComputePipelineState],
                       input: MTLBuffer, output: MTLBuffer, counts: MTLBuffer, control: MTLBuffer,
                       contour: MTLBuffer, safety: MTLBuffer, bubbleCount: Int, stride: Int, fused: Bool) -> Int {
        let fusedPipeline = pipelines["nativeGenerateContoursFused"]!
        if fused, stride <= fusedPipeline.maxTotalThreadsPerThreadgroup, bubbleCount > 0 {
            encoder.memoryBarrier(scope: .buffers)
            encoder.setComputePipelineState(fusedPipeline)
            for (index, buffer) in [input, output, counts, control, contour, safety].enumerated() {
                encoder.setBuffer(buffer, offset: 0, index: index)
            }
            encoder.setThreadgroupMemoryLength(stride * MemoryLayout<Float>.stride, index: 0)
            encoder.dispatchThreadgroups(.init(width: bubbleCount, height: 1, depth: 1),
                threadsPerThreadgroup: .init(width: stride, height: 1, depth: 1))
            return 1
        }
        let pipeline = pipelines["nativeGenerateContours"]!
        var source = input, destination = output
        for _ in 0..<passCount {
            encoder.memoryBarrier(scope: .buffers)
            encoder.setComputePipelineState(pipeline)
            for (index, buffer) in [source, destination, counts, control, contour, safety].enumerated() {
                encoder.setBuffer(buffer, offset: 0, index: index)
            }
            if bubbleCount * stride > 0 {
                encoder.dispatchThreads(.init(width: bubbleCount * stride, height: 1, depth: 1),
                    threadsPerThreadgroup: .init(width: min(pipeline.threadExecutionWidth, pipeline.maxTotalThreadsPerThreadgroup),
                                                 height: 1, depth: 1))
            }
            swap(&source, &destination)
        }
        return passCount
    }
}
