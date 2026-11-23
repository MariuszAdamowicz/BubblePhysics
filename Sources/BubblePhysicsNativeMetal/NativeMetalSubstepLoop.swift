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

/// Wynik `NativeMetalSubstepLoop.run`: liczba par buforów klatki i czasy GPU osobno dla buforów podkroków (fizyka) i końca kroku (kontur).
struct NativeMetalSubstepRun {
    var pairCount = 0
    var substepGPUMilliseconds = 0.0
    var endGPUMilliseconds = 0.0
}

extension NativeMetalSubstepLoop {
    /// Bufor podkroków kończy się przed buforem końca kroku (kolejność commitu), więc to wywołanie wraca od razu; handler po commicie
    /// jest niedozwolony, a `waitUntilCompleted` jest niedostępne w kontekście asynchronicznym, stąd osobna funkcja synchroniczna.
    private static func waitForCompletion(_ command: MTLCommandBuffer) { command.waitUntilCompleted() }

    /// Pary buforów klatki (CD-D-18): bufor podkroków i bufor końca kroku commitują się jeden po drugim bez czekania, a CPU czeka
    /// na bufor końca kroku i czyta licznik. Pierwsza para ma 2 × podkroków poprzedniej klatki (najmniej 2), każda kolejna 2 × więcej;
    /// kolejna para zaczyna od przebudowy siatki (`encodePair` koduje cały początek pary). Pętla kończy się, gdy czas kroku minął
    /// albo ustawiono znacznik limitu (`NativeMetalSubstep.frameLimit`); bufor końca kroku ma jądra z efektem ubocznym za bramkami,
    /// więc przed końcem kroku nie zmienia stanu świata.
    ///
    /// `encodePair(indeks, podkroki)` zwraca parę niezatwierdzonych buforów (podkroków, końca kroku) w tej kolejności i woła
    /// `invalidatePreviousContours` swojego uchwytu przed pierwszym commitem.
    static func run(state: NativeMetalPersistentState, previousFrameSubsteps: Int, executor: any NativeMetalCommandExecuting,
                    prepareContinuation: () -> Void,
                    encodePair: (_ pair: Int, _ substeps: Int) throws -> (MTLCommandBuffer, MTLCommandBuffer)) async throws -> NativeMetalSubstepRun {
        var result = NativeMetalSubstepRun()
        var pairSize = max(2, 2 * previousFrameSubsteps)
        var done = 0
        while true {
            if result.pairCount > 0 {
                // Czasy i liczniki klatki zostają; licznik podkroków pary i znacznik przebudowy zaczynają od zera.
                var control = state.substepControl.contents().load(as: NativeMetalSubstepControl.self)
                control.counts.x = 0
                control.counts.z = 0
                state.substepControl.contents().storeBytes(of: control, as: NativeMetalSubstepControl.self)
                prepareContinuation()
            }
            // Jeden podkrok ponad limit, żeby `nativeReduceSubstep` ustawił znacznik limitu, gdy krok jeszcze trwa.
            let substeps = min(pairSize, NativeMetalSubstep.frameLimit + 1 - done)
            let (stepsCommand, endCommand) = try encodePair(result.pairCount, substeps)
            stepsCommand.commit()
            let end = try await executor.complete(endCommand)
            // Kolejka wykonuje bufory w kolejności commitu, więc bufor podkroków już się skończył.
            waitForCompletion(stepsCommand)
            guard stepsCommand.status == .completed else {
                throw NativeMetalSolverError.commandFailed(stepsCommand.error?.localizedDescription
                    ?? "Metal status \(stepsCommand.status.rawValue)")
            }
            result.pairCount += 1
            result.substepGPUMilliseconds += max(0, stepsCommand.gpuEndTime - stepsCommand.gpuStartTime) * 1_000
            result.endGPUMilliseconds += end.gpuMilliseconds
            let control = state.substepControl.contents().load(as: NativeMetalSubstepControl.self)
            let finished = control.counts.w == 0 && !(control.time.x - control.time.y > 0)
            if finished || control.counts.w != 0 { return result }
            let used = Int(control.counts.y)
            guard used > done else { throw NativeMetalSolverError.commandFailed("pętla podkroków nie postępuje") }
            done = used
            pairSize *= 2
        }
    }
}
