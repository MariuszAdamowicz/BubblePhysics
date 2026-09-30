# Metal Full GPU Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zbudować iOS-only backend Metal, który wykonuje kompletny krok deformowalnej fizyki baniek na GPU i osiąga p95 ≤ 8 ms dla 300 baniek na iPhonie X.

**Architecture:** `BubbleWorld` zachowuje CPU jako backend referencyjny, a nowy produkt `BubblePhysicsMetal` dostarcza `MetalBubbleSolver`. Trwałe bufory GPU przechowują stan cząstek, ograniczenia, LBVH, pary i poprawki; jeden command buffer wykonuje predykcję, broad phase i osiem iteracji solvera Jacobi bez odczytu cząstek przez CPU.

**Tech Stack:** Swift 5.9, Swift Package Manager, Metal, Metal Shading Language, XCTest, iOS 16+, Xcode 26.6.

**Spec:** `docs/superpowers/specs/2026-09-30-metal-full-gpu-backend-design.md`

## Global Constraints

- Pierwsza wersja backendu działa tylko na iOS 16+; macOS nie jest wymaganiem.
- CPU i GPU mają być fizycznie porównywalne, nie bitowo identyczne.
- GPU wykonuje broad phase, narrow phase i solver; CPU nie odczytuje cząstek między iteracjami.
- Broad phase używa LBVH z AABB, nie jednolitej siatki.
- Nie wprowadzaj stałego limitu liczby punktów obwodu, par ani kontaktów.
- Przepełnienie bufora ma skutkować bezpiecznym wzrostem pojemności i ponowieniem kroku, nigdy utratą danych.
- P95 fizyki dla 300 baniek na iPhonie X w Release musi wynieść nie więcej niż 8 ms.
- Każdy task pracuje test-first, ma własny commit i jest wypychany na `main`.

## Review Focus

- Przepełnienie bufora par, kontaktów lub poprawek nie może cicho pominąć danych; test własności należy do Task 3.
- Jedna bardzo duża bańka i wiele małych muszą wygenerować komplet par AABB; test należy do Task 5.
- Redukcja poprawek współdzielonej cząstki nie może zależeć od kolejności wątków; test należy do Task 6.
- Długi przebieg gęstej sceny nie może wytworzyć NaN, nieskończoności ani utracić pola; test należy do Task 7.
- Odłączony Metal lub błąd komendy ma jednoznacznie przełączyć świat na CPU bez utraty poleceń; test należy do Task 8.

---

## Struktura plików

- `Package.swift` — produkt i target `BubblePhysicsMetal`.
- `Sources/BubblePhysics/SimulationBackend.swift` — wspólne typy backendu i diagnostyki.
- `Sources/BubblePhysicsMetal/MetalBubbleSolver.swift` — iOS facade zasobów Metal i kodowanie kroku.
- `Sources/BubblePhysicsMetal/MetalBufferLayout.swift` — ABI Swift/Metal, serializacja stanu i pojemności.
- `Sources/BubblePhysicsMetal/MetalCapacityManager.swift` — telemetria przepełnienia, wzrost i ponowienie kroku.
- `Sources/BubblePhysicsMetal/MetalWorldSnapshot.swift` — adaptacja `BubbleWorld` do buforów GPU.
- `Sources/BubblePhysicsMetal/Shaders/BubblePhysicsKernels.metal` — predykcja, AABB, kształt, granice i zastosowanie poprawek.
- `Sources/BubblePhysicsMetal/Shaders/LBVHKernels.metal` — klucze Mortona, sortowanie, budowa i przejście LBVH.
- `Sources/BubblePhysicsMetal/Shaders/ContactKernels.metal` — kontakty, poprawki i redukcja Jacobi.
- `Sources/BubblePhysicsMetal/Shaders/PolygonKernels.metal` — kontakty baniek z wielokątami, chwyt i prędkości kinematyczne.
- `Tests/BubblePhysicsMetalTests/*` — testy serializacji, CPU/GPU, LBVH, kontaktów i odtwarzania po przepełnieniu.
- `Benchmarks/iOS/BubblePhysicsBench/*` — host iOS, scenariusze skalowania oraz raport etapów GPU.

### Task 1: Kontrakt backendu i target iOS Metal

**Files:**
- Modify: `Package.swift`
- Create: `Sources/BubblePhysics/SimulationBackend.swift`
- Create: `Sources/BubblePhysicsMetal/MetalBubbleSolver.swift`
- Create: `Sources/BubblePhysicsMetal/Shaders/BubblePhysicsKernels.metal`
- Create: `Tests/BubblePhysicsMetalTests/MetalAvailabilityTests.swift`

**Interfaces:**
- Produces `public enum SimulationBackendKind: Sendable { case cpu, metal }`.
- Produces `public struct SimulationBackendDiagnostics: Equatable, Sendable` with `backend`, `didFallbackToCPU`, `particleCount`, `candidatePairCount`, `contactCount`, `didOverflow`.
- Produces `@available(iOS 16.0, *) public final class MetalBubbleSolver` with `init?(device: MTLDevice? = MTLCreateSystemDefaultDevice())` and `var isAvailable: Bool`.

- [ ] **Step 1: Write the failing availability test**

```swift
func testMetalSolverLoadsRequiredComputeFunctionsWhenMetalIsAvailable() throws {
    guard let solver = MetalBubbleSolver() else { throw XCTSkip("Metal unavailable") }
    XCTAssertTrue(solver.isAvailable)
    XCTAssertTrue(solver.loadedFunctionNames.contains("predictParticles"))
}
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run: `swift test --filter MetalAvailabilityTests/testMetalSolverLoadsRequiredComputeFunctionsWhenMetalIsAvailable`

Expected: FAIL because `BubblePhysicsMetal` and `MetalBubbleSolver` do not exist.

- [ ] **Step 3: Add the Metal package product and minimal solver facade**

Use an iOS availability annotation. Compile the package shader into a library that `MetalBubbleSolver` loads once during initialization; expose `loadedFunctionNames` only for diagnostics and tests.

- [ ] **Step 4: Run focused tests and the full package suite**

Run: `swift test`

Expected: all existing CPU tests remain green and the Metal availability test passes or skips only when Metal is genuinely unavailable.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/BubblePhysics/SimulationBackend.swift Sources/BubblePhysicsMetal Tests/BubblePhysicsMetalTests
git commit -m "feat: add iOS Metal solver target"
```

### Task 2: ABI buforów i snapshot świata

**Files:**
- Create: `Sources/BubblePhysicsMetal/MetalBufferLayout.swift`
- Create: `Sources/BubblePhysicsMetal/MetalWorldSnapshot.swift`
- Modify: `Sources/BubblePhysics/BubbleWorld.swift`
- Create: `Tests/BubblePhysicsMetalTests/MetalBufferLayoutTests.swift`

**Interfaces:**
- Consumes `BubbleWorld` state and `MetalBubbleSolver` from Task 1.
- Produces `MetalWorldSnapshot.init(world: BubbleWorld)` and `func encodedBuffers() -> MetalEncodedWorldBuffers`.
- Produces `MetalParticle`, `MetalBubbleRange`, `MetalDistanceConstraint`, `MetalAreaConstraint`, `MetalPolygonRange` with explicit 16-byte-aligned layouts shared with MSL.

- [ ] **Step 1: Write failing layout and snapshot tests**

```swift
func testSnapshotPreservesAdaptiveBoundaryRangesAndParticlePositions() {
    let snapshot = MetalWorldSnapshot(world: adaptiveWorld())
    XCTAssertEqual(snapshot.bubbleRanges.map(\.boundaryCount), [8, 23])
    XCTAssertEqual(snapshot.particles.map(\.position), expectedPositions)
}

func testSharedSwiftMetalRecordsHaveExpectedStride() {
    XCTAssertEqual(MemoryLayout<MetalParticle>.stride % 16, 0)
}
```

- [ ] **Step 2: Run focused tests to verify they fail**

Run: `swift test --filter MetalBufferLayoutTests`

Expected: FAIL because the snapshot and ABI records do not exist.

- [ ] **Step 3: Implement serializable GPU records and snapshot construction**

Preserve adaptive point counts exactly. Do not create a fixed `maxNodes` field. Keep dynamic topology mutations represented as command records rather than CPU position readbacks.

- [ ] **Step 4: Run focused tests and `swift test`**

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysics/BubbleWorld.swift Sources/BubblePhysicsMetal/MetalBufferLayout.swift Sources/BubblePhysicsMetal/MetalWorldSnapshot.swift Tests/BubblePhysicsMetalTests/MetalBufferLayoutTests.swift
git commit -m "feat: encode BubbleWorld state for Metal"
```

### Task 3: Trwałe bufory, telemetria i bezpieczny wzrost

**Files:**
- Create: `Sources/BubblePhysicsMetal/MetalCapacityManager.swift`
- Modify: `Sources/BubblePhysicsMetal/MetalBubbleSolver.swift`
- Create: `Tests/BubblePhysicsMetalTests/MetalCapacityManagerTests.swift`

**Interfaces:**
- Consumes `MetalEncodedWorldBuffers` from Task 2.
- Produces `MetalCapacityManager.ensureCapacity(for:) -> Bool` and `MetalStepTelemetry` with counters plus `didOverflow`.
- Produces `MetalBubbleSolver.step(snapshot:commands:) async throws -> MetalStepTelemetry`.

- [ ] **Step 1: Write failing tests for capacity growth and retry**

```swift
func testOverflowGrowsPairBufferBeforeRetryingStep() async throws {
    let solver = try makeSolver(pairCapacity: 1)
    let telemetry = try await solver.step(snapshot: overlappingThreeBubbleSnapshot, commands: [])
    XCTAssertFalse(telemetry.didOverflow)
    XCTAssertGreaterThanOrEqual(solver.capacities.pairs, 3)
}
```

- [ ] **Step 2: Run focused tests to verify they fail**

Run: `swift test --filter MetalCapacityManagerTests/testOverflowGrowsPairBufferBeforeRetryingStep`

Expected: FAIL because no capacity manager or retry path exists.

- [ ] **Step 3: Implement persistent allocation and retry protocol**

Use GPU flags and counters in a small shared telemetry buffer plus ping-pong state buffers. On overflow, discard the output buffer, preserve queued commands and the immutable input buffer, enlarge only the exhausted buffer outside the failed command buffer, then rerun the same input step.

- [ ] **Step 4: Run focused tests and `swift test`**

Expected: all tests pass with no fixed runtime cap.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysicsMetal/MetalCapacityManager.swift Sources/BubblePhysicsMetal/MetalBubbleSolver.swift Tests/BubblePhysicsMetalTests/MetalCapacityManagerTests.swift
git commit -m "feat: grow Metal physics buffers safely"
```

### Task 4: Predykcja, ograniczenia kształtu i granice na GPU

**Files:**
- Modify: `Sources/BubblePhysicsMetal/MetalBubbleSolver.swift`
- Modify: `Sources/BubblePhysicsMetal/Shaders/BubblePhysicsKernels.metal`
- Create: `Tests/BubblePhysicsMetalTests/MetalShapeSolverTests.swift`

**Interfaces:**
- Consumes snapshot buffers and step commands from Tasks 2–3.
- Produces GPU kernels `predictParticles`, `solveBubbleShape`, `solveWorldBounds` and a readback helper restricted to tests.

- [ ] **Step 1: Write failing CPU/GPU comparison tests**

```swift
func testMetalPredictionMovesBubbleDownUnderGravity() async throws { /* center.y decreases */ }
func testMetalShapeSolverKeepsRestAreaWithinExistingTolerance() async throws { /* πr² ± 3 */ }
func testMetalWorldBoundsKeepEveryBoundaryParticleInsideBounds() async throws { /* all points inside */ }
```

- [ ] **Step 2: Run focused tests to verify they fail**

Run: `swift test --filter MetalShapeSolverTests`

Expected: FAIL because the kernels do not yet update state.

- [ ] **Step 3: Implement these kernels and encode eight shape iterations**

Dispatch one independent workgroup per bubble. Apply radial, edge, diagonal and area constraints with the same material data as CPU. Bounds execute in every iteration.

- [ ] **Step 4: Run focused tests and `swift test`**

Expected: all tests pass; CPU reference tests remain unchanged.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysicsMetal/MetalBubbleSolver.swift Sources/BubblePhysicsMetal/Shaders/BubblePhysicsKernels.metal Tests/BubblePhysicsMetalTests/MetalShapeSolverTests.swift
git commit -m "feat: solve bubble shape constraints on Metal"
```

### Task 5: GPU AABB i LBVH broad phase

**Files:**
- Create: `Sources/BubblePhysicsMetal/Shaders/LBVHKernels.metal`
- Modify: `Sources/BubblePhysicsMetal/MetalBubbleSolver.swift`
- Create: `Tests/BubblePhysicsMetalTests/MetalBroadPhaseTests.swift`

**Interfaces:**
- Consumes particle ranges from Task 2 and persistent pair capacity from Task 3.
- Produces kernels `computeBubbleAABBs`, `encodeMortonKeys`, `radixSortMortonKeys`, `buildLBVH`, `emitCandidatePairs`.
- Produces telemetry `candidatePairCount`.

- [ ] **Step 1: Write failing broad-phase comparison tests**

```swift
func testMetalLBVHFindsOverlappingLargeAndSmallBubbles() async throws {
    let pairs = try await runMetalPairs(largeBubbleAndSmallBubble)
    XCTAssertEqual(pairs, [BubblePair(BubbleID(rawValue: 1), BubbleID(rawValue: 2))])
}

func testMetalLBVHRejectsPairsSeparatedOnYEvenWhenXOverlaps() async throws { /* no pairs */ }
```

- [ ] **Step 2: Run focused tests to verify they fail**

Run: `swift test --filter MetalBroadPhaseTests`

Expected: FAIL because LBVH kernels do not exist.

- [ ] **Step 3: Implement exact AABB LBVH generation**

Use AABB centers only for Morton ordering; pair emission must still test complete AABB overlap. Append each unordered pair once and signal capacity overflow instead of dropping it.

- [ ] **Step 4: Run focused tests and `swift test`**

Expected: GPU pairs match the CPU reference for small, large and mixed-size fixtures.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysicsMetal/MetalBubbleSolver.swift Sources/BubblePhysicsMetal/Shaders/LBVHKernels.metal Tests/BubblePhysicsMetalTests/MetalBroadPhaseTests.swift
git commit -m "feat: generate bubble pairs with Metal LBVH"
```

### Task 6: GPU narrow phase i redukcja Jacobi

**Files:**
- Create: `Sources/BubblePhysicsMetal/Shaders/ContactKernels.metal`
- Modify: `Sources/BubblePhysicsMetal/MetalBufferLayout.swift`
- Modify: `Sources/BubblePhysicsMetal/MetalBubbleSolver.swift`
- Create: `Tests/BubblePhysicsMetalTests/MetalContactSolverTests.swift`

**Interfaces:**
- Consumes candidate pairs from Task 5.
- Produces `MetalContact`, `MetalCorrection`, kernels `generateBubbleContacts`, `sortCorrectionsByParticle`, `reduceCorrections`, `applyCorrections`.
- Produces telemetry `contactCount`.

- [ ] **Step 1: Write failing tests for contact validity and shared corrections**

```swift
func testMetalContactsSeparateOverlappingBubblesWithoutLosingRestArea() async throws { /* centers separate; area tolerance */ }
func testMetalReductionAppliesBothCorrectionsToSharedParticle() async throws { /* expected summed correction */ }
```

- [ ] **Step 2: Run focused tests to verify they fail**

Run: `swift test --filter MetalContactSolverTests`

Expected: FAIL because contact and reduction kernels do not exist.

- [ ] **Step 3: Implement append, ordering and reduction pipeline**

Generate records without shared position writes. Sort correction keys by particle index, reduce each contiguous group deterministically, then apply a single correction per particle. Run this pipeline in each solver iteration.

- [ ] **Step 4: Run focused tests and `swift test`**

Expected: contacts separate bubbles and the dense-scene finiteness test remains green for Metal.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysicsMetal/Shaders/ContactKernels.metal Sources/BubblePhysicsMetal/MetalBufferLayout.swift Sources/BubblePhysicsMetal/MetalBubbleSolver.swift Tests/BubblePhysicsMetalTests/MetalContactSolverTests.swift
git commit -m "feat: resolve bubble contacts with Metal Jacobi reductions"
```

### Task 7: Wielokąty, chwyt i operacje dynamiczne

**Files:**
- Create: `Sources/BubblePhysicsMetal/Shaders/PolygonKernels.metal`
- Modify: `Sources/BubblePhysicsMetal/MetalWorldSnapshot.swift`
- Modify: `Sources/BubblePhysicsMetal/MetalBubbleSolver.swift`
- Create: `Tests/BubblePhysicsMetalTests/MetalInteractionTests.swift`

**Interfaces:**
- Consumes buffers and correction path from Task 6.
- Produces kernels `generatePolygonContacts`, `applyGrabConstraint`, `applyKinematicSurfaceVelocity`.
- Produces `MetalBubbleSolver.applyTopologyCommands(_:)` for resize, merge and split between GPU steps.

- [ ] **Step 1: Write failing interaction tests**

```swift
func testMetalKinematicRectangleTransfersTangentialVelocity() async throws { /* bubble gains tangential travel */ }
func testMetalGrabCapsFastTargetCorrection() async throws { /* movement ≤ maximum correction */ }
func testMetalSplitAndMergeConserveRestArea() async throws { /* total rest area unchanged */ }
```

- [ ] **Step 2: Run focused tests to verify they fail**

Run: `swift test --filter MetalInteractionTests`

Expected: FAIL because polygon, grab and topology command support does not exist.

- [ ] **Step 3: Implement all interaction kernels and topology update protocol**

Use existing CPU triangulation data as immutable GPU input. Apply topology-changing commands only at step boundaries; rebuild affected buffer ranges without downloading unchanged particle state.

- [ ] **Step 4: Run focused tests and `swift test`**

Expected: all interaction fixtures are physically finite and preserve required area semantics.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysicsMetal/Shaders/PolygonKernels.metal Sources/BubblePhysicsMetal/MetalWorldSnapshot.swift Sources/BubblePhysicsMetal/MetalBubbleSolver.swift Tests/BubblePhysicsMetalTests/MetalInteractionTests.swift
git commit -m "feat: support polygons grabs and topology commands on Metal"
```

### Task 8: Integracja świata, fallback CPU i benchmark iPhone X

**Files:**
- Modify: `Sources/BubblePhysics/BubbleWorld.swift`
- Modify: `Sources/BubblePhysics/BenchmarkScenario.swift`
- Modify: `Benchmarks/iOS/BubblePhysicsBench/App/BubblePhysicsBenchApp.swift`
- Create: `Tests/BubblePhysicsMetalTests/MetalBackendIntegrationTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes complete `MetalBubbleSolver` from Tasks 1–7.
- Produces `BubbleWorld` selection backendu `SimulationBackendKind` oraz `WorldStepReport.backendDiagnostics`.
- Produces benchmarki `iPhoneX`, `mixedScale`, `rotatingPolygon` i sweep liczby baniek.

- [ ] **Step 1: Write failing integration and fallback tests**

```swift
func testWorldFallsBackToCPUWithoutLosingQueuedCommandsWhenMetalStepFails() async throws { /* command applied once by CPU */ }
func testMetalAndCPUCompleteDenseScenarioWithoutNonFiniteParticles() async throws { /* both finite */ }
```

- [ ] **Step 2: Run focused tests to verify they fail**

Run: `swift test --filter MetalBackendIntegrationTests`

Expected: FAIL because `BubbleWorld` cannot yet choose and report a Metal backend.

- [ ] **Step 3: Integrate backend selection, diagnostics and benchmark reporting**

The production render path must retain the Metal position buffer. Read only counters and timing asynchronously. Add a Release-only iPhone X benchmark display for p50, p95, per-stage GPU timing, particles, pairs, contacts and overflow state.

- [ ] **Step 4: Verify all automated tests and the iOS host build**

Run: `swift test`

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer xcodebuild -project Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj -scheme BubblePhysicsBench -sdk iphonesimulator -configuration Release build CODE_SIGNING_ALLOWED=NO`

Expected: all tests pass and host app builds. If the user's open Xcode holds the build database lock, record that exact limitation and verify from Xcode after it is released.

- [ ] **Step 5: Measure the physical iPhone X acceptance benchmark**

Run the 300-bubble iPhone X scenario in Release on the connected iPhone X.

Expected: p95 ≤ 8 ms, zero overflow, zero non-finite state; record the scaling sweep and rotating-polygon result in `README.md`.

- [ ] **Step 6: Commit and push**

```bash
git add Sources/BubblePhysics Sources/BubblePhysicsMetal Tests Benchmarks/iOS/BubblePhysicsBench README.md
git commit -m "feat: integrate full Metal physics backend"
git push origin main
```

## Plan self-review

- Spec coverage: Tasks 1–3 cover module, persistent buffers and safe growth; Task 4 covers particles, shape and bounds; Task 5 covers LBVH; Task 6 covers contacts and reductions; Task 7 covers polygons, grabs and topology; Task 8 covers facade, renderer path, CPU fallback and benchmark.
- Type consistency: `MetalBubbleSolver`, `MetalWorldSnapshot`, `MetalEncodedWorldBuffers`, `MetalStepTelemetry` and `SimulationBackendDiagnostics` are introduced before their consumers.
- Review Focus coverage: overflow is Task 3, mixed-size AABB is Task 5, shared correction reduction is Task 6, long-run finiteness is Task 6 and Task 8, fallback preserves commands in Task 8.
- Scope: the plan makes one independently testable deliverable per task and defers macOS plus optional future GPU broad-phase variations outside the stated LBVH design.
