# Reference Benchmark Convergence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zbudować deterministyczny benchmark pełnej klatki CPU dla 24 i 300 baniek, porównujący limity Newtona `4/8/12/16` pod względem czasu oraz jakości zbieżności.

**Architecture:** Nowy scenariusz benchmarkowy steruje światem i kinematycznym trójkątem wyłącznie numerem kroku. Solver raportuje zbieżność globalną i per komponent grafu kontaktów, a osobny wykonawca klatki mierzy symulację, generowanie konturów i przygotowanie danych renderowania. Runner pojedynczego przebiegu pozostaje bez zależności od SwiftUI; runner macierzy tworzy świeży świat dla każdego limitu, a aplikacja iOS jedynie steruje przebiegiem i prezentuje tekstowy raport.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, SwiftUI iOS 16+, `ContinuousClock`, istniejący `BubblePhysicsReference`.

**Spec:** `docs/superpowers/specs/2026-10-04-reference-benchmark-convergence-design.md`

## Global Constraints

- Sceny `interactive-24` i `stress-300` używają komory `375 × 700`, stałego seeda i trasy zależnej wyłącznie od numeru kroku.
- Macierz limitów Newtona ma kolejność `4`, `8`, `12`, `16`; każdy wariant zaczyna od świeżego świata.
- Limit PCG oraz parametry fizyki pozostają identyczne między wariantami.
- Baseline CPU obejmuje krok świata, kontury wszystkich baniek i przygotowanie render-ready danych, ale nie prezentację Metal.
- Próg `10 ms p95` jest informacją w raporcie urządzenia, nigdy asercją czasową testu macOS/CI.
- Benchmark nie implementuje GPU, adaptacyjnego limitu czasu ani strojenia fizyki.
- Benchmark asynchroniczny reaguje na anulowanie i nie publikuje częściowego raportu jako ukończonego.

## Review Focus

- `measuredSteps == 0`: raport ma zawierać zera i nie generować `NaN` ani błędnych percentyli — test w Task 4.
- Zbieżność komponentu zawierającego wyłącznie kontakt bańka–odcinek: komponent ma być liczony, mimo braku `bubbleB` — test w Task 2.
- Dwie niezależne wyspy kontaktów o różnej jakości: raport ma policzyć tylko niezbieżną wyspę — test w Task 2.
- Anulowanie podczas rozgrzewki i podczas pomiaru: oba przypadki kończą się `CancellationError` bez kompletnego wyniku — test w Task 5.
- Powtórne uruchomienie UI po zatrzymaniu: stary task nie może nadpisać postępu ani raportu nowego przebiegu — test logiki modelu w Task 6.

---

### Task 1: Deterministyczne sceny i rzeczywisty limit Newtona

**Files:**
- Create: `Sources/BubblePhysicsReference/Benchmark/ReferenceConvergenceScenario.swift`
- Modify: `Sources/BubblePhysicsReference/Model/ReferenceConfiguration.swift:25-31`
- Modify: `Sources/BubblePhysicsReference/Solver/ReferenceEquilibriumSolver.swift:18`
- Test: `Tests/BubblePhysicsReferenceTests/ReferenceConvergenceScenarioTests.swift`
- Test: `Tests/BubblePhysicsReferenceTests/ReferenceEquilibriumSolverTests.swift`

**Interfaces:**
- Produces: `public enum ReferenceConvergenceScene: String, Sendable, CaseIterable { case interactive24; case stress300 }`.
- Produces: `public struct ReferenceConvergenceScenario: Sendable, Equatable` z polami `scene`, `seed`, `newtonIterationLimit`, `broadPhase`.
- Produces: `makeWorld() throws -> ReferenceWorld`, `polygonCenter(atStep:) -> ReferenceVector2` i `updatePolygon(in:fromStep:toStep:)`.
- Preserves: domyślne zachowanie produkcyjne odpowiadające dotychczasowym czterem iteracjom Newtona.

- [ ] **Step 1: Write failing scenario and solver-limit tests**

Dodaj testy:

```swift
func testConvergenceScenesBuildExpectedDeterministicWorlds()
func testPolygonTrajectoryDependsOnlyOnStepNumber()
func testFreshWorldsForEveryLimitStartIdenticallyApartFromConfiguration()
func testSolverHonorsConfiguredNewtonLimitAboveFour()
func testDefaultConfigurationPreservesFourIterationBehavior()
```

Asercje: sceny mają odpowiednio `24` i `300` baniek, cztery ściany i trzy odcinki jednego właściciela; dwa światy z tym samym seedem są równe; centra trójkąta dla kroków `0`, `1`, `120` są identyczne między wywołaniami; raport solvera dla wymuszonego trudnego układu może wykonać więcej niż cztery iteracje przy limicie `8`; domyślny limit wynosi `4`.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter ReferenceConvergenceScenarioTests && swift test --filter ReferenceEquilibriumSolverTests/testSolverHonorsConfiguredNewtonLimitAboveFour`

Expected: FAIL, ponieważ typ scenariusza nie istnieje, a solver twardo ogranicza Newtona do czterech iteracji.

- [ ] **Step 3: Implement deterministic scenario and explicit limit semantics**

W `ReferenceConfiguration` ustaw domyślne `solverIterations` na `4`. W `ReferenceEquilibriumSolver.solve` użyj `max(1, config.solverIterations)` bez twardego `min(4, ...)`. W scenariuszu buduj oba światy ze stałym rozkładem wartości/promieni, ścianami one-sided i jednym zamkniętym trójkątem two-sided; aktualizuj wszystkie trzy krawędzie w jednym kroku na podstawie pary kolejnych pozycji trasy.

- [ ] **Step 4: Run focused tests and full reference suite**

Run: `swift test --filter ReferenceConvergenceScenarioTests && swift test --filter BubblePhysicsReferenceTests`

Expected: PASS; brak regresji dotychczasowego zachowania przy domyślnych czterech iteracjach.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysicsReference/Benchmark/ReferenceConvergenceScenario.swift Sources/BubblePhysicsReference/Model/ReferenceConfiguration.swift Sources/BubblePhysicsReference/Solver/ReferenceEquilibriumSolver.swift Tests/BubblePhysicsReferenceTests/ReferenceConvergenceScenarioTests.swift Tests/BubblePhysicsReferenceTests/ReferenceEquilibriumSolverTests.swift
git commit -m "feat: add deterministic convergence scenarios"
```

### Task 2: Zbieżność per komponent kontaktowy

**Files:**
- Modify: `Sources/BubblePhysicsReference/Solver/ReferenceResidualComponents.swift`
- Modify: `Sources/BubblePhysicsReference/Solver/ReferenceSolverReport.swift`
- Modify: `Sources/BubblePhysicsReference/Solver/ReferenceEquilibriumSolver.swift`
- Modify: `Sources/BubblePhysicsReference/Solver/ReferenceWorld.swift`
- Test: `Tests/BubblePhysicsReferenceTests/ReferenceResidualComponentsTests.swift`
- Test: `Tests/BubblePhysicsReferenceTests/ReferenceEquilibriumSolverTests.swift`

**Interfaces:**
- Consumes: aktywne `[ReferenceContact]`, indeksy baniek i końcowy `[ReferenceVector2]` reszty.
- Produces: `ReferenceResidualComponents.summary(residual:contacts:indices:tolerance:) -> ReferenceResidualComponentSummary`.
- Produces: `struct ReferenceResidualComponentSummary: Sendable, Equatable { componentCount: Int; unconvergedCount: Int; maximumNorm: Float }`.
- Extends: `ReferenceSolverReport` o `contactComponentCount`, `unconvergedContactComponentCount`, `maximumComponentResidualNorm`.

- [ ] **Step 1: Write failing component-summary tests**

Dodaj testy z ręcznie podanymi wektorami reszty:

```swift
func testSummaryCountsOnlyUnconvergedIndependentIsland()
func testSummaryIncludesBubbleSegmentOnlyComponent()
func testSummaryReturnsZerosWithoutContacts()
func testEquilibriumReportPublishesFinalComponentQuality()
```

Pierwszy fixture ma dwie rozłączne pary baniek; jedna suma kwadratów reszty jest poniżej tolerancji, druga powyżej. Drugi fixture ma pojedynczy kontakt bańka–odcinek i resztę powyżej tolerancji.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter ReferenceResidualComponentsTests && swift test --filter ReferenceEquilibriumSolverTests/testEquilibriumReportPublishesFinalComponentQuality`

Expected: FAIL, ponieważ summary i pola raportu nie istnieją.

- [ ] **Step 3: Implement shared component partition and final quality report**

Wydziel wspólną deterministyczną partycję union-find używaną przez `improvingBubbleIndices` i `summary`. Do partycji włącz kontakt bańka–odcinek jako jednoelementowy komponent. Normę komponentu licz jako pierwiastek sumy `lengthSquared` reszt należących baniek. `ReferenceEquilibriumSolver` wylicza summary wyłącznie dla finalnego systemu i finalnych kontaktów; `ReferenceWorld.merge` zachowuje maksymalną liczbę komponentów, maksymalną liczbę niezbieżnych komponentów i maksymalną normę spośród podkroków.

- [ ] **Step 4: Run focused and reference tests**

Run: `swift test --filter ReferenceResidualComponentsTests && swift test --filter BubblePhysicsReferenceTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysicsReference/Solver/ReferenceResidualComponents.swift Sources/BubblePhysicsReference/Solver/ReferenceSolverReport.swift Sources/BubblePhysicsReference/Solver/ReferenceEquilibriumSolver.swift Sources/BubblePhysicsReference/Solver/ReferenceWorld.swift Tests/BubblePhysicsReferenceTests/ReferenceResidualComponentsTests.swift Tests/BubblePhysicsReferenceTests/ReferenceEquilibriumSolverTests.swift
git commit -m "feat: report contact component convergence"
```

### Task 3: Pełna klatka CPU i wykrywanie długiego zawarcia

**Files:**
- Create: `Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkFrame.swift`
- Create: `Sources/BubblePhysicsReference/Benchmark/ReferenceContainmentTracker.swift`
- Test: `Tests/BubblePhysicsReferenceTests/ReferenceBenchmarkFrameTests.swift`
- Test: `Tests/BubblePhysicsReferenceTests/ReferenceContainmentTrackerTests.swift`

**Interfaces:**
- Consumes: `ReferenceConvergenceScenario`, bieżący `ReferenceWorld` i numer kroku.
- Produces: `ReferenceBenchmarkFrame.run(world:scenario:step:) -> ReferenceBenchmarkFrameResult`.
- Produces: `ReferenceBenchmarkFrameResult` z `worldReport`, `simulationMilliseconds`, `contourMilliseconds`, `renderPreparationMilliseconds`, `fullFrameMilliseconds`, `contourPointCount`.
- Produces: `ReferencePreparedBubble` zawierający `id`, `center`, `rotation`, `contour`; tablica tych rekordów jest render-ready danymi CPU.
- Produces: `ReferenceContainmentTracker.observe(_ bubbles: [ReferenceBubble])` oraz `maximumConsecutiveFrames`.

- [ ] **Step 1: Write failing frame and containment tests**

Dodaj testy:

```swift
func testFrameAdvancesDeterministicPolygonAndPreparesEveryContour()
func testFullFrameTimingContainsSimulationContourAndPreparation()
func testRepeatedIdenticalRunsProduceEqualPhysicsAndGeometry()
func testTrackerCountsConsecutiveFullContainmentAndResetsAfterSeparation()
func testTrackerIgnoresOrdinaryOverlap()
```

Asercje czasu ogranicz do skończoności, nieujemności i `fullFrame >= simulation`; nie porównuj wartości zegara między uruchomieniami. Dla trackera użyj literalnych środków/promieni dających sekwencję `contained, contained, separated`, oczekując maksimum `2`.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter ReferenceBenchmarkFrameTests && swift test --filter ReferenceContainmentTrackerTests`

Expected: FAIL, ponieważ nowe typy nie istnieją.

- [ ] **Step 3: Implement frame runner and tracker**

`ReferenceBenchmarkFrame.run` najpierw aktualizuje wielokąt dla `step -> step + 1`, następnie mierzy `world.step()`, potem generuje wszystkie kontury i buduje `ReferencePreparedBubble`. Użyj `ContinuousClock`; czasy faz nie mogą się nakładać. Tracker uznaje pełne zawarcie, gdy `distance + minRadius < maxRadius - positionTolerance`, i przechowuje licznik per uporządkowana para ID, aby równoległe pary nie sklejały się w jedną serię.

- [ ] **Step 4: Run focused and reference tests**

Run: `swift test --filter ReferenceBenchmarkFrameTests && swift test --filter ReferenceContainmentTrackerTests && swift test --filter BubblePhysicsReferenceTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkFrame.swift Sources/BubblePhysicsReference/Benchmark/ReferenceContainmentTracker.swift Tests/BubblePhysicsReferenceTests/ReferenceBenchmarkFrameTests.swift Tests/BubblePhysicsReferenceTests/ReferenceContainmentTrackerTests.swift
git commit -m "feat: measure complete reference frames"
```

### Task 4: Raport pojedynczego przebiegu

**Files:**
- Modify: `Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkReport.swift`
- Modify: `Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkRunner.swift`
- Test: `Tests/BubblePhysicsReferenceTests/ReferenceBenchmarkTests.swift`

**Interfaces:**
- Consumes: `ReferenceBenchmarkFrameResult` z Task 3.
- Produces: `ReferenceTimingSummary { p50Milliseconds; p95Milliseconds; maximumMilliseconds }`.
- Produces: `ReferenceScalarSummary { p50; p95; maximum }` dla penetracji i norm reszty.
- Extends: `ReferenceBenchmarkReport` o wersję benchmarku, limit Newtona, `fullFrame`, `contour`, `renderPreparation`, summaries jakości, komponenty, iteracje, zawarcie i wszystkie parametry przebiegu.
- Preserves: istniejące `measure` i `measureAsync` dla `ReferenceBenchmarkScenario`; dodaje równoległe overloady przyjmujące `ReferenceConvergenceScenario`, żeby dotychczasowe testy broad phase i mikrobenchmarki pozostały dostępne.

- [ ] **Step 1: Write failing aggregation tests**

Dodaj testy:

```swift
func testTimingSummaryUsesLiteralNearestRankP50P95AndMaximum()
func testMeasuredReportAggregatesContourQualityAndContainment()
func testZeroMeasuredStepsProducesFiniteZeroSummaries()
func testReportRecordsEveryConfigurationValueNeededForComparison()
```

Dla próbek `[1, 2, 3, 100]` oczekuj nearest-rank `p50 == 2`, `p95 == 100`, `maximum == 100`. Dla zera próbek wszystkie wartości mają wynosić `0`.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter ReferenceBenchmarkTests`

Expected: FAIL z powodu brakujących pól i nowego wejścia scenariusza.

- [ ] **Step 3: Implement single-run aggregation**

Usuń duplikację synchronicznej i asynchronicznej agregacji przez jeden prywatny builder raportu. Warmup wykonuje tę samą pełną klatkę, ale nie zapisuje próbek. Mierzony przebieg aktualizuje tracker zawarcia po każdej klatce. Raportuje maksima liczników oraz percentyle wartości per-frame; wszystkie kolekcje filtrują wartości niefinitywne, a obecność takiej wartości ustawia `hasNonFiniteState`.

- [ ] **Step 4: Run focused and reference tests**

Run: `swift test --filter ReferenceBenchmarkTests && swift test --filter BubblePhysicsReferenceTests`

Expected: PASS bez progów czasowych.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkReport.swift Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkRunner.swift Tests/BubblePhysicsReferenceTests/ReferenceBenchmarkTests.swift
git commit -m "feat: report benchmark time and quality"
```

### Task 5: Runner macierzy i anulowanie

**Files:**
- Create: `Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkMatrix.swift`
- Modify: `Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkReport.swift`
- Test: `Tests/BubblePhysicsReferenceTests/ReferenceBenchmarkMatrixTests.swift`

**Interfaces:**
- Consumes: `ReferenceBenchmarkRunner.measureAsync` z Task 4.
- Produces: `ReferenceBenchmarkMatrixConfiguration(scene:warmupSteps:measuredSteps:iterationLimits:)`, którego domyślne limity to `[4, 8, 12, 16]`.
- Produces: `ReferenceBenchmarkMatrixRunner.measure(configuration:progress:) async throws -> ReferenceBenchmarkMatrixReport`.
- Produces: callback postępu `@Sendable (ReferenceBenchmarkProgress) async -> Void` zawierający indeks wariantu, limit, ukończone kroki i wszystkie kroki.
- Produces: `ReferenceBenchmarkMatrixReport.runs` uporządkowane dokładnie jak wejściowe limity oraz `plainText(deviceName:systemVersion:) -> String`.

- [ ] **Step 1: Write failing matrix tests**

Dodaj testy:

```swift
func testDefaultMatrixRunsFreshWorldsInFourEightTwelveSixteenOrder() async throws
func testProgressIsMonotonicAcrossWholeMatrix() async throws
func testCancellationDuringWarmupThrowsWithoutMatrixReport() async
func testCancellationDuringMeasuredFramesThrowsWithoutMatrixReport() async
func testPlainTextContainsDeviceScenarioLimitsAndTimeQualityColumns() throws
```

Do testów anulowania dodaj wewnętrzny injectable runner closure zamiast opóźnień zegarowych; closure wywołuje `Task.checkCancellation()` na kontrolowanej granicy kroku.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter ReferenceBenchmarkMatrixTests`

Expected: FAIL, ponieważ runner macierzy nie istnieje.

- [ ] **Step 3: Implement sequential fresh-world matrix**

Macierz uruchamia warianty sekwencyjnie, aby nie konkurowały o CPU. Każde wywołanie tworzy nowy `ReferenceConvergenceScenario` z tym samym scene/seed/broad phase i innym limitem. `plainText` używa stałej kolejności kolumn oraz kropki jako separatora dziesiętnego, aby raporty dało się porównywać tekstowo.

- [ ] **Step 4: Run focused and reference tests**

Run: `swift test --filter ReferenceBenchmarkMatrixTests && swift test --filter BubblePhysicsReferenceTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkMatrix.swift Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkReport.swift Tests/BubblePhysicsReferenceTests/ReferenceBenchmarkMatrixTests.swift
git commit -m "feat: run convergence benchmark matrix"
```

### Task 6: Ekran benchmarku iOS i końcowa weryfikacja

**Files:**
- Modify: `Benchmarks/iOS/BubblePhysicsBench/App/ReferenceBenchmarkView.swift`
- Create: `Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkPresentation.swift`
- Create: `Tests/BubblePhysicsReferenceTests/ReferenceBenchmarkPresentationTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: `ReferenceBenchmarkMatrixRunner`, `ReferenceBenchmarkProgress`, `ReferenceBenchmarkMatrixReport`.
- Produces: `@MainActor public final class ReferenceBenchmarkPresentation: ObservableObject` z injectable async runner closure, generation tokenem i stanem `scene`, `mode`, `selectedLimit`, `progress`, `reportText`, `errorMessage`, `isRunning`.
- Produces: ekran z wyborem `24/300`, trybem pojedynczy limit/cała macierz, wyborem limitu dla pojedynczego przebiegu, postępem, Start/Stop i kopiowalnym raportem.
- Preserves: UI pozostaje responsywne; nowy start anuluje i unieważnia poprzedni task przez generation token.

- [ ] **Step 1: Write failing presentation-state tests**

Dodaj testy:

```swift
func testStoppingRunPreventsLateResultPublication() async
func testStartingAgainIgnoresProgressFromPreviousGeneration() async
func testCompletedMatrixPublishesCopyableReportAndStopsProgress() async
```

Testuj wyodrębnioną logikę stanu z kontrolowanymi closure’ami runnera; nie testuj SwiftUI przez snapshot ani mock widoku.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter ReferenceBenchmarkPresentationTests`

Expected: FAIL, ponieważ generation token i stan macierzy nie istnieją.

- [ ] **Step 3: Implement benchmark controls and report view**

Zastąp wybór `40/300/1000` wyborem `24/300`; pozostaw broad phase tylko jeśli raport nadal porównuje oba warianty, w przeciwnym razie ustaw zatwierdzony sweep-and-prune bez kontrolki. Tabela pokazuje po jednym wierszu na limit z `full p50/p95/max`, `solver p95`, `contour p95`, penetracją p95/max, końcową resztą p95/max, niezbieżnymi komponentami, zawarciem i `non-finite`. Tekst raportu ma `.textSelection(.enabled)` oraz przycisk kopiowania przez `UIPasteboard`.

- [ ] **Step 4: Document device procedure**

W `README.md` dodaj komendę builda, ścieżkę w aplikacji, obowiązek uruchomienia Release na fizycznym iPhonie, kroki `warmup/measured`, roboczy budżet `10 ms p95` i format wyniku przekazywanego do decyzji GPU.

- [ ] **Step 5: Run complete verification**

Run:

```bash
swift test
xcodebuild -project Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj -scheme BubblePhysicsBench -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
git diff --check
```

Expected: wszystkie testy przechodzą z wyjątkiem jawnie opcjonalnego benchmarku drukowanego; `** BUILD SUCCEEDED **`; `git diff --check` bez wyjścia.

- [ ] **Step 6: Prepare the physical-device handoff**

Przekaż CEO instrukcję: na fizycznym iPhonie uruchomić Release dla obu scen i pełnej macierzy, a następnie wkleić dwa raporty tekstowe. Po otrzymaniu wyników zapisać surowy raport w `docs/benchmarks/reference-convergence-<device>-2026-10-04.txt` oraz wnioski w `docs/benchmarks/reference-convergence-2026-10-04.md`. Nie podejmować decyzji GPU bez danych z urządzenia.

- [ ] **Step 7: Commit implementation**

```bash
git add Benchmarks/iOS/BubblePhysicsBench Sources/BubblePhysicsReference/Benchmark Tests/BubblePhysicsReferenceTests README.md
git commit -m "feat: add iOS convergence benchmark"
```

Raport urządzenia dostaje osobny commit `docs: record convergence benchmark baseline` dopiero po przekazaniu danych przez CEO.
