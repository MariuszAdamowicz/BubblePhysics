# Wielobańkowy świat radialny GPU — plan implementacji

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zbudować wielobańkowy radialny świat GPU z adaptacyjnym `N`, segmentowymi kontaktami oraz sceną 12–20 baniek do oceny fizyki na iPhonie X.

**Architecture:** Stan świata będzie przechowywał wiele centralnych korpusów oraz płaskie, ciągłe zakresy czujników. CPU dostarczy referencyjną geometrię kontaktów i remeshing, a Metal wykona predykcję, broad phase, kontakty, redukcję i integrację w buforach świata. Renderer i aplikacja będą konsumowały jeden snapshot klatki bez osobnych kopii modelu.

**Tech Stack:** Swift 5, Swift Package Manager, XCTest, Metal compute/render, SwiftUI + MetalKit, Xcode 26.6, iOS 16+.

**Spec:** `docs/superpowers/specs/2026-10-01-multi-bubble-radial-world-design.md`

## Global Constraints

- Każda bańka ma dokładnie jeden masowy korpus i bezmasowe radialne czujniki.
- Liczba czujników wynika z obwodu oraz `maxSegmentLength`; model domenowy nie ma arbitralnego maksimum `N`.
- Kontakty działają na segmentach i rozdzielają kompresję barycentrycznie.
- Reakcja bańka–bańka jest symetryczna i bez zewnętrznej siły zachowuje sumaryczny pęd liniowy.
- Redukcja GPU jest deterministyczna względem kolejności baniek i kontaktów.
- Brak zasobów, overflow i non-finite są jawnymi błędami; nie obniżamy cicho jakości.
- Docelową platformą weryfikacji jest fizyczny iPhone X; zgodność z macOS nie jest wymaganiem produktu.
- Legacy tryby `40` i `300` pozostają dostępne do porównania.

## Review Focus

- Wielokąt całkowicie wewnątrz dużej bańki musi wygenerować kontakt zamiast pozostać niewidoczny — Task 3, `testPolygonContainedByBubbleProducesContact`.
- Dwie bańki o skrajnie różnych rozmiarach muszą zostać wykryte także bez przecięcia odpowiadających sobie indeksów — Task 4, `testSmallBubbleContainedByLargeBubbleProducesContacts`.
- Remeshing kilku baniek w tej samej klatce nie może pomieszać zakresów ani stanów — Task 2, `testConcurrentGrowthRebuildsContiguousRangesWithoutCrossTalk`.
- Szybki obiekt kinematyczny nie może przeskoczyć konturu między klatkami — Task 7, `testSweptTriangleCannotTunnelThroughBubble`.
- Brak pamięci podczas przebudowy buforów musi zachować poprzednią gotową klatkę albo zakończyć sesję jawnym błędem — Task 5, `testFailedWorldReallocationDoesNotPublishPartialLayout`.

---

### Task 1: Model domenowy wielobańkowego świata

**Files:**
- Create: `Sources/BubblePhysics/RadialWorldState.swift`
- Create: `Tests/BubblePhysicsTests/RadialWorldStateTests.swift`

**Interfaces:**
- Consumes: `RadialBubbleState`, `BubbleID`.
- Produces: `RadialBubbleRange { bubbleIndex, sensorStart, sensorCount }` oraz `RadialWorldState.init(bubbles:)`, `ranges`, `totalSensorCount`, `bubble(for:)`.

- [ ] **Step 1: Write failing model tests**

Dodaj `testWorldBuildsStableContiguousRanges`, `testWorldRejectsDuplicateBubbleIDs` i `testLookupUsesStableBubbleID`. Sprawdź dokładne początki zakresów dla baniek o 8, 13 i 257 czujnikach.

- [ ] **Step 2: Run RED**

Run: `swift test --filter RadialWorldStateTests`

Expected: compile failure because `RadialWorldState` does not exist.

- [ ] **Step 3: Implement the domain model**

`public struct RadialWorldState: Equatable, Sendable` przechowuje `[RadialBubbleState]`, wymusza unikalne ID i wylicza ciągłe zakresy w kolejności tablicy.

- [ ] **Step 4: Run GREEN and regression**

Run: `swift test --filter RadialWorldStateTests && swift test --skip BenchmarkScenarioTests`

Expected: all selected tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysics/RadialWorldState.swift Tests/BubblePhysicsTests/RadialWorldStateTests.swift
git commit -m "feat: add multi-bubble radial world state"
```

### Task 2: Remeshing całego świata z histerezą

**Files:**
- Create: `Sources/BubblePhysics/RadialWorldRemesher.swift`
- Modify: `Sources/BubblePhysics/RadialSensorRemesher.swift`
- Create: `Tests/BubblePhysicsTests/RadialWorldRemesherTests.swift`

**Interfaces:**
- Consumes: `RadialWorldState`, `RadialSensorRemesher.resample(_:to:)`.
- Produces: `RadialRemeshPolicy(upperSegmentLengthRatio: 1.0, lowerSegmentLengthRatio: 0.65, cooldownFrames: 15)`, `RadialRemeshDecision`, `RadialWorldRemesher.plan(world:policy:frameIndex:)` i `apply(_:to:)`.

- [ ] **Step 1: Write failing remeshing tests**

Dodaj `testGrowingBubbleAddsSensorsBeforeUpperThresholdIsExceeded`, `testHysteresisPreventsCountOscillation`, `testRemeshPreservesBodyMomentumAndMeanSurfaceState` oraz `testConcurrentGrowthRebuildsContiguousRangesWithoutCrossTalk`.

- [ ] **Step 2: Run RED**

Run: `swift test --filter RadialWorldRemesherTests`

Expected: compile failure for missing world remesher types.

- [ ] **Step 3: Implement planning and atomic apply**

Polityka zawiera `upperSegmentLengthRatio`, `lowerSegmentLengthRatio` i `cooldownFrames`. `plan` jest czysty i deterministyczny; `apply` tworzy kompletny nowy `RadialWorldState` bez częściowej mutacji.

- [ ] **Step 4: Run GREEN and regression**

Run: `swift test --filter RadialWorldRemesherTests && swift test --skip BenchmarkScenarioTests`

Expected: all selected tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysics/RadialWorldRemesher.swift Sources/BubblePhysics/RadialSensorRemesher.swift Tests/BubblePhysicsTests/RadialWorldRemesherTests.swift
git commit -m "feat: remesh radial world with hysteresis"
```

### Task 3: Referencyjne segmentowe kontakty środowiska

**Files:**
- Create: `Sources/BubblePhysics/RadialSegmentGeometry.swift`
- Replace internals: `Sources/BubblePhysics/RadialEnvironmentContacts.swift`
- Modify: `Tests/BubblePhysicsTests/RadialEnvironmentContactTests.swift`

**Interfaces:**
- Consumes: `RadialBubbleState`, `SimulationPolygonSnapshot`, `AABB`.
- Produces: `RadialSegmentGeometry.intersection(_:_:) -> RadialSegmentIntersection?`, `nearestPoints(_:_:) -> RadialSegmentSeparation`, `contains(_:contour:) -> Bool` oraz niezmienione publiczne `RadialEnvironmentContacts.generate(bubble:bounds:polygons:)` z barycentrycznymi kontaktami.

- [ ] **Step 1: Write failing geometry tests**

Dodaj `testPolygonEdgeCrossingBetweenSensorsProducesContact`, `testPolygonContainedByBubbleProducesContact`, `testWallContactIsDistributedBarycentrically` i `testMovingPolygonRelativeVelocityUsesContactPoint`.

- [ ] **Step 2: Run RED**

Run: `swift test --filter RadialEnvironmentContactTests`

Expected: at least crossing/containment assertions fail against point-only generation.

- [ ] **Step 3: Implement segment-level environment contacts**

Generuj stabilnie uporządkowane kontakty dla przecięć, zawierania i ścian. `sensorStartIndex`, `sensorEndIndex` oraz `barycentric` wskazują rzeczywiste położenie na segmencie.

- [ ] **Step 4: Run GREEN and regression**

Run: `swift test --filter RadialEnvironmentContactTests && swift test --skip BenchmarkScenarioTests`

Expected: all selected tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysics/RadialSegmentGeometry.swift Sources/BubblePhysics/RadialEnvironmentContacts.swift Tests/BubblePhysicsTests/RadialEnvironmentContactTests.swift
git commit -m "fix: detect radial segment environment contacts"
```

### Task 4: Broad phase i kontakty bańka–bańka na CPU

**Files:**
- Create: `Sources/BubblePhysics/RadialBubbleBroadPhase.swift`
- Create: `Sources/BubblePhysics/RadialBubbleContacts.swift`
- Create: `Tests/BubblePhysicsTests/RadialBubbleContactTests.swift`

**Interfaces:**
- Consumes: `RadialWorldState`, `RadialSegmentGeometry`.
- Produces: `RadialBubblePair`, `RadialBubbleBroadPhase.candidates(in:deltaTime:) -> [RadialBubblePair]`, `RadialBubblePairContact`, `RadialBubblePairLoads { first: RadialBodyLoad, second: RadialBodyLoad }` oraz `RadialBubbleContacts.generate(first:second:)` i `reduce(contacts:first:second:) -> RadialBubblePairLoads`.

- [ ] **Step 1: Write failing pair tests**

Dodaj `testBroadPhaseReturnsOnlyOverlappingSweptAABBsInStableOrder`, `testCrossingSegmentsProduceBarycentricPairContact`, `testSmallBubbleContainedByLargeBubbleProducesContacts`, `testPairLoadsAreEqualAndOpposite` oraz `testPairLoadDoesNotCreateNetLinearMomentum`.

- [ ] **Step 2: Run RED**

Run: `swift test --filter RadialBubbleContactTests`

Expected: compile failure for missing pair APIs.

- [ ] **Step 3: Implement sweep-and-prune and symmetric response**

Sortuj po minimalnym X, użyj stabilnego ID do rozstrzygania remisów i testuj Y przed narrow phase. Zredukuj każdy kontakt do dwóch `RadialBodyLoad` z przeciwnymi siłami.

- [ ] **Step 4: Run GREEN and regression**

Run: `swift test --filter RadialBubbleContactTests && swift test --skip BenchmarkScenarioTests`

Expected: all selected tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysics/RadialBubbleBroadPhase.swift Sources/BubblePhysics/RadialBubbleContacts.swift Tests/BubblePhysicsTests/RadialBubbleContactTests.swift
git commit -m "feat: add radial bubble pair contacts"
```

### Task 5: Bufory i bezkontaktowa dynamika świata Metal

**Files:**
- Create: `Sources/BubblePhysicsMetal/Radial/MetalRadialWorldBufferLayout.swift`
- Create: `Sources/BubblePhysicsMetal/Radial/MetalRadialWorldSimulation.swift`
- Create: `Sources/BubblePhysicsMetal/Shaders/RadialWorldKernels.metal`
- Modify: `Package.swift`
- Create: `Tests/BubblePhysicsMetalTests/MetalRadialWorldSimulationTests.swift`

**Interfaces:**
- Consumes: `RadialWorldState`, `RadialBubbleRange`, remesh decisions from Task 2.
- Produces: `MetalBufferAllocator.makeBuffer(device:length:options:)`, `MetalRadialWorldSimulation.init(device:world:allocator:)` z domyślnym alokatorem, `encodeFreeStep(deltaTime:commandBuffer:)`, `complete(frame:commandBuffer:)`, `world`, `status: MetalRadialWorldStatus` oraz `MetalRadialWorldFrameResources` zawierające bufory korpusów, deskryptorów, czujników, punktów powierzchni i zakresów.

- [ ] **Step 1: Write failing buffer/world tests**

Dodaj `testPackedWorldPreservesBodyAndSensorRanges`, `testFreeGPUWorldMatchesCPUForMultipleBubbles`, `testFrameBoundaryRemeshAtomicallyReplacesRanges` i `testFailedWorldReallocationDoesNotPublishPartialLayout`. Użyj wstrzykiwanego `MetalBufferAllocator`, którego testowa implementacja odmawia wskazanej alokacji.

- [ ] **Step 2: Run RED**

Run: `swift test --filter MetalRadialWorldSimulationTests`

Expected: compile failure for missing world simulation.

- [ ] **Step 3: Implement packed buffers and free kernels**

Kernele przyjmują deskryptory zakresów i indeksują dowolną liczbę baniek. Publikacja nowych buforów następuje dopiero po udanej alokacji oraz kopiowaniu całego layoutu.

- [ ] **Step 4: Run GREEN and regression**

Run: `swift test --filter MetalRadialWorldSimulationTests && swift test --skip BenchmarkScenarioTests`

Expected: all selected tests pass.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/BubblePhysicsMetal/Radial/MetalRadialWorldBufferLayout.swift Sources/BubblePhysicsMetal/Radial/MetalRadialWorldSimulation.swift Sources/BubblePhysicsMetal/Shaders/RadialWorldKernels.metal Tests/BubblePhysicsMetalTests/MetalRadialWorldSimulationTests.swift
git commit -m "feat: simulate packed radial world on Metal"
```

### Task 6: Kontakty środowiska w świecie Metal

**Files:**
- Create: `Sources/BubblePhysicsMetal/Shaders/RadialWorldEnvironmentKernels.metal`
- Modify: `Sources/BubblePhysicsMetal/Radial/MetalRadialWorldSimulation.swift`
- Modify: `Sources/BubblePhysicsMetal/Radial/MetalRadialWorldBufferLayout.swift`
- Modify: `Package.swift`
- Create: `Tests/BubblePhysicsMetalTests/MetalRadialWorldEnvironmentTests.swift`

**Interfaces:**
- Consumes: CPU reference from Task 3 and frame resources from Task 5.
- Produces: `encodeStep(bounds:polygons:deltaTime:commandBuffer:)` with segment contacts, contact counts, maximum penetration and overflow state.

- [ ] **Step 1: Write failing CPU/GPU parity tests**

Dodaj `testGPUDetectsEdgeCrossingBetweenSensors`, `testGPUDetectsPolygonContainedByLargeBubble`, `testGPUEnvironmentContactsMatchCPUReference` oraz `testEnvironmentOverflowFailsExplicitly`.

- [ ] **Step 2: Run RED**

Run: `swift test --filter MetalRadialWorldEnvironmentTests`

Expected: missing overload or point-only behavior fails.

- [ ] **Step 3: Implement segment contact and deterministic reduction kernels**

Bufor kontaktów przechowuje bubble/range/barycentric/source. Kontakty są redukowane per bańka i segment w stabilnym porządku; overflow kończy klatkę błędem.

- [ ] **Step 4: Run GREEN and regression**

Run: `swift test --filter MetalRadialWorldEnvironmentTests && swift test --skip BenchmarkScenarioTests`

Expected: all selected tests pass.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/BubblePhysicsMetal/Radial/MetalRadialWorldSimulation.swift Sources/BubblePhysicsMetal/Radial/MetalRadialWorldBufferLayout.swift Sources/BubblePhysicsMetal/Shaders/RadialWorldEnvironmentKernels.metal Tests/BubblePhysicsMetalTests/MetalRadialWorldEnvironmentTests.swift
git commit -m "feat: solve radial world environment contacts"
```

### Task 7: Kontakty bańka–bańka i ochrona przed tunnelingiem

**Files:**
- Create: `Sources/BubblePhysicsMetal/Shaders/RadialWorldPairKernels.metal`
- Modify: `Sources/BubblePhysicsMetal/Radial/MetalRadialWorldSimulation.swift`
- Modify: `Sources/BubblePhysicsMetal/Radial/MetalRadialWorldBufferLayout.swift`
- Modify: `Package.swift`
- Create: `Tests/BubblePhysicsMetalTests/MetalRadialWorldContactTests.swift`

**Interfaces:**
- Consumes: CPU pair reference from Task 4 and environment solve from Task 6.
- Produces: GPU AABB candidates, pair contacts, symmetric reductions, `substepCount(for:polygons:deltaTime:) -> Int` ograniczone do `1...8` i complete multi-contact frame.

- [ ] **Step 1: Write failing world-contact tests**

Dodaj `testGPUPairContactsMatchCPUReference`, `testGPUWorldPreservesPairLinearMomentum`, `testContactOrderDoesNotChangeWorldResult`, `testSweptTriangleCannotTunnelThroughBubble` i `testExtremeSizeRatioProducesCandidateAndContact`.

- [ ] **Step 2: Run RED**

Run: `swift test --filter MetalRadialWorldContactTests`

Expected: missing GPU pair contact behavior fails.

- [ ] **Step 3: Implement GPU broad/narrow phase and substeps**

Broad phase zapisuje uporządkowane pary; narrow phase testuje segmenty i zawieranie. Liczba podkroków wynika z maksymalnej drogi wielokąta względem najkrótszego aktywnego segmentu i ma jawny limit bezpieczeństwa raportowany w telemetrii.

- [ ] **Step 4: Run GREEN and regression**

Run: `swift test --filter MetalRadialWorldContactTests && swift test --skip BenchmarkScenarioTests`

Expected: all selected tests pass.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/BubblePhysicsMetal/Radial/MetalRadialWorldSimulation.swift Sources/BubblePhysicsMetal/Radial/MetalRadialWorldBufferLayout.swift Sources/BubblePhysicsMetal/Shaders/RadialWorldPairKernels.metal Tests/BubblePhysicsMetalTests/MetalRadialWorldContactTests.swift
git commit -m "feat: solve radial bubble contacts on GPU"
```

### Task 8: Wielobańkowy renderer

**Files:**
- Create: `Sources/BubblePhysicsMetal/Radial/MetalRadialWorldRenderer.swift`
- Modify: `Sources/BubblePhysicsMetal/Shaders/RadialBubbleKernels.metal`
- Create: `Tests/BubblePhysicsMetalTests/MetalRadialWorldRendererTests.swift`

**Interfaces:**
- Consumes: `MetalRadialWorldFrameResources` and ranges from Task 5.
- Produces: `MetalRadialWorldRenderer.rebuildScene(labels:)` oraz `encode(frame:polygonVertices:diagnostics:renderPass:drawableSize:commandBuffer:)`.

- [ ] **Step 1: Write failing renderer tests**

Dodaj `testRendererBuildsOneFanAndLoopPerBubbleRange`, `testLabelsFollowMatchingBodyPose`, `testLargeAdaptiveContourHasNoVisibleEightPointFallback` i `testCollapsedBubbleDoesNotProduceNonFiniteGeometry`.

- [ ] **Step 2: Run RED**

Run: `swift test --filter MetalRadialWorldRendererTests`

Expected: compile failure for missing renderer.

- [ ] **Step 3: Implement range-driven instanced rendering**

Renderer używa wspólnych buforów świata, oddzielnego zakresu dla każdego wachlarza i etykiety oraz istniejącego `MetalWorldViewport`.

- [ ] **Step 4: Run GREEN and regression**

Run: `swift test --filter MetalRadialWorldRendererTests && swift test --skip BenchmarkScenarioTests`

Expected: all selected tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysicsMetal/Radial/MetalRadialWorldRenderer.swift Sources/BubblePhysicsMetal/Shaders/RadialBubbleKernels.metal Tests/BubblePhysicsMetalTests/MetalRadialWorldRendererTests.swift
git commit -m "feat: render multi-bubble radial world"
```

### Task 9: Scena diagnostyczna i telemetria

**Files:**
- Replace internals: `Benchmarks/iOS/BubblePhysicsBench/App/RadialBubblePrototypeView.swift`
- Modify: `Benchmarks/iOS/BubblePhysicsBench/App/BubblePhysicsBenchApp.swift`
- Modify: `Sources/BubblePhysicsMetal/FrameTelemetry.swift`
- Create: `Sources/BubblePhysics/Prototype/RadialDiagnosticSceneFactory.swift`
- Create: `Tests/BubblePhysicsTests/RadialDiagnosticSceneFactoryTests.swift`
- Modify: `Tests/BubblePhysicsMetalTests/FrameTelemetryTests.swift`
- Replace: `Tests/BubblePhysicsMetalTests/MetalRadialEnduranceTests.swift`

**Interfaces:**
- Consumes: world simulation and renderer from Tasks 5–8.
- Produces: deterministic `RadialDiagnosticSceneFactory.make()` z 16 bańkami, multi-world prototype view and telemetry broad/contact/solve/remesh/render, counts, penetrations, substeps and flags.

- [ ] **Step 1: Write failing scene and telemetry tests**

Dodaj `testSceneContainsSixteenBubblesAcrossRequiredSizeClasses`, `testSceneIncludesBubbleLargerThanShortBoardDimension`, `testSceneStartsBubblesCollapsedWithUniqueIDs`, `testTelemetryPublishesWorldContactAndRemeshMetrics` oraz `testDiagnosticWorldSurvivesTenThousandStepsWithoutOverflowOrRunawayEnergy`. Użyj promieni docelowych 18–32 dla małych, 48–90 dla średnich, 160 dla dużej i 430 dla bańki większej od planszy.

- [ ] **Step 2: Run RED**

Run: `swift test --filter RadialDiagnosticSceneFactoryTests && swift test --filter FrameTelemetryTests && swift test --filter MetalRadialEnduranceTests`

Expected: missing scene factory and world metrics fail.

- [ ] **Step 3: Implement scene, app integration and overlay**

Twórz bańki deterministycznie i uruchamiaj narodziny sekwencyjnie. Zachowaj kontrolki oraz legacy `40`/`300`; `Radial` używa wyłącznie nowego świata.

- [ ] **Step 4: Run GREEN, full tests and generic Debug build**

Run: `swift test --skip BenchmarkScenarioTests`

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer xcodebuild -project Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj -scheme BubblePhysicsBench -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`

Expected: tests pass and `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysics/Prototype/RadialDiagnosticSceneFactory.swift Sources/BubblePhysicsMetal/FrameTelemetry.swift Benchmarks/iOS/BubblePhysicsBench/App/RadialBubblePrototypeView.swift Benchmarks/iOS/BubblePhysicsBench/App/BubblePhysicsBenchApp.swift Tests/BubblePhysicsTests/RadialDiagnosticSceneFactoryTests.swift Tests/BubblePhysicsMetalTests/FrameTelemetryTests.swift Tests/BubblePhysicsMetalTests/MetalRadialEnduranceTests.swift
git commit -m "feat: add radial contact diagnostic scene"
```

### Task 10: Buildy i odbiór na iPhonie X

**Files:**
- Modify: `docs/benchmarks/iphone-x-radial-prototype.md`

**Interfaces:**
- Consumes: complete world from Tasks 1–9.
- Produces: recorded automated and physical-device acceptance result.

- [ ] **Step 1: Run complete automated verification**

Run: `swift test --skip BenchmarkScenarioTests`

Run generic iOS builds in Debug and Release with Xcode 26.6.

Expected: all tests pass and both builds report `BUILD SUCCEEDED`.

- [ ] **Step 2: Install, launch and observe on iPhone X**

Uruchom `Radial` na `iPhone (Mariusz)` przez co najmniej 60 sekund i potwierdź, że proces pozostaje podłączony bez błędu Metal.

- [ ] **Step 3: Record technical telemetry**

Zapisz w dokumencie FPS, p50, p95, czasy faz, liczby baniek/czujników/kandydatów/kontaktów, penetrację przed/po solve, remeshing, substeps, overflow i non-finite.

- [ ] **Step 4: Obtain CEO visual acceptance**

Poproś CEO o ocenę gładkości, penetracji, nacisku, odzyskiwania kształtu, wypełniania przestrzeni i obrotu. Nie oznaczaj fizyki jako zaakceptowanej bez tej decyzji.

- [ ] **Step 5: Record, commit and push**

```bash
git add docs/benchmarks/iphone-x-radial-prototype.md
git commit -m "test: validate multi-bubble radial world"
git push origin main
```
