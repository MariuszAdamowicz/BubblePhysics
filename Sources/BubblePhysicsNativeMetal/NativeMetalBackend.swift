/// Konfiguracja silnika 4.0.0: bez pól publicznych. Przełączniki pakietowe służą testom i diagnostyce; domyślnie wszystkie są wyłączone.
public struct NativeMetalConfiguration: Equatable, Sendable {
    /// Mnożnik drobniejszego podziału podkroku (G4-AC3): 1 to podział naturalny, 4 daje czterokrotnie drobniejszy.
    package var substepSplitMultiplier = 1
    /// Zapas obwiedni tylko r / 4, bez członu z prędkości i przyspieszenia (G5-AC3).
    package var minimumMarginOnly = false
    /// Zapis x, v i h po każdym podkroku do odczytu przez test.
    package var captureSubsteps = false
    /// Asercja kontaktu po każdym podkroku, a nie tylko na końcu kroku (G6-AC2).
    package var assertEverySubstep = false
    /// Stan wstrzykiwany po wskazanym podkroku, by sprawdzić asercję kontaktu (G6-AC2).
    package var injectedSubstepState: NativeMetalInjectedSubstepState?
    /// Wymusza ścieżkę wielu dyspozycji (pary buforów) w każdym świecie, także do 1024 baniek (G8-AC4). Bez przełącznika ścieżkę wybiera próg.
    package var forceMultipleDispatches = false
    /// Mniejszy limit kandydatów na obiekt, 1...128 (G8-AC4). Skraca tylko wiersz kandydatów; pojemność buforów zostaje na 128.
    package var candidateLimitPerObject = NativeMetalSolver.candidateLimitPerObject
    /// Liczba kubełków siatki haszowanej w grupie, domyślnie 2048; 1 wymusza kolizję każdej komórki (P-B-46).
    package var gridHashBucketCount = NativeMetalConfiguration.defaultGridHashBucketCount

    /// Domyślna liczba kubełków siatki haszowanej jądra jednej grupy.
    package static let defaultGridHashBucketCount = 2048

    public init() {}

    public static let `default` = NativeMetalConfiguration()

    public var sanitized: NativeMetalConfiguration {
        var value = self
        value.substepSplitMultiplier = max(1, substepSplitMultiplier)
        value.candidateLimitPerObject = min(max(1, candidateLimitPerObject), NativeMetalSolver.candidateLimitPerObject)
        value.gridHashBucketCount = max(1, gridHashBucketCount)
        return value
    }
}

/// Stan bańki wstrzykiwany po podkroku (G6-AC2): przesuwa środek obiektu `objectID` na `position` po podkroku `afterSubstep`
/// (liczonym od 0 w klatce), żeby asercja kontaktu zobaczyła d ≤ 0 albo środek w bryle.
package struct NativeMetalInjectedSubstepState: Equatable, Sendable {
    package var afterSubstep: Int
    package var objectID: UInt64
    package var position: SIMD2<Float>
    package init(afterSubstep: Int, objectID: UInt64, position: SIMD2<Float>) {
        self.afterSubstep = afterSubstep; self.objectID = objectID; self.position = position
    }
}

/// Stan baniek po jednym podkroku, zapisany przy `captureSubsteps` do odczytu przez test (G4-AC2, G3-AC1): x i v każdej bańki
/// po podkroku oraz jego długość h. Kluczem jest surowa wartość `ObjectID`.
package struct NativeMetalSubstepSample: Equatable, Sendable {
    package struct Body: Equatable, Sendable {
        package var position: SIMD2<Float>
        package var velocity: SIMD2<Float>
        package init(position: SIMD2<Float>, velocity: SIMD2<Float>) { self.position = position; self.velocity = velocity }
    }
    package var h: Float
    package var bubbles: [UInt64: Body]
    package init(h: Float, bubbles: [UInt64: Body]) { self.h = h; self.bubbles = bubbles }
}

/// Który wykonawca opublikował klatkę. Neutralny odpowiednik typu diagnostycznego.
public enum NativeMetalFrameBackend: String, Equatable, Sendable {
    case cpu
    case nativeMetal = "native-metal"
}

/// Którą ścieżką wykonania liczono krok (CD-D-27): jedna dyspozycja jednej grupy do 1024 baniek albo pary buforów.
public enum NativeMetalExecutionPath: String, Equatable, Sendable {
    case singleDispatch
    case multipleDispatches
}

public struct NativeMetalFrameTelemetry: Equatable, Sendable {
    public let backend: NativeMetalFrameBackend
    public let commandBufferCount: Int
    public let encoderCount: Int
    public let contactCount: Int
    public let didEncounterNonFinite: Bool
    public let fallbackReason: String?
    public let gpuMilliseconds: Double
    /// Liczba podkroków fizyki w klatce (G8-AC1).
    public let substepCount: Int
    /// Liczba przebudów siatki wymuszonych zapasem obwiedni w klatce (człon `h_zapasu`, CD-D-23; G8-AC1), bez par buforów, które skończyły się
    /// samym wyczerpaniem podkroków. Pary liczy `substepBufferCount`.
    public let gridRebuildCount: Int
    /// Liczba par buforów podkroków w klatce (G8-AC1): 1 w ścieżce jednej dyspozycji.
    public let substepBufferCount: Int
    /// Ścieżka wykonania kroku (G8-AC4).
    public let executionPath: NativeMetalExecutionPath
    /// Szerokość grupy wątków jądra pętli podkroków; 0 w ścieżce wielu dyspozycji (A11 może dać mniej niż Mac).
    public let singleGroupWidth: Int
    /// Czas GPU fizyki: suma buforów podkroków. Osobno od konturu (G8-AC1).
    public let physicsGPUMilliseconds: Double
    /// Czas GPU konturu: bufor końca kroku (G8-AC1).
    public let contourGPUMilliseconds: Double

    public init(backend: NativeMetalFrameBackend = .cpu, commandBufferCount: Int = 0,
                encoderCount: Int = 0,
                contactCount: Int = 0, didEncounterNonFinite: Bool = false,
                fallbackReason: String? = nil, gpuMilliseconds: Double = 0,
                substepCount: Int = 0, gridRebuildCount: Int = 0, physicsGPUMilliseconds: Double = 0,
                contourGPUMilliseconds: Double = 0, substepBufferCount: Int = 0,
                executionPath: NativeMetalExecutionPath = .multipleDispatches, singleGroupWidth: Int = 0) {
        self.backend = backend
        self.commandBufferCount = commandBufferCount
        self.encoderCount = encoderCount
        self.contactCount = contactCount
        self.didEncounterNonFinite = didEncounterNonFinite
        self.fallbackReason = fallbackReason
        self.gpuMilliseconds = gpuMilliseconds
        self.substepCount = substepCount
        self.gridRebuildCount = gridRebuildCount
        self.physicsGPUMilliseconds = physicsGPUMilliseconds
        self.contourGPUMilliseconds = contourGPUMilliseconds
        self.substepBufferCount = substepBufferCount
        self.executionPath = executionPath
        self.singleGroupWidth = singleGroupWidth
    }
}
