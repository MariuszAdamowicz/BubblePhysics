import BubblePhysicsModel
import Metal

// Lustra Swift rekordów sił silnika 4.0.0 (CD-D-5): host nie liczy już gumki, pól, motoru ani siły globalnej, tylko opisuje je GPU.
// ABI Swift/MSL: wyłącznie lane'y SIMD o wyrównaniu 16 bajtów; układ pilnuje `NativeMetalShaderABITests`, a odpowiedniki
// shaderowe leżą na początku `NativeForceKernels.metal-source`. Identyfikator obiektu to surowa wartość `ObjectID` w `identity.x`.

/// Gumka bańki w roli `.playerDriven`: cel stoi w kroku, więc siła K_band · (cel − x) liczy się w każdym podkroku z bieżącego x.
struct NativeMetalBandDrive: Equatable, Sendable {
    var identity: SIMD2<UInt64> // ID bańki, reserved
    var band: SIMD4<Float> // cel.xy, K_band, maximumForce (0 = bez limitu; polityka wymaga limitu > 0)
}

/// Pole sił z geometrią zasięgu i filtrem obiektów. Wierzchołki wielokąta i identyfikatory filtra leżą w osobnych tablicach
/// `NativeForceInput`, a rekord wskazuje ich zakresy.
struct NativeMetalForceField: Equatable, Sendable {
    static let directionalKind: UInt32 = 0
    static let radialKind: UInt32 = 1
    static let vortexKind: UInt32 = 2

    var identity: SIMD2<UInt64> // ID pola, reserved
    var pose: SIMD4<Float> // położenie.xy, obrót, falloff
    var strength: SIMD4<Float> // siła kierunkowa.xy, siła radialna albo wirowa, promień zasięgu (koło: promień, wielokąt: najdalszy wierzchołek)
    var shape: SIMD4<UInt32> // rodzaj, początek wierzchołków, liczba wierzchołków (0 = koło), reserved
    var filter: SIMD4<UInt32> // początek identyfikatorów, liczba identyfikatorów, filtr obecny (1; pusty filtr nie działa na nikogo), reserved
}

/// Motor bańki w roli `.motorDriven`: stała siła i moment; bezwładność ½ m r² host liczy z bieżącego promienia kolizji.
struct NativeMetalMotor: Equatable, Sendable {
    var identity: SIMD2<UInt64> // ID bańki, reserved
    var drive: SIMD4<Float> // siła.xy, moment, bezwładność
}

/// Sterowanie pętlą podkroków na GPU: czasy, liczniki i obiekt wyznaczający h w ostatnim podkroku.
struct NativeMetalSubstepControl: Equatable, Sendable {
    var time = SIMD4<Float>.zero // czas kroku, czas upłynięty, h, mnożnik wymuszonego podziału h (substepSplitMultiplier; < 1 znaczy 1)
    var counts = SIMD4<UInt32>.zero // podkroki pary buforów, podkroki klatki, znacznik przebudowy, znacznik limitu
    var limiter = SIMD2<UInt64>.zero // obiekt wyznaczający h, człon h
}

/// Pierwsze naruszenie asercji kontaktu w klatce (`nativeAssertContacts`): lepki rekord, który host czyta po kroku i zeruje przed następnym.
struct NativeMetalContactAssertion: Equatable, Sendable {
    /// Rodzaj w `state.x`; zero oznacza brak naruszenia.
    enum Kind: UInt32 {
        case pair = 1, insideBody = 2, edgeSide = 3
    }
    var state = SIMD4<UInt32>.zero // rodzaj naruszenia, ID odcinka (rodzaj edgeSide), reserved, reserved
    var objects = SIMD2<UInt64>.zero // bańka i drugi koniec: bańka, bryła albo właściciel odcinka
    var detail = SIMD4<Float>.zero // d (para: odległość środków; krawędź: strona środka po ruchu), reserved
}

/// Przełączniki diagnostyczne kodowania podkroków (G6-AC2): stan wstrzykiwany po wskazanym podkroku i asercja po każdym podkroku.
struct NativeMetalSubstepDiagnostics {
    var injection: NativeMetalInjectedSubstepState?
    var assertEverySubstep = false
    var bodyCount = 0
}

/// Stałe jądra `nativeSubstepLoopSingleGroup` (lustro `NativeSingleGroupParameters`): zapas tylko r / 4, liczba kubełków siatki, bryły jako kandydaci,
/// zapis podkroków; wstrzyknięcie stanu, asercja po podkroku, liczba brył asercji i podkrok wstrzyknięcia; obiekt i położenie wstrzyknięcia;
/// przesunięcia wycinków bloku sterowania kroku i rekordów sił we wspólnych buforach (bugfix iPhone X, BF-D-2).
struct NativeMetalSingleGroupParameters: Equatable, Sendable {
    var flags: SIMD4<UInt32>
    var diagnostics: SIMD4<UInt32>
    var injectionObject: SIMD2<UInt64>
    var injectionPosition: SIMD4<Float>
    /// Sterowanie kontaktów, statystyki dyspozycji, liczniki odrzuceń, sterowanie podkroków.
    var stepControlOffsets: SIMD4<UInt32>
    /// Argumenty dyspozycji pośredniej, historia h, rekord asercji, reserved.
    var stepControlOffsetsTail: SIMD4<UInt32>
    /// Pola, wierzchołki pól, ID obiektów pól, gumki.
    var forceRecordOffsets: SIMD4<UInt32>
    /// Motory, reserved.
    var forceRecordOffsetsTail: SIMD4<UInt32>
}

/// Stałe jąder sił poza rekordami: siła globalna i liczby rekordów w buforach `NativeMetalForceBuffers`.
struct NativeMetalForceControl: Equatable, Sendable {
    var global = SIMD4<Float>.zero // siła globalna.xy, reserved
    var counts = SIMD4<UInt32>.zero // pola, gumki, motory, reserved
}

/// Stałe pętli podkroków wspólne dla Swift i MSL (`NativeForceKernels.metal-source`).
enum NativeMetalSubstep {
    /// Najwięcej podkroków w klatce (CD-D-21); kolejny podkrok ustawia znacznik limitu.
    static let frameLimit = 1024
    /// Świat do tylu baniek liczy krok jedną dyspozycją jednej grupy wątków (CD-D-27); większy idzie parami buforów.
    static let singleDispatchBubbleLimit = 1024
    /// Pamięć grupy jądra jednej grupy w bajtach: jedna tablica współdzielona przez fazy (kubełki siatki 8 KB, sumy częściowe i skan nad nią).
    static let singleGroupMemoryLength = 16_384
    /// Liczba slotów buforów `nativeSubstepLoopSingleGroup`; parametry idą w następnym slocie. Z parametrami mieści się w limicie
    /// 31 wpisów tablicy buforów funkcji na A11 (bugfix iPhone X, BF-D-2).
    static let singleGroupBufferCount = 28
    /// Szerokość grupy jąder podkroku; `nativeReduceSubstep` zapisuje liczbę grup dla tej szerokości.
    static let groupWidth = 64
    /// Szerokość grupy `nativeReduceSubstep` (jedna grupa na świat) w ścieżce wielu dyspozycji: największa potęga dwójki, którą pipeline pomieści, do 1024.
    /// Jądro jednej grupy bierze `NativeMetalSolver.singleGroupWidth` (bez wymogu potęgi dwójki); redukcja jest poprawna dla każdej szerokości do 1024.
    static func reductionWidth(_ pipeline: MTLComputePipelineState) -> Int {
        var width = 1
        while width * 2 <= min(pipeline.maxTotalThreadsPerThreadgroup, 1024) { width *= 2 }
        return width
    }
    /// Człon wyznaczający h w `NativeMetalSubstepControl.limiter.y`.
    enum Term: UInt64 {
        case remainingTime = 0, stiffness = 1, distance = 2, margin = 3
    }
    /// Bramki dyspozycji końca kroku (`nativePrepareEndGates`): indeks w `NativeMetalPersistentState.endGates`. Pierwsze osiem to jądra z
    /// efektem ubocznym, reszta to dyspozycje bezpośrednie, które w parze niekońcowej przepisałyby sąsiedztwo i liczniki kontaktów
    /// czytane przez kontynuację pętli albo liczyłyby kontur zbędnie (CD-D-29).
    enum EndGate: Int, CaseIterable {
        case region, mergeEvents, sensors, missingSensors, rigidFinish, polygonSensors, missingPolygonSensors, contactAssertion
        case bubbleBodyContacts, contactScan, indirectArguments, clearAdjacency, buildAdjacency, contactPressure, structuralContours,
             contour, renderPreparation, hitTest
    }
    /// Sloty argumentów dyspozycji pośrednich końca kroku, za slotami pętli w `NativeMetalPersistentState.indirectArguments`
    /// (`endArgumentBase`). Osobne, żeby bramka pary niekońcowej nie zerowała slotów pętli podkroków (CD-D-29).
    enum EndArgument: Int, CaseIterable {
        case buildContacts, prepareContactFlags, compactActiveContacts, emitAdjacency, contactImpulses, checkFinite
    }
    /// Fazy `nativeIntegrateSubstep`: ½ impulsu i ruch; siły z nowego stanu i ½ impulsu; przyspieszenie początku kroku.
    enum Phase: UInt32 {
        case kickAndMove = 0, forcesAndKick = 1, initialAcceleration = 2
    }
}

/// Bufory rekordów sił jednego kroku na GPU: wycinki jednego wspólnego bufora (jeden slot jądra jednej grupy zamiast sześciu,
/// bugfix iPhone X, BF-D-2), który rośnie razem z liczbą rekordów i jest używany ponownie między klatkami.
@MainActor
final class NativeMetalForceBuffers {
    private let recordBuffer = NativeMetalReusableBuffer()
    /// Wspólny bufor wycinków `control`, `fields`, `fieldVertices`, `fieldObjectIDs`, `bands` i `motors`; nil przed pierwszym `upload`.
    var records: MTLBuffer? { recordBuffer.buffer }
    private(set) var control: NativeMetalBufferSlice?
    private(set) var fields: NativeMetalBufferSlice?
    private(set) var fieldVertices: NativeMetalBufferSlice?
    private(set) var fieldObjectIDs: NativeMetalBufferSlice?
    private(set) var bands: NativeMetalBufferSlice?
    private(set) var motors: NativeMetalBufferSlice?

    func upload(_ input: NativeForceInput, device: MTLDevice) throws {
        let counts = SIMD4(UInt32(input.fields.count), UInt32(input.bandDrives.count), UInt32(input.motors.count), 0)
        let controlRecords = [NativeMetalForceControl(global: SIMD4(input.globalForce.x, input.globalForce.y, 0, 0), counts: counts)]
        let lengths = try [Self.length(controlRecords), Self.length(input.fields), Self.length(input.fieldVertices),
                           Self.length(input.fieldObjectIDs), Self.length(input.bandDrives), Self.length(input.motors)]
        let buffer = try recordBuffer.reserve(count: NativeMetalBufferSlice.layout(lengths).length, stride: 1, device: device)
        let slices = NativeMetalBufferSlice.slices(of: buffer, lengths: lengths)
        Self.copy(controlRecords, to: slices[0])
        Self.copy(input.fields, to: slices[1])
        Self.copy(input.fieldVertices, to: slices[2])
        Self.copy(input.fieldObjectIDs, to: slices[3])
        Self.copy(input.bandDrives, to: slices[4])
        Self.copy(input.motors, to: slices[5])
        control = slices[0]
        fields = slices[1]
        fieldVertices = slices[2]
        fieldObjectIDs = slices[3]
        bands = slices[4]
        motors = slices[5]
    }

    /// Długość wycinka: pusta tablica zajmuje jeden rekord, żeby wiązanie zawsze wskazywało pamięć.
    private static func length<T>(_ values: [T]) throws -> Int {
        let (length, overflow) = max(1, values.count).multipliedReportingOverflow(by: MemoryLayout<T>.stride)
        guard !overflow else { throw NativeMetalSolverError.allocationFailed }
        return length
    }

    private static func copy<T>(_ values: [T], to slice: NativeMetalBufferSlice) {
        values.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { memcpy(slice.contents(), base, bytes.count) }
        }
    }
}

/// Dane wejściowe sił jednego kroku, zbudowane z obiektów świata po `MotionControllers.prepare`. Rekordy idą po ID, więc
/// kolejność nie zależy od kolejności obiektów na wejściu. Siły dla brył dynamicznych liczy dalej host (bryły są poza podkrokami).
struct NativeForceInput: Equatable, Sendable {
    var globalForce: WorldPoint = .zero
    var bandDrives: [NativeMetalBandDrive] = []
    var fields: [NativeMetalForceField] = []
    var fieldVertices: [SIMD2<Float>] = []
    var fieldObjectIDs: [UInt64] = []
    var motors: [NativeMetalMotor] = []

    init() {}

    init(objects: [NativePublicObject], globalForce: WorldPoint) {
        self.globalForce = globalForce
        for object in objects.sorted(by: { $0.descriptor.id.rawValue < $1.descriptor.id.rawValue }) {
            let id = object.descriptor.id.rawValue
            switch object.descriptor {
            case .bubble(let bubble):
                switch object.motionRole {
                case .playerDriven:
                    guard let target = object.playerDriveTarget, let policy = bubble.drivePolicy else { break }
                    bandDrives.append(NativeMetalBandDrive(identity: SIMD2(id, 0),
                        band: SIMD4(target.x, target.y, policy.bandStiffness, policy.maximumForce ?? 0)))
                case .motorDriven:
                    guard let motor = object.motorDrive else { break }
                    let inertia = 0.5 * bubble.mass * object.collisionRadius * object.collisionRadius
                    motors.append(NativeMetalMotor(identity: SIMD2(id, 0),
                                                   drive: SIMD4(motor.force.x, motor.force.y, motor.torque, inertia)))
                case .static, .dynamic, .kinematic, .pathDriven: break
                }
            case .forceField(let field):
                appendField(field, id: id)
            case .rigidBody, .sensor: break
            }
        }
    }

    private mutating func appendField(_ field: ForceFieldDescriptor, id: UInt64) {
        var strength = SIMD4<Float>.zero
        var kind = NativeMetalForceField.directionalKind
        var falloff: Float = 0
        switch field.field {
        case .directional(let force): strength.x = force.x; strength.y = force.y
        case .radial(let value, let exponent): kind = NativeMetalForceField.radialKind; strength.z = value; falloff = exponent
        case .vortex(let value, let exponent): kind = NativeMetalForceField.vortexKind; strength.z = value; falloff = exponent
        }
        var vertexStart: UInt32 = 0, vertexCount: UInt32 = 0
        switch field.geometry.shape {
        case .circle(let radius): strength.w = radius
        case .polygon(let geometry):
            vertexStart = UInt32(fieldVertices.count); vertexCount = UInt32(geometry.vertices.count)
            fieldVertices.append(contentsOf: geometry.vertices)
            // Ten sam promień zaniku co dotychczas na hoście: najdalszy wierzchołek od środka pola.
            strength.w = geometry.vertices.map { ($0.x * $0.x + $0.y * $0.y).squareRoot() }.max() ?? 1
        }
        var idStart: UInt32 = 0, idCount: UInt32 = 0, hasFilter: UInt32 = 0
        if let ids = field.filter.objectIDs {
            idStart = UInt32(fieldObjectIDs.count); idCount = UInt32(ids.count); hasFilter = 1
            fieldObjectIDs.append(contentsOf: ids.map(\.rawValue).sorted())
        }
        fields.append(NativeMetalForceField(identity: SIMD2(id, 0),
            pose: SIMD4(field.position.x, field.position.y, field.rotation, falloff), strength: strength,
            shape: SIMD4(kind, vertexStart, vertexCount, 0), filter: SIMD4(idStart, idCount, hasFilter, 0)))
    }
}
