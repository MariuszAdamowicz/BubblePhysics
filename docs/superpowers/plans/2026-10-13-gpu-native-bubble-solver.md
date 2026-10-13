# GPU-native Bubble Solver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zbudować niezależny backend Metal oparty na trwałym stanie GPU, warm-starcie kontaktów i solverze XPBD/PBD, który zachowuje fizyczną wiarygodność CPU reference oraz ma drogę do bramki `stress-300 p95 <= 10 ms` na iPhonie X.

**Architecture:** Nowy target `BubblePhysicsNativeMetal` działa obok `BubblePhysicsReferenceMetal`; nie przenosi Newton/PCG ani jego harmonogramu. Jeden command buffer klatki utrzymuje stan symulacji i cache kontaktów na GPU, wykonuje siatkę broad phase, warm-start, stałą liczbę iteracji Jacobi XPBD/PBD, selektywny CCD, guardy i kontury. `ReferenceWorld` pozostaje API scen, wyrocznią jakości i fallbackiem CPU.

**Tech Stack:** Swift 5.9, Metal Shading Language 2.4, XCTest, Swift Package Manager, iOS 16+, macOS 13+ na Apple Silicon.

**Spec:** `docs/superpowers/specs/2026-10-13-gpu-native-bubble-solver-design.md`

## Global Constraints

- Zachować iOS 16 i macOS 13 jako minima oraz nie dodawać zależności.
- CPU reference pozostaje wyrocznią scen/testów i pełnoklatkowym fallbackiem; nie wymaga się bitowej zgodności trajektorii GPU.
- `BubblePhysicsReferenceMetal` pozostaje niezmienionym backendem referencyjnym/diagnostycznym; nowy kod trafia do `BubblePhysicsNativeMetal`.
- Normalna klatka GPU koduje jeden command buffer; host nie czeka ani nie steruje iteracjami między etapami.
- Stan baniek, cache kontaktów i scratch pozostają na GPU między klatkami; publikacja jest atomowa dopiero po ukończeniu command buffera.
- Warm-start jest ważny tylko dla kontaktów o kanonicznym kluczu; teleport, zmiana przeszkody, reset świata, CCD/containment i błąd numeryczny unieważniają właściwy cache.
- Solver używa jawnej, stałej konfiguracji iteracji XPBD/PBD; nie dodawać czasowego ani ukrytego limitu jakości.
- Wymagać `containment == 0`, `non_finite == no`, p95 penetracji `<= max(cpuP95 * 1.10, cpuP95 + 0.5)` i maksimum `<= max(cpuMax * 1.15, cpuMax + 1.0)`.
- Nie zmieniać podpisu Xcode, plików użytkownika ani `Benchmarks/iOS/BubblePhysicsBench/.DS_Store`.
- Mac mini jest pętlą profilowania; akceptacja wymaga iPhone'a X Release i `stress-300` p95 `<= 10 ms`, 30 warmup / 300 measured, bez fallbacków.

## Review Focus

1. Teleport lub ruchoma przeszkoda może pozostawić nieprawidłowy warm-start i wypchnąć bańkę w złą stronę; testy Task 3 muszą potwierdzić selektywne wyzerowanie cache.
2. Dwa kontakty dzielące bańkę nie mogą wywołać wyścigu lub zależności od kolejności wykonania; Task 4 testuje Jacobi na łańcuchu trzech baniek i powtarzalny hash.
3. Szybka bańka może ominąć ścianę między dyskretnymi krokami; Task 5 wymaga selektywnego CCD oraz testu braku przejścia środka przez odcinek.
4. Błąd, overflow lub brak pipeline'u nie może opublikować scratcha GPU; Task 2 utrzymuje atomowy fallback całej klatki do CPU.
5. Kontur może maskować niestabilny środek albo nie wracać do promienia spoczynkowego; Task 6 testuje deformację kontaktową, 30-klatkowy powrót i brak rosnącej oscylacji.

---

## Struktura plików

| Ścieżka | Odpowiedzialność |
| --- | --- |
| `Sources/BubblePhysicsNativeMetal/NativeMetalBackend.swift` | Publiczne typy backendu, telemetryka i klasyfikacja błędów. |
| `Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift` | Swift/MSL ABI trwałego stanu, kontaktów, cache i kontroli klatki. |
| `Sources/BubblePhysicsNativeMetal/NativeMetalWorldRunner.swift` | Życie sesji, atomowa publikacja i fallback CPU. |
| `Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift` | Własność zasobów Metal, kodowanie jednej klatki i odczyt finalnego wyniku. |
| `Sources/BubblePhysicsNativeMetal/NativeMetalBenchmarkRunner.swift` | Adapter nowego runnera do istniejącego harnessu benchmarkowego. |
| `Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source` | Predykcja, siatka broad phase, kandydaci i kontakty. |
| `Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source` | Dopasowanie cache, warm-start i iteracje Jacobi XPBD/PBD. |
| `Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source` | Selektywny CCD, guardy, prędkości, kontury i dane renderowania. |
| `Tests/BubblePhysicsNativeMetalTests/*` | Testy nowego backendu, niezależne od testów referencyjnego portu. |
| `Package.swift`, `Benchmarks/iOS/.../project.pbxproj` | Produkt, target testowy i jawne dołączenie produktu do aplikacji benchmarkowej. |

### Task 1: Wprowadzić izolowany kontrakt backendu GPU-native

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkReport.swift`
- Create: `Sources/BubblePhysicsNativeMetal/NativeMetalBackend.swift`
- Create: `Sources/BubblePhysicsNativeMetal/NativeMetalWorldRunner.swift`
- Create: `Tests/BubblePhysicsNativeMetalTests/NativeMetalWorldRunnerTests.swift`

**Interfaces:**
- Rozszerz `ReferenceSimulationBackend` o `case nativeMetal = "native-metal"`.
- `@MainActor public final class NativeMetalWorldRunner` udostępnia `init?(device: MTLDevice? = MTLCreateSystemDefaultDevice(), configuration: NativeMetalConfiguration = .default)` oraz `func step(world: inout ReferenceWorld, scenarioStep: Int) async -> ReferenceWorldStepReport`.
- `public struct NativeMetalConfiguration: Equatable, Sendable` zawiera `solverIterationCount`, `cacheExpiryFrames`, `teleportDistanceMultiplier`, `ccdVelocityMultiplier` oraz walidujący `sanitized`.
- `public struct NativeMetalFrameTelemetry: Equatable, Sendable` zawiera backend, `commandBufferCount`, `encoderCount`, `cacheHitCount`, `cacheResetCount`, `contactCount`, `didEncounterNonFinite`, `fallbackReason` i czas GPU.

- [ ] **Step 1: Napisać czerwone testy wyboru backendu i atomowego fallbacku.**

  W `NativeMetalWorldRunnerTests` dodaj testy `testNativeMetalIsDistinctBenchmarkBackend`, `testUnavailableNativeRuntimeFallsBackToWholeCPUFrame` i `testRejectedNativeFrameDoesNotPublishPartialState`. Pierwszy wymaga `.nativeMetal.rawValue == "native-metal"`; dwa pozostałe używają wstrzykniętego executora i porównują po fallbacku bańki oraz kontakty z kopią `world.step()`.

- [ ] **Step 2: Uruchomić testy red.**

  Run: `swift test --filter NativeMetalWorldRunnerTests`

  Expected: FAIL, ponieważ target i typy GPU-native nie istnieją.

- [ ] **Step 3: Dodać target, publiczne typy i runner z tylko bezpiecznym fallbackiem.**

  Dodaj produkt oraz pusty target `BubblePhysicsNativeMetal` zależny od `BubblePhysicsReference` i `BubblePhysicsNativeMetalTests`; zasoby shaderów dodaj dopiero razem z ich pierwszym plikiem w Task 2. Runner przy braku urządzenia/executora albo błędzie wykonuje dokładnie jedną pełną klatkę CPU z oryginalnego świata; jego region publikacji nie może zawierać `await`.

- [ ] **Step 4: Uruchomić testy green i istniejące kontrakty reference.**

  Run: `swift test --filter NativeMetalWorldRunnerTests && swift test --filter ReferenceMetalWorldRunnerTests`

  Expected: PASS; istniejący backend `.metal` pozostaje niezmieniony.

- [ ] **Step 5: Zacommitować kontrakt.**

  ```bash
  git add Package.swift Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkReport.swift Sources/BubblePhysicsNativeMetal Tests/BubblePhysicsNativeMetalTests
  git commit -m "feat: add native Metal backend contract"
  ```

### Task 2: Utrzymać trwałe zasoby i jeden command buffer klatki

**Files:**
- Modify: `Package.swift`
- Create: `Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- Create: `Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- Create: `Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- Modify: `Sources/BubblePhysicsNativeMetal/NativeMetalWorldRunner.swift`
- Create: `Tests/BubblePhysicsNativeMetalTests/NativeMetalSolverLifecycleTests.swift`

**Interfaces:**
- `NativeMetalSolver.executeFrame(snapshot: NativeMetalSnapshot, scenarioStep: Int) async throws -> NativeMetalWorldFrame` koduje jeden command buffer dla normalnej klatki.
- `NativeMetalSnapshot` pakuje tylko zmiany wejścia CPU; `NativeMetalPersistentState` przechowuje ping/pong baniek, kontakty cache i scratch między wywołaniami.
- `NativeMetalFrameProfile` raportuje `commandBufferCount`, `encoderCount`, `hostEncodingMilliseconds`, `hostWaitingMilliseconds` i czasy etapów.

- [ ] **Step 1: Napisać czerwone testy trwałości i harmonogramu.**

  W `NativeMetalSolverLifecycleTests` dodaj `testTwoFramesReusePersistentBuffers`, `testNormalFrameUsesExactlyOneCommandBuffer` i `testFailedCommandDoesNotReplacePublishedState`. Test z kontrolowanym executorem wymaga jednego `commit`, zera hostowych waitów między encoderami oraz zachowania poprzednio opublikowanej klatki po błędzie.

- [ ] **Step 2: Uruchomić testy red.**

  Run: `swift test --filter NativeMetalSolverLifecycleTests`

  Expected: FAIL — brak ABI i executora GPU-native.

- [ ] **Step 3: Zaimplementować ABI oraz lifecycle zasobów.**

  Dodaj pierwszy zasób shaderów do targetu w `Package.swift`. Zdefiniuj rekordy 16-bajtowo wyrównane dla baniek, segmentów, kontaktów cache, kontroli i pakietu renderowania. Kompiluj tylko `nativePredict` jako pierwszy pipeline; alokuj bufory z pojemnością rosnącą przed command bufferem. Jeden completion handler mierzy wynik, lecz nie steruje kolejnymi etapami.

- [ ] **Step 4: Uruchomić testy green.**

  Run: `swift test --filter NativeMetalSolverLifecycleTests && swift test --filter NativeMetalWorldRunnerTests`

  Expected: PASS; normalna klatka profilu raportuje `commandBufferCount == 1`.

- [ ] **Step 5: Zacommitować lifecycle.**

  ```bash
  git add Sources/BubblePhysicsNativeMetal Tests/BubblePhysicsNativeMetalTests
  git commit -m "feat: persist native Metal frame resources"
  ```

### Task 3: Zbudować stabilne kontakty, cache i broad phase

**Files:**
- Modify: `Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- Modify: `Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- Modify: `Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- Create: `Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- Create: `Tests/BubblePhysicsNativeMetalTests/NativeMetalContactCacheTests.swift`
- Create: `Tests/BubblePhysicsNativeMetalTests/NativeMetalBroadPhaseTests.swift`

**Interfaces:**
- `NativeContactKey` kanonizuje parę bubble–bubble albo bubble–segment bez utraty pełnego ID.
- `NativeContactCacheRecord` zawiera `key`, `lambda`, `age`, `lastSeenFrame` i `flags`.
- `NativeMetalConfiguration` używa `cacheExpiryFrames`, `teleportDistanceMultiplier` i `ccdVelocityMultiplier` bez wartości ukrytych w shaderze.

- [ ] **Step 1: Napisać czerwone testy kluczy i invalidacji cache.**

  W `NativeMetalContactCacheTests` dodaj: `testBubblePairKeyIsOrderIndependent`, `testContactExpiresAfterConfiguredMisses`, `testTeleportInvalidatesOnlyIncidentContactCache` oraz `testSegmentRevisionInvalidatesItsContacts`. W `NativeMetalBroadPhaseTests` dodaj `testGridCandidatesMatchBruteForceForSparseAndDenseWorlds` i `testCapacityOverflowRejectsFrameBeforePublication`.

- [ ] **Step 2: Uruchomić testy red.**

  Run: `swift test --filter NativeMetalContactCacheTests && swift test --filter NativeMetalBroadPhaseTests`

  Expected: FAIL — brak kluczy, cache i GPU siatki.

- [ ] **Step 3: Zaimplementować siatkę, kompaktację i dopasowanie cache.**

  `nativeBuildGrid` przypisuje bańki do komórek; `nativeEmitCandidates` emituje kanoniczne kandydaty; `nativeBuildContacts` tworzy kontakty i `nativeMatchContactCache` dopasowuje cache po posortowanym kluczu. Zachowaj stabilną kolejność kluczy, a overflow zgłaszaj przed publikacją. Teleport i rewizja segmentu ustawiają flagi invalidacji tylko dla dotkniętych rekordów.

- [ ] **Step 4: Uruchomić testy green oraz reference broad phase.**

  Run: `swift test --filter NativeMetalContactCacheTests && swift test --filter NativeMetalBroadPhaseTests && swift test --filter ReferenceBroadPhaseTests`

  Expected: PASS; brak utraty kandydatów względem CPU brute force.

- [ ] **Step 5: Zacommitować kontakty.**

  ```bash
  git add Sources/BubblePhysicsNativeMetal Tests/BubblePhysicsNativeMetalTests
  git commit -m "feat: add native Metal contact cache"
  ```

### Task 4: Rozwiązać kontakty metodą Jacobi XPBD/PBD z warm-startem

**Files:**
- Modify: `Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- Modify: `Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- Modify: `Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- Create: `Tests/BubblePhysicsNativeMetalTests/NativeMetalXPBDTests.swift`

**Interfaces:**
- `NativeMetalConfiguration.solverIterationCount` jest dodatni i jawnie raportowany w telemetryce.
- Kernels `nativeApplyWarmStart`, `nativeBuildAdjacency`, `nativeSolveJacobi` i `nativeUpdateVelocities` nie zapisują współdzielonej pozycji z wątku kontaktu.
- `NativeMetalWorldFrame` zawiera końcowe bańki, kontakty, `ReferenceWorldStepReport` zgodny z neutralnym formatem oraz telemetrykę native.

- [ ] **Step 1: Napisać czerwone testy solvera.**

  W `NativeMetalXPBDTests` dodaj `testTwoOverlappingBubblesSeparateWithoutNonFiniteState`, `testThreeBubbleChainIsRepeatableAndRaceFree`, `testWarmStartNeedsNoMoreIterationsThanColdStartAfterFirstFrame` oraz `testSameInputProducesSamePublishedStateHash`. Łańcuch trzech baniek wykonaj minimum 60 kroków; test nie porównuje współrzędnych 1:1 z CPU, lecz sprawdza rozdzielenie centrów, skończoność i hash.

- [ ] **Step 2: Uruchomić testy red.**

  Run: `swift test --filter NativeMetalXPBDTests`

  Expected: FAIL — brak XPBD i danych warm-start.

- [ ] **Step 3: Zaimplementować predykcję, warm-start i Jacobi.**

  Zastosuj cache lambda tylko po pomyślnym dopasowaniu. `nativeSolveJacobi` ma czytać pozycję wejściową iteracji, sumować wyłącznie kontakty incydentne bańki i zapisywać ping/pong bez atomików float. Po ostatniej iteracji aktualizuj prędkości oraz cache tylko z zatwierdzonego wyniku.

- [ ] **Step 4: Uruchomić testy green i kontrakty dynamiczne CPU.**

  Run: `swift test --filter NativeMetalXPBDTests && swift test --filter ReferenceDynamicAcceptanceTests`

  Expected: PASS; warm-start nie pogarsza liczby iteracji względem cold start w kontrolowanej scenie.

- [ ] **Step 5: Zacommitować solver.**

  ```bash
  git add Sources/BubblePhysicsNativeMetal Tests/BubblePhysicsNativeMetalTests
  git commit -m "feat: solve native Metal contacts with warm start"
  ```

### Task 5: Dodać przeszkody, selektywny CCD i guardy containment

**Files:**
- Modify: `Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- Modify: `Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- Create: `Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- Modify: `Sources/BubblePhysicsNativeMetal/NativeMetalWorldRunner.swift`
- Create: `Tests/BubblePhysicsNativeMetalTests/NativeMetalSafetyTests.swift`

**Interfaces:**
- Kernels `nativeFindFastCandidates`, `nativeResolveCCD`, `nativeApplyCenterGuards` i `nativeCheckFinite` działają przed publikacją.
- `NativeMetalFrameTelemetry` raportuje liczbę kandydatów CCD, guardów i invalidacji cache.
- Naruszenie guardu skutkuje pełnoklatkowym CPU fallbackiem z wejścia klatki.

- [ ] **Step 1: Napisać czerwone testy bezpieczeństwa.**

  W `NativeMetalSafetyTests` dodaj `testFastBubbleDoesNotCrossSegmentCenter`, `testMovingPolygonCannotContainBubbleCenter`, `testCCDInvalidatesIncidentWarmStart`, `testNonFiniteCandidateFallsBackWithoutPublication` oraz `testGuardFailureRerunsCPUFromOriginalWorld`.

- [ ] **Step 2: Uruchomić testy red.**

  Run: `swift test --filter NativeMetalSafetyTests`

  Expected: FAIL — brak etapów CCD/guardów GPU-native.

- [ ] **Step 3: Zaimplementować tylko selektywną trudną ścieżkę.**

  Kryterium szybkiego ruchu opiera się wyłącznie na `ccdVelocityMultiplier` i promieniu; nie uruchamiaj CCD dla wszystkich kontaktów. Dla segmentów, ścian i wielokątów stosuj test przejścia środka, wypchnięcie na dozwoloną stronę i reset cache incydentnego kontaktu. Wszystkie guardy zapisują status do kontrolnego bufora, który runner sprawdza przed publikacją.

- [ ] **Step 4: Uruchomić testy green.**

  Run: `swift test --filter NativeMetalSafetyTests && swift test --filter ReferenceDynamicAcceptanceTests`

  Expected: PASS; trudno ścieżka nie publikuje containment ani wyniku nie-skończonego.

- [ ] **Step 5: Zacommitować bezpieczeństwo.**

  ```bash
  git add Sources/BubblePhysicsNativeMetal Tests/BubblePhysicsNativeMetalTests
  git commit -m "feat: guard native Metal CCD and containment"
  ```

### Task 6: Wytwarzać elastyczne kontury z zatwierdzonego stanu GPU

**Files:**
- Modify: `Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- Modify: `Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- Modify: `Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- Create: `Tests/BubblePhysicsNativeMetalTests/NativeMetalContourTests.swift`

**Interfaces:**
- Kernels `nativeAccumulateContactPressure`, `nativeGenerateContours` i `nativePrepareRenderData` używają wyłącznie stanu po CCD/guardach.
- `NativeMetalWorldFrame.contours` i `.renderData` spełniają aktualny format `ReferenceMetalWorldFrame`/`ReferencePreparedBubble` bez CPU-owego ponownego generowania konturu dla udanej klatki GPU.

- [ ] **Step 1: Napisać czerwone testy deformacji i powrotu.**

  W `NativeMetalContourTests` dodaj `testContactFlattensContourAlongContactNormal`, `testReleasedContourReturnsWithinTwoPercentAfterThirtyFrames`, `testRestingContourDoesNotGainOscillationAmplitude` oraz `testPublishedRenderDataMatchesApprovedCenters`.

- [ ] **Step 2: Uruchomić testy red.**

  Run: `swift test --filter NativeMetalContourTests`

  Expected: FAIL — brak konturu GPU-native.

- [ ] **Step 3: Zaimplementować nacisk, napięcie i pakowanie renderowania.**

  Kontakt zapisuje lokalny nacisk kierunkowy, a kontur generuje punkty ograniczone przez przeszkody, napięcie powierzchniowe i wygładzanie. Po zniknięciu kontaktu wykładniczo wygaszaj wyłącznie jego deformację. Nie pobieraj punktów na CPU przed opublikowaniem klatki.

- [ ] **Step 4: Uruchomić testy green oraz istniejące testy konturu CPU.**

  Run: `swift test --filter NativeMetalContourTests && swift test --filter ContourGeneratorTests`

  Expected: PASS; kontur jest skończony, stabilny i zgodny z envelope specyfikacji.

- [ ] **Step 5: Zacommitować kontury.**

  ```bash
  git add Sources/BubblePhysicsNativeMetal Tests/BubblePhysicsNativeMetalTests
  git commit -m "feat: generate native Metal bubble contours"
  ```

### Task 7: Zintegrować benchmark i bramki jakości

**Files:**
- Modify: `Sources/BubblePhysicsNativeMetal/NativeMetalBackend.swift`
- Create: `Sources/BubblePhysicsNativeMetal/NativeMetalBenchmarkRunner.swift`
- Modify: `Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkRunner.swift`
- Modify: `Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkReport.swift`
- Modify: `Benchmarks/macOS/BubblePhysicsReferenceBench/main.swift`
- Modify: `Benchmarks/iOS/BubblePhysicsBench/App/ReferenceBenchmarkView.swift`
- Modify: `Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj/project.pbxproj`
- Create: `Tests/BubblePhysicsNativeMetalTests/NativeMetalBenchmarkTests.swift`
- Create: `Tests/BubblePhysicsNativeMetalTests/NativeMetalQualityEnvelopeTests.swift`

**Interfaces:**
- CLI i aplikacja akceptują backend `native-metal`, obok `cpu` i historycznego `metal`.
- Raport dodaje jednoznaczne pola `native_cache_hits`, `native_cache_resets`, `native_solver_iterations`, `native_ccd_candidates` i profil liczby command bufferów; nie przedstawia fallbacku CPU jako pomiaru GPU.
- `NativeMetalQualityEnvelope.evaluate(cpu:gpu:) -> [NativeMetalQualityViolation]` implementuje progi specyfikacji.

- [ ] **Step 1: Napisać czerwone testy raportu i envelope.**

  W `NativeMetalBenchmarkTests` dodaj `testNativeBenchmarkReportsOneCommandBufferAndNoFallback` oraz `testCPUFallbackIsExcludedFromNativeCompletedSamples`. W `NativeMetalQualityEnvelopeTests` dodaj przypadki graniczne dla p95/maksimum penetracji, containment, non-finite, jitteru i powtarzalnego hasha.

- [ ] **Step 2: Uruchomić testy red.**

  Run: `swift test --filter NativeMetalBenchmarkTests && swift test --filter NativeMetalQualityEnvelopeTests`

  Expected: FAIL — brak adaptera, pól raportu i evaluatorów.

- [ ] **Step 3: Dodać adapter benchmarkowy oraz kontrolę jakości.**

  Zintegruj `NativeMetalWorldRunner` przez istniejący `ReferenceBenchmarkRunner.measureAsync`; nie kopiuj scen ani formatu macierzy. Zaktualizuj wyłącznie selektor backendu i zależność produktu w projekcie iOS, bez modyfikowania ustawień podpisu. Wyświetlaj native telemetry jako techniczną diagnostykę, nie jako zastępstwo testów.

- [ ] **Step 4: Uruchomić testy, build i profil Maca.**

  Run: `swift test && swift run -c release BubblePhysicsReferenceBench --scene stress-300 --backend native-metal --limits 4 --warmup 5 --measured 30 && DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer xcodebuild -project Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj -scheme BubblePhysicsBench -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`

  Expected: wszystkie testy i unsigned build przechodzą; CLI raportuje `metal_frames > 0`, `fallbacks == 0` i pojedynczy command buffer na ukończoną klatkę. Wynik czasowy Maca nie jest akceptacją.

- [ ] **Step 5: Zacommitować harness.**

  ```bash
  git add Sources/BubblePhysicsNativeMetal Sources/BubblePhysicsReference Benchmarks/macOS Benchmarks/iOS Tests/BubblePhysicsNativeMetalTests Package.swift
  git commit -m "feat: benchmark native Metal bubble solver"
  ```

### Task 8: Przejść bramki urządzeniowe i udokumentować wynik

**Files:**
- Create: `docs/benchmarks/native-metal-bubble-solver-mac-YYYY-MM-DD.txt`
- Create: `docs/benchmarks/native-metal-bubble-solver-iphone-YYYY-MM-DD.txt`
- Create: `docs/benchmarks/native-metal-bubble-solver-YYYY-MM-DD.md`
- Modify: `README.md`

**Interfaces:**
- Surowe raporty są dosłownym tekstem CLI/aplikacji, bez ręcznego przepisywania metryk.
- Analiza rozdziela profil Maca, krótki smoke iPhone'a oraz końcową macierz iPhone'a; zawiera wynik `NativeMetalQualityEnvelope`.

- [ ] **Step 1: Wykonać automatyczne kontrole przed urządzeniem.**

  Run: `swift test && git diff --check && swift run -c release BubblePhysicsReferenceBench --scene interactive-24 --backend native-metal --limits 4 --warmup 30 --measured 300 && swift run -c release BubblePhysicsReferenceBench --scene stress-300 --backend native-metal --limits 4 --warmup 30 --measured 300`

  Expected: testy przechodzą, Mac ma rzeczywiste próbki native Metal bez fallbacków i raportuje envelope bez naruszeń.

- [ ] **Step 2: Wykonać krótki smoke Release na iPhonie X.**

  Uruchom przez Xcode 26.6 wyłącznie `interactive-24`, `native-metal`, limit 4, 30/30. Jeśli wystąpi fallback, hang, naruszenie envelope albo p95 nie jest wielokrotnie bliżej `10 ms` niż poprzedni backend, zatrzymaj bramkę i udokumentuj blokadę zamiast uruchamiać pełną macierz.

- [ ] **Step 3: Wykonać końcową macierz tylko po udanym smoke.**

  Na aktywnym ekranie iPhona uruchom `interactive-24` i `stress-300`, backend `native-metal`, limity `4/8/12/16`, 30 warmup / 300 measured. Zachowaj oba skopiowane raporty dosłownie. Każdy limit musi mieć `metal_frames == 330`, `fallbacks == 0` i przejść envelope.

- [ ] **Step 4: Napisać analizę oraz zaktualizować README.**

  Porównaj CPU reference, historyczny `metal` i `native-metal` dla czasu pełnej klatki, liczby command bufferów, cache hit/reset, penetracji, containment, non-finite oraz konturów. W README opisz wsparcie iOS 16+/macOS 13+, CPU fallback i że bramka 10 ms jest zmierzona tylko na konkretnym iPhonie X, jeśli zostanie osiągnięta.

- [ ] **Step 5: Zacommitować tylko potwierdzony wynik.**

  ```bash
  git add docs/benchmarks README.md
  git commit -m "docs: report native Metal bubble solver result"
  ```

## Self-review planu

- **Pokrycie specyfikacji:** Task 1 chroni izolację i fallback; Task 2 trwałe zasoby i jeden command buffer; Task 3 cache/siatkę; Task 4 solver Jacobi XPBD/PBD; Task 5 CCD/containment; Task 6 elastyczny kontur; Task 7 telemetrykę/envelope; Task 8 bramkę urządzeniową i dokumentację.
- **Spójność typów:** `.nativeMetal`, `NativeMetalConfiguration`, `NativeMetalWorldRunner`, `NativeMetalSolver`, `NativeMetalWorldFrame` i `NativeMetalQualityEnvelope` są wprowadzane przed każdym późniejszym użyciem.
- **Review focus:** wszystkie pięć ryzyk ma test w Tasks 2–6.
- **Zakres:** plan nie dotyka podpisu, nie usuwa starych backendów i nie uruchamia pełnej macierzy przed krótkim smoke urządzeniowym.
