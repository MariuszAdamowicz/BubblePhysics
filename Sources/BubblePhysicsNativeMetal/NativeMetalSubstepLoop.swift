import Metal

/// Kodowanie pętli podkroków silnika 4.0.0 (CD-D-18, CD-D-21). Kontakt jednej bańki zależy od położenia sąsiadki, więc siły liczą się
/// dopiero po ruchu wszystkich baniek: podkrok to `nativeReduceSubstep` (h, zero grup dla podkroku pustego), ½ impulsu z ruchem,
/// `nativeContactForces` z nowego stanu i drugie ½ impulsu. Jądra podkroku idą pośrednią dyspozycją z liczbą grup z redukcji, więc
/// podkrok pusty (czas kroku minął, znacznik przebudowy albo limitu) kosztuje tylko wyjście z `nativeReduceSubstep`.
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

    /// a₀ z siły globalnej, pól, gumki i motoru oraz zapas obwiedni i x₀ z położeń początku kroku. Przy przebudowie
    /// w tej samej klatce liczy się z czasu pozostałego w kroku; `minimumMarginOnly` zostawia sam zapas r / 4.
    static func encodeBroadphaseInputs(_ encoder: MTLComputeCommandEncoder, pipelines: [String: MTLComputePipelineState],
                                       state: NativeMetalPersistentState, forces: NativeMetalForceBuffers, count: Int,
                                       minimumMarginOnly: Bool = false) {
        bind(encoder, pipelines["nativeAccelerationWithoutContacts"]!, [state.workingBubbles, state.control, forces.control!,
            forces.fields!, forces.fieldVertices!, forces.fieldObjectIDs!, state.nonContactAcceleration, forces.bands!, forces.motors!])
        dispatch(encoder, count: count)
        bind(encoder, pipelines["nativeBroadphaseMargin"]!, [state.workingBubbles, state.control, state.nonContactAcceleration,
            state.substepControl, state.broadphaseMargin, state.referencePositions])
        var minimumOnly: UInt32 = minimumMarginOnly ? 1 : 0
        encoder.setBytes(&minimumOnly, length: MemoryLayout<UInt32>.stride, index: 6)
        dispatch(encoder, count: count)
    }

    private static func contactForces(_ encoder: MTLComputeCommandEncoder, pipelines: [String: MTLComputePipelineState],
                                      state: NativeMetalPersistentState, rigid: NativeRigidPolygonState, count: Int, indirect: Bool) {
        bind(encoder, pipelines["nativeContactForces"]!, [state.workingBubbles, state.workingSegments, state.control,
            state.contactControl, state.adjacency, state.adjacencyCounts, state.contactForces,
            rigid.bodies, rigid.vertices, rigid.triangles, state.substepControl])
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
        encoder.setBuffer(forces.bands!, offset: 0, index: 12)
        encoder.setBuffer(forces.motors!, offset: 0, index: 13)
        if indirect { dispatchIndirect(encoder, state: state) } else { dispatch(encoder, count: count) }
    }

    /// Wiąże `nativeAssertContacts` z jego buforami i liczbą brył; wywołujący dyspozytuje (po podkroku zwykłą dyspozycją, na końcu kroku
    /// przez bramkę). Rekord naruszenia jest lepki w klatce, więc asercja po podkroku i na końcu kroku piszą do tego samego rekordu.
    static func bindAssertContacts(_ encoder: MTLComputeCommandEncoder, pipelines: [String: MTLComputePipelineState],
                                   state: NativeMetalPersistentState, rigid: NativeRigidPolygonState, bodyCount: Int) {
        bind(encoder, pipelines["nativeAssertContacts"]!, [state.workingBubbles, state.workingSegments, state.control,
            rigid.bodies, rigid.vertices, rigid.triangles, state.substepControl, state.contactAssertion, state.contactAssertion])
        var counts = SIMD4<UInt32>(UInt32(bodyCount), 0, 0, 0)
        encoder.setBytes(&counts, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 9)
    }

    /// Wstrzyknięcie stanu i asercja po podkroku (tylko przełączniki diagnostyczne; bez nich nic się nie koduje).
    private static func encodeSubstepDiagnostics(_ encoder: MTLComputeCommandEncoder, pipelines: [String: MTLComputePipelineState],
                                                 state: NativeMetalPersistentState, rigid: NativeRigidPolygonState, count: Int,
                                                 diagnostics: NativeMetalSubstepDiagnostics) {
        if let injection = diagnostics.injection {
            bind(encoder, pipelines["nativeInjectSubstepState"]!, [state.workingBubbles, state.control, state.substepControl])
            var selection = SIMD2<UInt64>(injection.objectID, UInt64(max(injection.afterSubstep, 0)))
            var position = injection.position
            encoder.setBytes(&selection, length: MemoryLayout<SIMD2<UInt64>>.stride, index: 3)
            encoder.setBytes(&position, length: MemoryLayout<SIMD2<Float>>.stride, index: 4)
            dispatch(encoder, count: count)
        }
        if diagnostics.assertEverySubstep {
            bindAssertContacts(encoder, pipelines: pipelines, state: state, rigid: rigid, bodyCount: diagnostics.bodyCount)
            dispatch(encoder, count: count)
        }
    }

    /// Siły pełne (z kontaktami) w położeniach początku kroku i przyspieszenie początku kroku, potem `substeps` podkroków.
    /// Zakłada zbudowane sąsiedztwo (`adjacency`, `adjacencyCounts`) i `substepControl` z czasem kroku.
    static func encode(_ encoder: MTLComputeCommandEncoder, pipelines: [String: MTLComputePipelineState],
                       state: NativeMetalPersistentState, forces: NativeMetalForceBuffers, rigid: NativeRigidPolygonState, count: Int,
                       capture: Bool, substeps: Int,
                       diagnostics: NativeMetalSubstepDiagnostics = NativeMetalSubstepDiagnostics()) {
        guard count > 0 else { return }
        contactForces(encoder, pipelines: pipelines, state: state, rigid: rigid, count: count, indirect: false)
        integrate(encoder, pipelines: pipelines, state: state, forces: forces, phase: .initialAcceleration, capture: capture,
                  count: count, indirect: false)
        let reduction = pipelines["nativeReduceSubstep"]!
        let width = NativeMetalSubstep.reductionWidth(reduction)
        for _ in 0..<substeps {
            bind(encoder, reduction, [state.workingBubbles, state.workingSegments, state.control, state.contactControl,
                state.adjacency, state.adjacencyCounts, state.acceleration, state.substepControl, state.substepDispatch,
                state.substepSteps, state.broadphaseMargin, state.referencePositions, forces.control!, forces.bands!,
                rigid.bodies, rigid.vertices, rigid.triangles])
            encoder.dispatchThreadgroups(.init(width: 1, height: 1, depth: 1), threadsPerThreadgroup: .init(width: width, height: 1, depth: 1))
            integrate(encoder, pipelines: pipelines, state: state, forces: forces, phase: .kickAndMove, capture: capture,
                      count: count, indirect: true)
            contactForces(encoder, pipelines: pipelines, state: state, rigid: rigid, count: count, indirect: true)
            integrate(encoder, pipelines: pipelines, state: state, forces: forces, phase: .forcesAndKick, capture: capture,
                      count: count, indirect: true)
            encodeSubstepDiagnostics(encoder, pipelines: pipelines, state: state, rigid: rigid, count: count, diagnostics: diagnostics)
        }
    }
}

/// Wynik `NativeMetalSubstepLoop.run`: liczba par buforów klatki i czasy GPU osobno dla buforów podkroków (fizyka) i końca kroku (kontur).
struct NativeMetalSubstepRun {
    var pairCount = 0
    /// Przebudowy siatki w klatce: każda para po pierwszej zaczyna od przebudowy siatki i kandydatów (zapas wyczerpany albo para za krótka).
    var rebuildCount: Int { max(0, pairCount - 1) }
    /// Przebudowy wymuszone znacznikiem zapasu obwiedni (`h_zapasu` wyznaczył h albo zapas się wyczerpał, `substepControl.counts.z`),
    /// bez par, które skończyły się tylko dlatego, że wyczerpały swoje podkroki (CD-D-23).
    var marginRebuildCount = 0
    /// Odrzuceni kandydaci kontaktu w klatce: największy licznik z jednej budowy siatki (każda para zaczyna od zera), bo ta sama odrzucona
    /// para wraca przy każdej przebudowie i suma po parach liczyłaby ją wielokrotnie (CD-D-26).
    var candidateOverflowCount = 0
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
                if control.counts.z != 0 { result.marginRebuildCount += 1 }
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
            // Licznik odrzuconych kandydatów zbiera się w jednej budowie siatki; kolejna para zaczyna od zera (maksimum na obiekt zostaje).
            let overflow = state.candidateOverflow.contents().load(as: SIMD4<UInt32>.self)
            result.candidateOverflowCount = max(result.candidateOverflowCount, Int(overflow.x))
            result.substepGPUMilliseconds += max(0, stepsCommand.gpuEndTime - stepsCommand.gpuStartTime) * 1_000
            result.endGPUMilliseconds += end.gpuMilliseconds
            let control = state.substepControl.contents().load(as: NativeMetalSubstepControl.self)
            let finished = control.counts.w == 0 && !(control.time.x - control.time.y > 0)
            if finished || control.counts.w != 0 { return result }
            state.candidateOverflow.contents().storeBytes(of: UInt32(0), as: UInt32.self)
            let used = Int(control.counts.y)
            guard used > done else { throw NativeMetalSolverError.commandFailed("pętla podkroków nie postępuje") }
            done = used
            pairSize *= 2
        }
    }
}
