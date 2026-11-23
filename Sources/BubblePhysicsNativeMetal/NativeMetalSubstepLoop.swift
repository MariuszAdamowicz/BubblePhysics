import Metal

/// Kodowanie pętli podkroków silnika 4.0.0 (CD-D-18, CD-D-21). Kontakt jednej bańki zależy od położenia sąsiadki, więc siły liczą się
/// dopiero po ruchu wszystkich baniek: podkrok to `nativeReduceSubstep` (h, zero grup dla podkroku pustego), ½ impulsu z ruchem,
/// `nativeContactForces` z nowego stanu i drugie ½ impulsu. Jądra podkroku idą pośrednią dyspozycją z liczbą grup z redukcji, więc
/// podkrok pusty (czas kroku minął, znacznik przebudowy albo limitu) kosztuje tylko wyjście z `nativeReduceSubstep`.
///
/// Stan przejściowy zadania 7 (do zadania 8): jedna pętla w jednym buforze poleceń z `NativeMetalSubstep.frameLimit` podkrokami.
@MainActor
enum NativeMetalSubstepLoop {
    private static func bind(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, _ buffers: [MTLBuffer]) {
        encoder.memoryBarrier(scope: .buffers)
        encoder.setComputePipelineState(pipeline)
        for (index, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: index) }
    }

    private static func dispatch(_ encoder: MTLComputeCommandEncoder, count: Int) {
        guard count > 0 else { return }
        encoder.dispatchThreads(.init(width: count, height: 1, depth: 1),
                                threadsPerThreadgroup: .init(width: NativeMetalSubstep.groupWidth, height: 1, depth: 1))
    }

    private static func dispatchIndirect(_ encoder: MTLComputeCommandEncoder, state: NativeMetalPersistentState) {
        encoder.dispatchThreadgroups(indirectBuffer: state.substepDispatch, indirectBufferOffset: 0,
            threadsPerThreadgroup: .init(width: NativeMetalSubstep.groupWidth, height: 1, depth: 1))
    }

    /// a₀ z siły globalnej i pól (gumka i motor dochodzą w zadaniu 10) oraz zapas obwiedni i x₀ z położeń początku kroku.
    static func encodeBroadphaseInputs(_ encoder: MTLComputeCommandEncoder, pipelines: [String: MTLComputePipelineState],
                                       state: NativeMetalPersistentState, forces: NativeMetalForceBuffers, count: Int) {
        bind(encoder, pipelines["nativeAccelerationWithoutContacts"]!, [state.workingBubbles, state.control, forces.control!,
            forces.fields!, forces.fieldVertices!, forces.fieldObjectIDs!, state.nonContactAcceleration])
        dispatch(encoder, count: count)
        bind(encoder, pipelines["nativeBroadphaseMargin"]!, [state.workingBubbles, state.control, state.nonContactAcceleration,
            state.substepControl, state.broadphaseMargin, state.referencePositions])
        dispatch(encoder, count: count)
    }

    private static func contactForces(_ encoder: MTLComputeCommandEncoder, pipelines: [String: MTLComputePipelineState],
                                      state: NativeMetalPersistentState, count: Int, indirect: Bool) {
        bind(encoder, pipelines["nativeContactForces"]!, [state.workingBubbles, state.workingSegments, state.control,
            state.contactControl, state.adjacency, state.adjacencyCounts, state.contactForces])
        if indirect { dispatchIndirect(encoder, state: state) } else { dispatch(encoder, count: count) }
    }

    private static func integrate(_ encoder: MTLComputeCommandEncoder, pipelines: [String: MTLComputePipelineState],
                                  state: NativeMetalPersistentState, forces: NativeMetalForceBuffers, phase: NativeMetalSubstep.Phase,
                                  capture: Bool, count: Int, indirect: Bool) {
        bind(encoder, pipelines["nativeIntegrateSubstep"]!, [state.workingBubbles, state.control, forces.control!, forces.fields!,
            forces.fieldVertices!, forces.fieldObjectIDs!, state.acceleration, state.nonContactAcceleration, state.contactForces,
            state.substepControl, state.substepCapture ?? state.acceleration])
        var mode = SIMD4<UInt32>(phase.rawValue, capture ? 1 : 0, 0, 0)
        encoder.setBytes(&mode, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 11)
        if indirect { dispatchIndirect(encoder, state: state) } else { dispatch(encoder, count: count) }
    }

    /// Siły pełne (z kontaktami) w położeniach początku kroku i przyspieszenie początku kroku, potem `substeps` podkroków.
    /// Zakłada zbudowane sąsiedztwo (`adjacency`, `adjacencyCounts`) i `substepControl` z czasem kroku.
    static func encode(_ encoder: MTLComputeCommandEncoder, pipelines: [String: MTLComputePipelineState],
                       state: NativeMetalPersistentState, forces: NativeMetalForceBuffers, count: Int, capture: Bool,
                       substeps: Int = NativeMetalSubstep.frameLimit) {
        guard count > 0 else { return }
        contactForces(encoder, pipelines: pipelines, state: state, count: count, indirect: false)
        integrate(encoder, pipelines: pipelines, state: state, forces: forces, phase: .initialAcceleration, capture: capture,
                  count: count, indirect: false)
        let reduction = pipelines["nativeReduceSubstep"]!
        let width = NativeMetalSubstep.reductionWidth(reduction)
        for _ in 0..<substeps {
            bind(encoder, reduction, [state.workingBubbles, state.workingSegments, state.control, state.contactControl,
                state.adjacency, state.adjacencyCounts, state.acceleration, state.substepControl, state.substepDispatch,
                state.substepSteps])
            encoder.dispatchThreadgroups(.init(width: 1, height: 1, depth: 1), threadsPerThreadgroup: .init(width: width, height: 1, depth: 1))
            integrate(encoder, pipelines: pipelines, state: state, forces: forces, phase: .kickAndMove, capture: capture,
                      count: count, indirect: true)
            contactForces(encoder, pipelines: pipelines, state: state, count: count, indirect: true)
            integrate(encoder, pipelines: pipelines, state: state, forces: forces, phase: .forcesAndKick, capture: capture,
                      count: count, indirect: true)
        }
    }
}
