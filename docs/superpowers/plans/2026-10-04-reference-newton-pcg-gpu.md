# GPU Newton/PCG dla referencyjnego solvera BubblePhysics — plan implementacji

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zbudować iOS-only backend Metal dla referencyjnego kroku kontaktowego, w którym GPU wykonuje Newton/PCG i otaczający pipeline świata, przy zachowaniu CPU jako wyroczni jakości i fallbacku.

**Architecture:** Nowy target `BubblePhysicsReferenceMetal` przechowuje trwałe bufory SoA oraz jeden command buffer na klatkę. CPU przekazuje wejścia sceny i odczytuje po ukończeniu małą telemetrię; GPU wykonuje predykcję, broad phase, CCD, kontakty, Newton/PCG, guardy i kontury. Każdy etap porównuje wynik z `BubblePhysicsReference` w tolerancji float, nie bitowo.

**Tech Stack:** Swift 5.9, Swift Package Manager, Metal, Metal Shading Language, XCTest, iOS 16+, Xcode 26.6.

**Spec:** `docs/superpowers/specs/2026-10-04-reference-newton-pcg-gpu-design.md`

## Globalne ograniczenia

- Backend działa wyłącznie na iOS 16+; CPU reference pozostaje backendem domyślnym, testowym i fallbackiem.
- Nie zmieniaj scen, parametrów fizycznych, tolerancji, definicji jakości ani publicznego API biblioteki.
- Pierwsza bramka używa limitu Newtona `4`; macierz `4/8/12/16` służy porównaniu, nie adaptacji czasu.
- Bufory kandydatów, kontaktów, komponentów i wektorów PCG rosną po przepełnieniu i ponawiają tę samą klatkę; nie mają semantycznego stałego maksimum.
- Nie publikuj częściowego kroku ani wyniku mieszanego CPU/GPU.
- Akceptacja: `stress-300`, Release, iPhone, `p95 <= 10 ms` pełnej klatki oraz jakość nie gorsza od baseline'u CPU.
- Nie implementuj dynamicznego limitu iteracji.

## Review focus

- Przepełnienie w środku kroku nie może zmienić stanu ani zgubić wejść — Task 2.
- Kontakt bańka–odcinek musi tworzyć jednoelementowy komponent GPU — Task 5.
- `J·v` dla zera, kontaktu bańka–bańka i bańka–odcinek musi być zgodny z CPU — Task 3.
- Wczesne zbieganie PCG nie może wymagać odczytu CPU między dispatchami — Task 4.
- Błąd Metal lub `non-finite` przełącza całą następną klatkę na CPU — Task 6.

## Struktura plików

- `Package.swift` — produkt i target referencyjnego backendu Metal.
- `Sources/BubblePhysicsReferenceMetal/ReferenceMetalBufferLayout.swift` — ABI Swift/MSL i snapshot świata.
- `Sources/BubblePhysicsReferenceMetal/ReferenceMetalCapacityManager.swift` — pojemności, przepełnienia i retry.
- `Sources/BubblePhysicsReferenceMetal/ReferenceMetalSolver.swift` — pipeline'y i kodowanie klatki.
- `Sources/BubblePhysicsReferenceMetal/ReferenceMetalWorldRunner.swift` — wybór CPU/GPU i fallback.
- `Sources/BubblePhysicsReferenceMetal/Shaders/ReferenceGeometryKernels.metal` — predykcja, broad phase, CCD i kontakty.
- `Sources/BubblePhysicsReferenceMetal/Shaders/ReferenceNewtonPCGKernels.metal` — reszta, `J·v`, preconditioner, redukcje i PCG.
- `Sources/BubblePhysicsReferenceMetal/Shaders/ReferencePostSolveKernels.metal` — guardy, kontury i dane render-ready.
- `Tests/BubblePhysicsReferenceMetalTests/*` — testy ABI, operatorów, PCG, kontaktów, fallbacku i benchmarku.

### Task 1: Target, kontrakt backendu i telemetria

**Files:**

- Modify: `Package.swift`
- Create: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalBackend.swift`
- Create: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalSolver.swift`
- Create: `Tests/BubblePhysicsReferenceMetalTests/ReferenceMetalAvailabilityTests.swift`

**Interfaces:** Produces `ReferenceSimulationBackend { case cpu, metal }`, `ReferenceMetalFrameTelemetry` oraz iOS-owy `ReferenceMetalSolver.init?(device:)` z listą załadowanych funkcji.

- [ ] Write failing tests `testReferenceMetalSolverLoadsRequiredPipelines` i `testEmptyTelemetryIsFinite`.
- [ ] Run `swift test --filter ReferenceMetalAvailabilityTests`; expect compilation failure because target/facade do not exist.
- [ ] Add target depending on `BubblePhysicsReference`, minimal facade and telemetry; expose `referenceBuildResidual` as required pipeline.
- [ ] Run `swift test --filter ReferenceMetalAvailabilityTests && swift test`; expect pass or explicit skip only without Metal.
- [ ] Commit: `git add Package.swift Sources/BubblePhysicsReferenceMetal Tests/BubblePhysicsReferenceMetalTests && git commit -m "feat: add reference Metal backend contract"`.

### Task 2: ABI, snapshot i bezpieczny wzrost buforów

**Files:**

- Create: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalBufferLayout.swift`
- Create: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalCapacityManager.swift`
- Modify: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalSolver.swift`
- Create: `Tests/BubblePhysicsReferenceMetalTests/ReferenceMetalBufferLayoutTests.swift`
- Create: `Tests/BubblePhysicsReferenceMetalTests/ReferenceMetalCapacityManagerTests.swift`

**Interfaces:** Produces `ReferenceMetalSnapshot.init(world:)`, 16-byte-aligned `ReferenceMetalBubble`, `ReferenceMetalSegment`, `ReferenceMetalContact`, `ReferenceMetalComponent`, and `ReferenceMetalCapacityManager.retryingFrame(requirements:encode:) async throws -> ReferenceMetalFrameTelemetry`.

- [ ] Write failing tests preserving sorted IDs, centers and segment velocity, plus `testOverflowRetriesFromUnchangedInputAndPublishesOnlyRetryResult` with exactly two attempts.
- [ ] Run `swift test --filter ReferenceMetalBufferLayoutTests && swift test --filter ReferenceMetalCapacityManagerTests`; expect RED.
- [ ] Implement SoA input/output buffers. Overflow flag discards output, enlarges only its exhausted allocation and re-encodes the unchanged snapshot and controls.
- [ ] Run focused tests and `swift test`; expect pass and no fixed semantic capacity.
- [ ] Commit: `git add Sources/BubblePhysicsReferenceMetal Tests/BubblePhysicsReferenceMetalTests && git commit -m "feat: add reference Metal buffers and retry"`.

### Task 3: GPU dynamic-system operators

**Files:**

- Create: `Sources/BubblePhysicsReferenceMetal/Shaders/ReferenceNewtonPCGKernels.metal`
- Modify: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalSolver.swift`
- Create: `Tests/BubblePhysicsReferenceMetalTests/ReferenceMetalDynamicSystemTests.swift`

**Interfaces:** Produces kernels `referenceBuildResidual`, `referenceApplyJacobian`, `referenceBuildInverseDiagonal`, `referenceReduceDot`, and `evaluateOperatorsForTesting(snapshot:endCenters:vector:) async throws -> ReferenceMetalOperatorResult`.

- [ ] Write failing tests matching CPU within `1e-3` for bubble–bubble and bubble–segment fixtures, and exact zero for `J·0`.
- [ ] Run `swift test --filter ReferenceMetalDynamicSystemTests`; expect RED.
- [ ] Implement CPU-equivalent midpoint/contact formulas, finite-difference epsilon `1e-3`, inverse diagonal and fixed-block dot reduction.
- [ ] Run `swift test --filter ReferenceMetalDynamicSystemTests && swift test --filter BubblePhysicsReferenceTests`; expect pass.
- [ ] Commit: `git add Sources/BubblePhysicsReferenceMetal Tests/BubblePhysicsReferenceMetalTests && git commit -m "feat: evaluate reference Newton operators on Metal"`.

### Task 4: Matrix-free PCG on GPU

**Files:**

- Modify: `ReferenceMetalBufferLayout.swift`, `ReferenceMetalSolver.swift`, `ReferenceNewtonPCGKernels.metal`
- Create: `Tests/BubblePhysicsReferenceMetalTests/ReferenceMetalPCGTests.swift`

**Interfaces:** Produces kernels `referencePCGInitialize`, `referencePCGAdvance`, `referencePCGUpdateDirection`, `referencePCGFinalize`, and `solvePCGForTesting(snapshot:endCenters:rightHandSide:limit:) async throws -> ReferencePCGResult`.

- [ ] Write failing comparison test for correction and iteration count within `1e-3`, early convergence at limit 8, and non-finite input reporting.
- [ ] Run `swift test --filter ReferenceMetalPCGTests`; expect RED.
- [ ] Encode a fixed maximum of GPU-controlled PCG advances; control record suppresses later updates after threshold convergence and preserves CPU denominator/non-finite guards.
- [ ] Run `swift test --filter ReferenceMetalPCGTests && swift test`; expect pass without intermediate CPU scalar readback.
- [ ] Commit: `git add Sources/BubblePhysicsReferenceMetal Tests/BubblePhysicsReferenceMetalTests && git commit -m "feat: solve reference PCG on Metal"`.

### Task 5: Geometry, contacts, CCD i komponenty

**Files:**

- Create: `Sources/BubblePhysicsReferenceMetal/Shaders/ReferenceGeometryKernels.metal`
- Modify: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalSolver.swift`
- Create: `Tests/BubblePhysicsReferenceMetalTests/ReferenceMetalContactPipelineTests.swift`

**Interfaces:** Produces `referencePredict`, `referenceEmitCandidatePairs`, `referenceRefreshContacts`, `referenceFindTOI`, `referenceLabelComponents`, and `prepareFrameForTesting(snapshot:step:) async throws -> ReferenceMetalPreparedFrame`.

- [ ] Write failing tests for sorted contact-ID equality with CPU scene, one bubble–segment component, and CCD that keeps a center on its allowed segment side.
- [ ] Run `swift test --filter ReferenceMetalContactPipelineTests`; expect RED.
- [ ] Implement deterministic pair/contact generation, TOI grouping and component labels; signal overflow instead of dropping any pair or contact.
- [ ] Run `swift test --filter ReferenceMetalContactPipelineTests && swift test --filter BubblePhysicsReferenceTests`; expect pass.
- [ ] Commit: `git add Sources/BubblePhysicsReferenceMetal Tests/BubblePhysicsReferenceMetalTests && git commit -m "feat: prepare reference contacts on Metal"`.

### Task 6: World integration, fallback i post-solve

**Files:**

- Create: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalWorldRunner.swift`
- Create: `Sources/BubblePhysicsReferenceMetal/Shaders/ReferencePostSolveKernels.metal`
- Modify: `Sources/BubblePhysicsReference/Solver/ReferenceWorld.swift`
- Create: `Tests/BubblePhysicsReferenceMetalTests/ReferenceMetalWorldRunnerTests.swift`

**Interfaces:** Produces `ReferenceMetalWorldRunner.step(world:inout ReferenceWorld, scenarioStep:Int) async -> ReferenceWorldStepReport`, kernels `referenceApplyCenterGuards`, `referenceGenerateContours`, `referencePrepareRenderData`, and explicit backend dispatch preserving CPU `step()`.

- [ ] Write failing tests for a finite short `interactive-24` run matching CPU quality tolerance, total-frame fallback after injected GPU failure, and no closed-polygon containment after post-solve.
- [ ] Run `swift test --filter ReferenceMetalWorldRunnerTests`; expect RED.
- [ ] Implement atomic commit of final GPU state/telemetry; otherwise rerun entire next frame on CPU and record fallback reason. Never mix results from two backends.
- [ ] Run `swift test --filter ReferenceMetalWorldRunnerTests && swift test`; expect pass or legitimate Metal skip.
- [ ] Commit: `git add Sources/BubblePhysicsReference Sources/BubblePhysicsReferenceMetal Tests/BubblePhysicsReferenceMetalTests && git commit -m "feat: integrate reference Metal world runner"`.

### Task 7: Benchmark host i bramka urządzeniowa

**Files:**

- Modify: `Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkReport.swift`
- Modify: `Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkRunner.swift`
- Modify: `Benchmarks/iOS/BubblePhysicsBench/App/ReferenceBenchmarkView.swift`
- Create: `Tests/BubblePhysicsReferenceMetalTests/ReferenceMetalBenchmarkTests.swift`
- Modify: `README.md`

**Interfaces:** Extends convergence configuration with `backend: ReferenceSimulationBackend`; preserves plaintext columns and adds backend plus fallback counters.

- [ ] Write failing tests proving GPU report records backend/fallback without changing quality columns and CPU/GPU use the identical seed, steps and limits.
- [ ] Run `swift test --filter ReferenceMetalBenchmarkTests`; expect RED.
- [ ] Add iOS GPU selection. Refuse to label a fallback run as a GPU acceptance measurement; CPU report behavior remains unchanged.
- [ ] Run `swift test`, then `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer xcodebuild -project Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj -scheme BubblePhysicsBench -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`, then `git diff --check`; expect all pass.
- [ ] Run Release matrix `4/8/12/16` for both scenes on the physical iPhone. Save raw report and comparison analysis. Accept only if `stress-300 p95 <= 10 ms` and no quality metric is worse than baseline; otherwise report gap to CEO.
- [ ] Commit: `git add Sources/BubblePhysicsReference Benchmarks/iOS/BubblePhysicsBench Tests/BubblePhysicsReferenceMetalTests README.md docs/benchmarks && git commit -m "feat: benchmark reference GPU solver"`.

## Samokontrola planu

- Tasks 1–2 pokrywają kontrakt i odporność, 3–4 Newton/PCG, 5 CCD/kontakty/komponenty, 6 guardy/kontury/fallback, a 7 benchmark urządzeniowy.
- Każdy punkt Review focus ma test w oznaczonym tasku.
- Plan nie wprowadza adaptacyjnych iteracji, nowych parametrów fizyki ani portu macOS.
