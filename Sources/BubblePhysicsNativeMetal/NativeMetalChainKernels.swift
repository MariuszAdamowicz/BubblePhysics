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
    /// `fused: false` to dawna ścieżka trzynastu dispatchów, zachowana wyłącznie jako wzorzec bit w bit dla
    /// `NativeMetalChainKernelTests`; produkcja zawsze przekazuje `fused: true`.
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

/// Kodowanie kandydatów kontaktu brył. Jedna grupa na bryłę przegląda bańki w porcjach, a wiersz zapełnia w tej samej
/// kolejności co pojedynczy wątek, więc wynik nie zależy od szerokości grupy (szerokość 1 to dawny przebieg szeregowy).
enum NativeMetalRigidCandidates {
    static let defaultGroupWidth = 256

    @discardableResult
    static func encode(_ encoder: MTLComputeCommandEncoder, pipelines: [String: MTLComputePipelineState],
                       bodies: MTLBuffer, bubbles: MTLBuffer, positions: MTLBuffer, control: MTLBuffer,
                       rows: MTLBuffer, rowCounts: MTLBuffer, overflow: MTLBuffer,
                       jointRanges: MTLBuffer, jointPartners: MTLBuffer, bodyCount: Int,
                       groupWidth: Int = defaultGroupWidth) -> Int {
        guard bodyCount > 0 else { return 0 }
        let pipeline = pipelines["nativeRigidEmitCandidates"]!
        let width = max(1, min(groupWidth, pipeline.maxTotalThreadsPerThreadgroup))
        encoder.memoryBarrier(scope: .buffers)
        encoder.setComputePipelineState(pipeline)
        for (index, buffer) in [bodies, bubbles, positions, control, rows, rowCounts, overflow,
                                jointRanges, jointPartners].enumerated() {
            encoder.setBuffer(buffer, offset: 0, index: index)
        }
        // Pamięć grupy ma długość będącą wielokrotnością 16 bajtów (wymóg Metala); jądro używa `width` bajtów.
        encoder.setThreadgroupMemoryLength((width + 15) / 16 * 16, index: 0)
        encoder.dispatchThreadgroups(.init(width: bodyCount, height: 1, depth: 1),
                                     threadsPerThreadgroup: .init(width: width, height: 1, depth: 1))
        return 1
    }
}

/// Kodowanie przygotowania danych renderu (punkty konturu, ramka, pakiet bańki). `grouped`: jedna grupa na bańkę,
/// gdy stride mieści się w grupie i w pamięci grupy; inaczej, i dla `grouped: false`, dawny wątek na bańkę.
/// `grouped: false` istnieje wyłącznie jako wzorzec bit w bit dla `NativeMetalChainKernelTests`; produkcja zawsze
/// przekazuje `grouped: true` (wątek na bańkę zostaje tylko jako zapas dla zbyt szerokiego stride).
enum NativeMetalRenderPreparation {
    /// Bajty pamięci grupy na próbkę: poziom, punkt, ramka i skrajne wartości.
    static let bytesPerSample = MemoryLayout<Float>.stride + MemoryLayout<SIMD2<Float>>.stride
        + MemoryLayout<SIMD4<Float>>.stride + MemoryLayout<SIMD2<Float>>.stride

    /// Zwraca liczbę zakodowanych dispatchy.
    @discardableResult
    static func encode(_ encoder: MTLComputeCommandEncoder, pipelines: [String: MTLComputePipelineState],
                       bubbles: MTLBuffer, deformation: MTLBuffer, counts: MTLBuffer, points: MTLBuffer,
                       packets: MTLBuffer, control: MTLBuffer, contour: MTLBuffer, safety: MTLBuffer,
                       bubbleCount: Int, stride: Int, grouped: Bool) -> Int {
        guard bubbleCount > 0 else { return 0 }
        let groupedPipeline = pipelines["nativePrepareRenderDataGrouped"]!
        let useGroups = grouped && stride <= groupedPipeline.maxTotalThreadsPerThreadgroup
            && stride * bytesPerSample <= groupedPipeline.device.maxThreadgroupMemoryLength
        let pipeline = useGroups ? groupedPipeline : pipelines["nativePrepareRenderData"]!
        encoder.memoryBarrier(scope: .buffers)
        encoder.setComputePipelineState(pipeline)
        for (index, buffer) in [bubbles, deformation, counts, points, packets, control, contour, safety].enumerated() {
            encoder.setBuffer(buffer, offset: 0, index: index)
        }
        guard useGroups else {
            encoder.dispatchThreads(.init(width: bubbleCount, height: 1, depth: 1),
                threadsPerThreadgroup: .init(width: min(pipeline.threadExecutionWidth, pipeline.maxTotalThreadsPerThreadgroup),
                                             height: 1, depth: 1))
            return 1
        }
        for (index, size) in [MemoryLayout<Float>.stride, MemoryLayout<SIMD2<Float>>.stride,
                              MemoryLayout<SIMD4<Float>>.stride, MemoryLayout<SIMD2<Float>>.stride].enumerated() {
            encoder.setThreadgroupMemoryLength(stride * size, index: index)
        }
        encoder.dispatchThreadgroups(.init(width: bubbleCount, height: 1, depth: 1),
                                     threadsPerThreadgroup: .init(width: stride, height: 1, depth: 1))
        return 1
    }
}

/// Skan prefiksowy wartości `uint4` (liczniki kandydatów, kontaktów i cache'u). Dawny skan blokowy to osobny dispatch na
/// poziom, dispatchy dodające sumy bloków i dispatch kończący; skan jednej grupy robi to w jednym dispatchu, w porcjach
/// szerokości grupy z przeniesioną sumą. Sumy całkowite nie zależą od kolejności, więc wynik jest ten sam bit w bit.
/// `blockSums` i `blockOffsets` służą wyłącznie dawnemu skanowi blokowemu (wzorzec bit w bit dla
/// `NativeMetalChainKernelTests`); produkcja przekazuje `singleGroup: true` i ich nie czyta. Bufory są małe
/// (pojemność skanu / 256 wpisów na poziom), a liczba poziomów wyznacza rozmiar `indirectArguments`, więc zostają
/// przydzielone razem z resztą stanu.
struct NativeMetalScanBuffers {
    let values: MTLBuffer
    let offsets: MTLBuffer
    let blockSums: [MTLBuffer]
    let blockOffsets: [MTLBuffer]
    let control: MTLBuffer
    let contacts: MTLBuffer
    let indirectArguments: MTLBuffer
    let overflow: MTLBuffer
}

enum NativeMetalScan {
    static let singleGroupWidth = 512

    /// `mode` 0 skanuje liczniki kandydatów po bańkach (`maximum` to ich liczba), 1 aktywne kontakty, 2 scalony cache.
    /// `singleGroup: false` to dawny skan blokowy, zachowany wyłącznie jako wzorzec bit w bit dla
    /// `NativeMetalChainKernelTests`; produkcja zawsze przekazuje `singleGroup: true`.
    /// Zwraca liczbę zakodowanych dispatchy.
    @discardableResult
    static func encode(_ encoder: MTLComputeCommandEncoder, pipelines: [String: MTLComputePipelineState],
                       buffers: NativeMetalScanBuffers, mode: UInt32, maximum: Int, singleGroup: Bool) -> Int {
        if singleGroup {
            let pipeline = pipelines["nativeScanSingleGroup"]!
            let width = min(singleGroupWidth, pipeline.maxTotalThreadsPerThreadgroup)
            encoder.memoryBarrier(scope: .buffers)
            encoder.setComputePipelineState(pipeline)
            for (index, buffer) in [buffers.values, buffers.offsets, buffers.control, buffers.contacts].enumerated() {
                encoder.setBuffer(buffer, offset: 0, index: index)
            }
            var parameters = SIMD2(mode, UInt32(0))
            encoder.setBytes(&parameters, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 4)
            encoder.setBuffer(buffers.overflow, offset: 0, index: 5)
            encoder.setThreadgroupMemoryLength(2 * width * MemoryLayout<SIMD4<UInt32>>.stride, index: 0)
            encoder.dispatchThreadgroups(.init(width: 1, height: 1, depth: 1),
                                         threadsPerThreadgroup: .init(width: width, height: 1, depth: 1))
            return 1
        }
        // Trzystopniowy skan blokowy (dla obecnej pojemności): każdy blok ma 256 work-itemów.
        // Rekurencja skanuje sumy bloków, a osobne dispatchy dodają offsety rodziców.
        var dispatches = 0
        var lengths = [maximum]
        while lengths.last! > 256 { lengths.append((lengths.last! + 255) / 256) }
        let levelCount = buffers.blockSums.count
        for level in lengths.indices {
            encoder.memoryBarrier(scope: .buffers)
            encoder.setComputePipelineState(pipelines["nativeScanBlocks"]!)
            let input = level == 0 ? buffers.values : buffers.blockSums[level - 1]
            let output = level == 0 ? buffers.offsets : buffers.blockOffsets[level - 1]
            for (i, b) in [input, output, buffers.blockSums[level], buffers.control, buffers.contacts].enumerated() {
                encoder.setBuffer(b, offset: 0, index: i)
            }
            var parameters = SIMD2(mode, UInt32(level))
            encoder.setBytes(&parameters, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 5)
            if mode == 0 {
                encoder.dispatchThreadgroups(.init(width: (lengths[level] + 255) / 256, height: 1, depth: 1),
                    threadsPerThreadgroup: .init(width: 256, height: 1, depth: 1))
            } else {
                encoder.dispatchThreadgroups(indirectBuffer: buffers.indirectArguments,
                    indirectBufferOffset: (5 + (Int(mode) - 1) * levelCount + level) * 16,
                    threadsPerThreadgroup: .init(width: 256, height: 1, depth: 1))
            }
            dispatches += 1
        }
        if lengths.count > 1 {
            for level in (0..<(lengths.count - 1)).reversed() {
                encoder.memoryBarrier(scope: .buffers)
                encoder.setComputePipelineState(pipelines["nativeAddScanBlockOffsets"]!)
                let output = level == 0 ? buffers.offsets : buffers.blockOffsets[level - 1]
                for (i, b) in [output, buffers.blockOffsets[level], buffers.control, buffers.contacts].enumerated() {
                    encoder.setBuffer(b, offset: 0, index: i)
                }
                var parameters = SIMD2(mode, UInt32(level))
                encoder.setBytes(&parameters, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 4)
                if mode == 0 {
                    encoder.dispatchThreads(.init(width: lengths[level], height: 1, depth: 1),
                        threadsPerThreadgroup: .init(width: 256, height: 1, depth: 1))
                } else {
                    encoder.dispatchThreadgroups(indirectBuffer: buffers.indirectArguments,
                        indirectBufferOffset: (5 + (Int(mode) - 1) * levelCount + level) * 16,
                        threadsPerThreadgroup: .init(width: 256, height: 1, depth: 1))
                }
                dispatches += 1
            }
        }
        encoder.memoryBarrier(scope: .buffers)
        encoder.setComputePipelineState(pipelines["nativeFinishScan"]!)
        for (i, b) in [buffers.offsets, buffers.control, buffers.contacts].enumerated() { encoder.setBuffer(b, offset: 0, index: i) }
        var parameters = SIMD2(mode, UInt32(0))
        encoder.setBytes(&parameters, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 3)
        encoder.setBuffer(buffers.overflow, offset: 0, index: 4)
        encoder.dispatchThreads(.init(width: 1, height: 1, depth: 1), threadsPerThreadgroup: .init(width: 1, height: 1, depth: 1))
        return dispatches + 1
    }
}

/// Jeden przebieg naprawy zawierania: rozsunięcie baniek i guard środków po nim. `fused`: jeden dispatch zamiast dwóch
/// (nativeSeparateContainedBubbles, potem nativeReapplyCenterGuards na wyniku); guard dotyka tylko własnej pozycji
/// bańki i danych tylko do odczytu, więc może iść tym samym wątkiem zaraz po zapisie pozycji.
/// `fused: false` (dwa dispatche) zostaje wyłącznie jako wzorzec bit w bit dla `NativeMetalChainKernelTests`;
/// produkcja zawsze przekazuje `fused: true`.
enum NativeMetalContainmentRepair {
    /// Zwraca liczbę zakodowanych dispatchy.
    @discardableResult
    static func encodePass(_ encoder: MTLComputeCommandEncoder, pipelines: [String: MTLComputePipelineState],
                           bubbles: MTLBuffer, segments: MTLBuffer, input: MTLBuffer, output: MTLBuffer,
                           control: MTLBuffer, solver: MTLBuffer, contacts: MTLBuffer, changed: MTLBuffer,
                           safety: MTLBuffer, statistics: MTLBuffer, repairActive: MTLBuffer, pass: Int,
                           bubbleCount: Int, fused: Bool) -> Int {
        let pipeline = pipelines[fused ? "nativeSeparateAndGuardContainedBubbles" : "nativeSeparateContainedBubbles"]!
        encoder.memoryBarrier(scope: .buffers)
        encoder.setComputePipelineState(pipeline)
        encoder.setThreadgroupMemoryLength(pipeline.threadExecutionWidth * MemoryLayout<SIMD2<Float>>.stride, index: 0)
        for (index, buffer) in [bubbles, input, output, control, solver, changed, safety, repairActive].enumerated() {
            encoder.setBuffer(buffer, offset: 0, index: index)
        }
        var repairPass = UInt32(pass)
        encoder.setBytes(&repairPass, length: MemoryLayout<UInt32>.stride, index: 8)
        if fused { for (index, buffer) in [segments, contacts, statistics].enumerated() { encoder.setBuffer(buffer, offset: 0, index: 9 + index) } }
        if bubbleCount > 0 {
            encoder.dispatchThreadgroups(.init(width: bubbleCount, height: 1, depth: 1),
                threadsPerThreadgroup: .init(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
        }
        guard !fused else { return 1 }
        // Dawna wersja: guard na wyniku rozsunięcia (z flagą ruchu w `.z`).
        let guardPipeline = pipelines["nativeReapplyCenterGuards"]!
        encoder.memoryBarrier(scope: .buffers)
        encoder.setComputePipelineState(guardPipeline)
        for (index, buffer) in [bubbles, segments, output, control, contacts, changed, safety, statistics].enumerated() {
            encoder.setBuffer(buffer, offset: 0, index: index)
        }
        if bubbleCount > 0 {
            encoder.dispatchThreads(.init(width: bubbleCount, height: 1, depth: 1),
                threadsPerThreadgroup: .init(width: min(guardPipeline.threadExecutionWidth, guardPipeline.maxTotalThreadsPerThreadgroup),
                                             height: 1, depth: 1))
        }
        return 2
    }
}
