# BubblePhysics Public API v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dostarczyć stabilne, backend-agnostyczne API `BubbleWorld` dla gier i bezpośrednią ścieżkę renderowania Metal, zachowując GPU-native jako produkcyjny runtime.

**Architecture:** Główny produkt SPM stanie się cienką warstwą publiczną nad niepublicznym adapterem GPU-native. Świat przyjmuje niezmienne, atomowo walidowane `WorldTransaction`, wykonuje stałe kroki i publikuje `WorldFrame`; Metal otrzymuje niekopiowany uchwyt do stanu opublikowanej klatki. Stare CPU/reference i wcześniejsze eksperymenty pozostają narzędziami wewnętrznymi oraz testowymi, nie typami importowanymi przez grę.

**Tech Stack:** Swift 5.9, Swift Package Manager, Metal, XCTest; iOS 16+ i macOS 13+.

**Spec:** `docs/superpowers/specs/2026-10-15-public-api-design.md`

## Global Constraints

- Wspieraj wyłącznie iOS 16+ i macOS 13+.
- Gra importuje `BubblePhysics` i opcjonalnie `BubblePhysicsMetalRender`; nie wybiera CPU/GPU ani nie widzi cache, buforów, iteracji lub encoderów.
- Produkcyjny runtime to jeden GPU-native solver; CPU reference jest ukrytym narzędziem jakości/fallbackiem kompletnej klatki.
- `simulationRegion` jest obowiązkowym prostokątem obliczeniowym, nie fizyczną ścianą; `wrap` nie tworzy kolizji przez szew.
- Żadna transakcja nie może opublikować częściowej zmiany świata, a overflow zdarzeń i zaleganie akumulatora muszą być jawne.
- Nie dodawaj w v1 dziur w wielobokach, snapshotów/replay, closure pól, ani publicznych parametrów solvera/buforów Metal.

## Review Focus

- Transakcja zawierająca poprawną zmianę i jeden niepoprawny wielobok nie zmienia ani obiektów, ani zasobów — test w Task 3.
- `wrap` następuje dopiero po całkowitym wyjściu collidera i nie generuje kontaktu z obiektem po przeciwnej krawędzi — test w Task 5.
- Duża liczba nieinteresujących kontaktów nie zapełnia bufora zdarzeń; overflow interesujących jest widoczny — test w Task 7.
- `playerDriven` zatrzymany przez statyczny obiekt raportuje feedback, lecz nie teleportuje ani nie przemieszcza blokera — test w Task 6.
- Standardowy render 300 baniek nie odczytuje konturów na CPU i koduje fizykę + render do command buffera aplikacji — test/instrumentacja w Task 9.

---

## Podział na bramki

Plan celowo dzieli wdrożenie na dziewięć niezależnie recenzowalnych bramek. Taski 1–4 tworzą publiczny kontrakt i atomowość bez ryzyka zmian solvera. Taski 5–8 rozszerzają semantykę świata w GPU-native. Task 9 zmienia ścieżkę renderowania i jest jedyną bramką, która może dotknąć harmonogramu command bufferów. Po każdym tasku należy uruchomić pełny `swift test`; po Task 9 także wymagany jest benchmark urządzeniowy opisany w Task 9.

## File Structure

- `Sources/BubblePhysicsPublic/`: jedyne publiczne modele świata, transakcje, klatki i fasada `BubbleWorld`.
- `Sources/BubblePhysicsRuntime/`: wewnętrzny adapter pomiędzy publicznymi modelami a `BubblePhysicsNativeMetal`; tu mieszczą się konwersje i atomowy staging, nigdy w publicznym module.
- `Sources/BubblePhysicsNativeMetal/`: trwały stan GPU, rozszerzony o niepubliczny staging obiektów, zdarzeń i renderer handoff.
- `Sources/BubblePhysicsMetalRender/`: publiczny adapter renderujący, używający tylko uchwytu runtime i API Metal.
- `Tests/BubblePhysicsPublicTests/`, `Tests/BubblePhysicsRuntimeTests/`, `Tests/BubblePhysicsMetalRenderTests/`: kontraktowe testy API oraz testy integracyjne, odseparowane od historycznych eksperymentów.

### Task 1: Rozdziel publiczny produkt od eksperymentalnych modułów

**Files:**
- Modify: `Package.swift`
- Create: `Sources/BubblePhysicsPublic/BubblePhysics.swift`
- Create: `Sources/BubblePhysicsRuntime/BubblePhysicsRuntime.swift`
- Modify: wszystkie importy/test dependencies wskazujące obecny target `BubblePhysics`
- Test: `Tests/BubblePhysicsPublicTests/PublicProductTests.swift`

**Interfaces:**
- Produces: product `BubblePhysics` -> target `BubblePhysicsPublic`; internal target `BubblePhysicsRuntime`; product `BubblePhysicsMetalRender` -> target o tej nazwie (implementowany w Task 9).
- Preserves: historyczne targety jako implementacyjne/testowe zależności, ale nie jako produkty biblioteki przeznaczone dla gry.

- [ ] **Step 1: Write failing product-surface tests**

```swift
func testGameProductExportsOnlyPublicFacade() {
    _ = BubbleWorld.self
    _ = WorldTransaction.self
    _ = WorldFrame.self
}
```

- [ ] **Step 2: Run the test to verify the target is not yet importable**

Run: `swift test --filter PublicProductTests`
Expected: FAIL because `BubblePhysicsPublic`/the public facade target does not exist.

- [ ] **Step 3: Rewire the package without deleting historical source**

Make `BubblePhysicsPublic` the sole gameplay-facing `BubblePhysics` product and create `BubblePhysicsRuntime` as its implementation dependency. Rename the current `BubblePhysics` target in `Package.swift` to an internal legacy target and update dependent targets/tests; do not move or delete its source directory in this task.

- [ ] **Step 4: Run package and product tests**

Run: `swift test --filter PublicProductTests`
Expected: PASS, and all previous test targets still resolve their internal dependencies.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/BubblePhysicsPublic Sources/BubblePhysicsRuntime Tests/BubblePhysicsPublicTests
git commit -m "refactor: separate BubblePhysics public product"
```

### Task 2: Define value models, IDs, configuration, resources and viewport

**Files:**
- Create: `Sources/BubblePhysicsPublic/Identifiers.swift`
- Create: `Sources/BubblePhysicsPublic/WorldConfiguration.swift`
- Create: `Sources/BubblePhysicsPublic/Objects.swift`
- Create: `Sources/BubblePhysicsPublic/Resources.swift`
- Create: `Sources/BubblePhysicsPublic/Viewport.swift`
- Test: `Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`

**Interfaces:**
- Consumes: public target from Task 1.
- Produces: `ObjectID`, `PhysicsMaterialID`, `RenderStyleID`, `ParameterID`, `MergeGroupSet`, `WorldConfiguration`, `BubbleDescriptor`, `PolygonDescriptor`, `ForceFieldDescriptor`, `SensorDescriptor`, `MotionRole`, `Viewport`.

- [ ] **Step 1: Write failing validation tests**

```swift
func testConcaveSimplePolygonIsAcceptedButHoleAndSelfIntersectionAreRejected()
func testViewportMapsScreenAndWorldWithoutChangingSimulationRegion()
func testMergeGroupSetUsesExactlyUInt64OverlapSemantics()
func testStaticGeometryOutsideSimulationRegionIsRejected()
```

- [ ] **Step 2: Run the focused test target**

Run: `swift test --filter ModelValidationTests`
Expected: FAIL because public descriptors and validators do not exist.

- [ ] **Step 3: Implement public immutable descriptors and throwing validation**

Define `public init(...) throws` on `WorldConfiguration` and each geometry-bearing descriptor. Use `SIMD2<Float>` as the public 2D coordinate type alias `WorldPoint`; require finite values and a simple closed polygon with at least three vertices, while accepting either winding direction. Keep any decomposition result internal. Implement `Viewport.worldPoint(for:in:)` and `Viewport.screenPoint(for:in:)` for an unrotated viewport.

- [ ] **Step 4: Run model tests**

Run: `swift test --filter ModelValidationTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysicsPublic Tests/BubblePhysicsPublicTests/ModelValidationTests.swift
git commit -m "feat: add public world models and resources"
```

### Task 3: Add transaction grammar and all-or-nothing staging

**Files:**
- Create: `Sources/BubblePhysicsPublic/WorldTransaction.swift`
- Create: `Sources/BubblePhysicsPublic/WorldFrame.swift`
- Create: `Sources/BubblePhysicsRuntime/TransactionStager.swift`
- Test: `Tests/BubblePhysicsPublicTests/WorldTransactionTests.swift`
- Test: `Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**Interfaces:**
- Consumes: descriptors/resources from Task 2.
- Produces: `WorldTransaction`, `WorldOperation`, `TransactionReceipt`, `WorldEvent.transactionRejected`, `WorldFrame`.

- [ ] **Step 1: Write failing atomicity tests**

```swift
func testRejectedTransactionPublishesNoPartialObjectOrResourceChange()
func testAcceptedTransactionsApplyInSubmissionOrderAtOneFixedStepBoundary()
func testInvalidCommandHasStructuredRejectionInNextFrame()
```

- [ ] **Step 2: Run transaction tests**

Run: `swift test --filter 'WorldTransactionTests|TransactionStagerTests'`
Expected: FAIL because staging does not exist.

- [ ] **Step 3: Implement `WorldTransaction` and internal `TransactionStager.stage`**

Expose fluent value-building methods `add`, `remove`, `replace`, `updatePhysicsMaterial`, `updateRenderStyle`, `setMotion`, `setGlobalForce`, `applyImpulse`, `beginPlayerDrive`, `updatePlayerDrive`, `endPlayerDrive`, `startTransition`, `mergeBubbles`, `splitBubble`, and `replacePolygons`. Implement `TransactionStager.stage(_ transaction: WorldTransaction, against state: RuntimeState) throws -> StagedWorldChange`; it validates every operation against one prospective state and returns nothing publishable on any error.

- [ ] **Step 4: Run transaction tests**

Run: `swift test --filter 'WorldTransactionTests|TransactionStagerTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysicsPublic Sources/BubblePhysicsRuntime Tests/BubblePhysicsPublicTests/WorldTransactionTests.swift Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift
git commit -m "feat: add atomic world transactions"
```

### Task 4: Implement `BubbleWorld`, fixed time and explicit diagnostics

**Files:**
- Create: `Sources/BubblePhysicsPublic/BubbleWorld.swift`
- Create: `Sources/BubblePhysicsPublic/Diagnostics.swift`
- Create: `Sources/BubblePhysicsRuntime/FixedStepDriver.swift`
- Test: `Tests/BubblePhysicsPublicTests/BubbleWorldTimeTests.swift`
- Test: `Tests/BubblePhysicsRuntimeTests/FixedStepDriverTests.swift`

**Interfaces:**
- Consumes: `WorldTransaction`, `WorldFrame`, `TransactionStager` from Task 3.
- Produces: `@MainActor public final class BubbleWorld`, `submit(_:)`, `advance(by:)`, `pause()`, `resume()`, `WorldDiagnostics`.

- [ ] **Step 1: Write failing fixed-step tests**

```swift
func testAdvanceAccumulatesPresentationTimeIntoDeterministicFixedSteps()
func testTransactionsPublishOnlyAtFixedStepBoundary()
func testPausePreventsStepsButKeepsQueuedTransaction()
func testPersistentBacklogIsReportedWithoutChangingConfiguredStep()
```

- [ ] **Step 2: Run time tests**

Run: `swift test --filter 'BubbleWorldTimeTests|FixedStepDriverTests'`
Expected: FAIL because `BubbleWorld` does not exist.

- [ ] **Step 3: Implement the public world façade**

Define `init(configuration: WorldConfiguration, device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws`, `submit(_:) -> TransactionToken`, and `advance(by seconds: TimeInterval) async -> WorldFrame`. The runtime uses a fixed `configuration.fixedTimeStep`, applies staged transactions immediately before that step, and places all unsimulated excess in `WorldDiagnostics.backlogSeconds`; it must never change runtime solver settings to catch up.

- [ ] **Step 4: Run time tests and the old native lifecycle tests**

Run: `swift test --filter 'BubbleWorldTimeTests|FixedStepDriverTests|NativeMetalSolverLifecycleTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysicsPublic Sources/BubblePhysicsRuntime Tests/BubblePhysicsPublicTests/BubbleWorldTimeTests.swift Tests/BubblePhysicsRuntimeTests/FixedStepDriverTests.swift
git commit -m "feat: add fixed-step BubbleWorld facade"
```

### Task 5: Adapt region policy, ordinary polygon geometry and shared resources to GPU-native state

**Files:**
- Modify: `Sources/BubblePhysicsRuntime/TransactionStager.swift`
- Create: `Sources/BubblePhysicsRuntime/RegionPolicy.swift`
- Modify: `Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- Modify: `Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- Modify: `Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- Test: `Tests/BubblePhysicsRuntimeTests/RegionPolicyTests.swift`
- Test: `Tests/BubblePhysicsNativeMetalTests/NativeMetalPublicObjectTests.swift`

**Interfaces:**
- Consumes: `StagedWorldChange`, object descriptors and fixed-step driver.
- Produces: runtime support for static/dynamic polygon objects, resource updates, `.remove`/`.wrap`, and `WorldEvent.didExitSimulationRegion`/`.didWrap`.

- [ ] **Step 1: Write failing region and resource tests**

```swift
func testRemovalWaitsUntilEntireColliderLeavesRegion()
func testWrapPreservesVelocityAndDoesNotCreateSeamContact()
func testMaterialUpdateAffectsEveryReferencingObjectOnNextCompleteFrame()
```

- [ ] **Step 2: Run focused tests**

Run: `swift test --filter 'RegionPolicyTests|NativeMetalPublicObjectTests'`
Expected: FAIL because runtime has only reference bubbles/segments.

- [ ] **Step 3: Extend private packed state and shaders**

Add opaque runtime records for object kind, region policy, material/style index and polygon body state. Upload only staged changes, rebuild collision data only when a changed polygon requires it, and evaluate complete-collider removal/wrap after solve. Do not expose these layouts outside `BubblePhysicsNativeMetal`.

- [ ] **Step 4: Run focused and regression tests**

Run: `swift test --filter 'RegionPolicyTests|NativeMetalPublicObjectTests|NativeMetalContactPipelineTests|NativeMetalSafetyTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysicsRuntime Sources/BubblePhysicsNativeMetal Tests/BubblePhysicsRuntimeTests/RegionPolicyTests.swift Tests/BubblePhysicsNativeMetalTests/NativeMetalPublicObjectTests.swift
git commit -m "feat: stage public objects in native runtime"
```

### Task 5B: Add GPU-native rigid polygon bodies and bidirectional contacts

**Why this gate was added:** Implementation of Task 5 exposed that the native solver represents polygons only as zero-mass segments. That is sufficient for static obstacles but cannot satisfy the approved contract for `dynamic`/`motorDriven` polygons. This gate closes that architectural gap before drives or fields can claim to affect such objects.

**Files:**
- Create: `Sources/BubblePhysicsNativeMetal/NativeRigidPolygonState.swift`
- Modify: `Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- Modify: `Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- Modify: `Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- Modify: `Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- Modify: `Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- Modify: `Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- Test: `Tests/BubblePhysicsNativeMetalTests/NativeMetalRigidPolygonTests.swift`
- Test: `Tests/BubblePhysicsRuntimeTests/RigidPolygonRuntimeTests.swift`

**Interfaces:**
- Consumes: the Task-5A public object mapping and `PolygonDescriptor` geometry.
- Produces: opaque native rigid-body records with stable `ObjectID`, inverse mass, inverse moment, pose, linear/angular velocity and convex collision pieces; bidirectional bubble↔polygon contact response; runtime acceptance of `.dynamic` and `.motorDriven` polygon roles.

- [ ] **Step 1: Write failing rigid-polygon tests**

```swift
func testDynamicPolygonReceivesTranslationAndRotationFromBubbleImpact()
func testStaticPolygonDoesNotMoveUnderSameImpact()
func testConcavePolygonUsesInternalConvexPiecesWithoutPublicDecomposition()
func testPolygonContactPreservesFiniteStateAndDoesNotMoveThroughStaticWall()
```

- [ ] **Step 2: Run focused tests to verify failure**

Run: `swift test --filter 'NativeMetalRigidPolygonTests|RigidPolygonRuntimeTests'`
Expected: FAIL because dynamic/motor polygon roles are currently rejected.

- [ ] **Step 3: Add private rigid-body and convex-piece GPU storage**

Use `ObjectID` only for identity. Compute mass properties and decompose valid concave input internally before GPU upload. Keep body/vertex/manifold layout private; upload staged changes only and preserve existing static segment behavior.

- [ ] **Step 4: Implement bidirectional narrow phase and Jacobi corrections**

For bubble↔convex-polygon contacts, apply position and velocity/angular corrections weighted by inverse mass and inverse moment. Static bodies have zero inverse mass/moment. Produce no public manifold/cache type and retain the native solver's finite-state/containment guards.

- [ ] **Step 5: Accept runtime roles only after native representation exists**

Remove the Task-5A structured rejection for `.dynamic` and `.motorDriven` polygons only after their frame update and contacts are covered by the tests. Keep `pathDriven` and `playerDriven` for Task 6.

- [ ] **Step 6: Verify and commit**

Run: `swift test`
Expected: PASS.

Run on iPhone X: a Release stress/interaction smoke containing moving and rotating polygons, with zero fallback, containment and non-finite state.
Expected: native quality envelope passes; record a device report before proceeding to Task 6.

```bash
git add Sources/BubblePhysicsNativeMetal Sources/BubblePhysicsRuntime Tests/BubblePhysicsNativeMetalTests Tests/BubblePhysicsRuntimeTests
git commit -m "feat: add native rigid polygon bodies"
```

### Task 6: Implement motion roles, drives, fields and physical transitions

**Files:**
- Create: `Sources/BubblePhysicsPublic/Motion.swift`
- Create: `Sources/BubblePhysicsRuntime/MotionControllers.swift`
- Modify: `Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- Modify: `Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- Test: `Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- Test: `Tests/BubblePhysicsNativeMetalTests/NativeMetalMotionRoleTests.swift`

**Interfaces:**
- Consumes: active objects from Task 5.
- Produces: `PlayerDriveID`, `DriveFeedback`, `PathDrive`, `MotorDrive`, global force and directional/radial/vortex fields.

- [ ] **Step 1: Write failing behavior tests**

```swift
func testPlayerDrivenBubbleTransitionsToEffectiveRigidCircleThenRelaxesAfterRelease()
func testBlockedPlayerDriveReportsAchievedPointAndBlockerWithoutTeleporting()
func testDynamicAndMotorDrivenReceiveFieldsWhileActivePlayerDriveDoesNot()
func testDynamicPolygonCanTranslateAndRotateAfterBubbleImpact()
func testPathDrivenStopsAtUnresolvableBlocker()
```

- [ ] **Step 2: Run motion tests**

Run: `swift test --filter 'MotionCommandTests|NativeMetalMotionRoleTests'`
Expected: FAIL because public motion roles do not drive the native solver.

- [ ] **Step 3: Implement controllers as private force/constraint sources**

Implement each public role in the runtime, preserving collision resolution as final authority. When a soft bubble begins a player drive, capture its effective support radius and interpolate its representation over `rigidificationDuration`; after ending, interpolate back according to descriptor policy. Apply global/local fields only to `.dynamic` and `.motorDriven`. Compute `DriveFeedback` every published frame for active drives, not as an event.

- [ ] **Step 4: Run motion and contact regressions**

Run: `swift test --filter 'MotionCommandTests|NativeMetalMotionRoleTests|NativeMetalXPBDTests|NativeMetalContactPipelineTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysicsPublic Sources/BubblePhysicsRuntime Sources/BubblePhysicsNativeMetal Tests/BubblePhysicsPublicTests/MotionCommandTests.swift Tests/BubblePhysicsNativeMetalTests/NativeMetalMotionRoleTests.swift
git commit -m "feat: add public motion roles and force fields"
```

### Task 7: Add opt-in events, sensors and merge candidate detection

**Files:**
- Create: `Sources/BubblePhysicsPublic/Events.swift`
- Create: `Sources/BubblePhysicsRuntime/EventCompactor.swift`
- Modify: `Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- Modify: `Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- Modify: `Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- Test: `Tests/BubblePhysicsPublicTests/EventInterestTests.swift`
- Test: `Tests/BubblePhysicsNativeMetalTests/NativeMetalEventCompactionTests.swift`

**Interfaces:**
- Consumes: objects/motion from Tasks 5–6.
- Produces: `EventInterest`, `WorldEvent`, `WorldEventOverflow`, sensor enter/exit and `mergeContact` records in `WorldFrame.events`.

- [ ] **Step 1: Write failing filtering and overflow tests**

```swift
func testNoContactEventIsPublishedWithoutInterest()
func testMergeContactRequiresBothInterestAndOverlappingUInt64GroupBit()
func testSensorPublishesOnlyEnterAndExit()
func testEventBufferOverflowIsReportedInsteadOfSilentlyDroppingIt()
```

- [ ] **Step 2: Run event tests**

Run: `swift test --filter 'EventInterestTests|NativeMetalEventCompactionTests'`
Expected: FAIL because events are not modeled in public world state.

- [ ] **Step 3: Implement bounded GPU compaction and typed frame events**

Add one explicit `WorldConfiguration.eventBufferCapacity`. Filter candidates on GPU by per-object interest and `MergeGroupSet` overlap, compact only selected records, and read back only the bounded compacted sequence and overflow counter at frame publication. Maintain private previous-overlap state for sensors. `driveBlocked` is emitted only when the relevant interest is enabled; `DriveFeedback` remains independent.

- [ ] **Step 4: Run event and broad-phase regressions**

Run: `swift test --filter 'EventInterestTests|NativeMetalEventCompactionTests|NativeMetalBroadPhaseTests|NativeMetalContactCacheTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysicsPublic Sources/BubblePhysicsRuntime Sources/BubblePhysicsNativeMetal Tests/BubblePhysicsPublicTests/EventInterestTests.swift Tests/BubblePhysicsNativeMetalTests/NativeMetalEventCompactionTests.swift
git commit -m "feat: add opt-in world events and sensors"
```

### Task 8: Implement transitions and semantic merge/split operations

**Files:**
- Create: `Sources/BubblePhysicsPublic/Transitions.swift`
- Create: `Sources/BubblePhysicsRuntime/StructuralOperations.swift`
- Modify: `Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- Modify: `Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- Test: `Tests/BubblePhysicsPublicTests/TransitionTests.swift`
- Test: `Tests/BubblePhysicsNativeMetalTests/NativeMetalStructuralOperationTests.swift`

**Interfaces:**
- Consumes: transactions and native object state from Tasks 3–7.
- Produces: `ParameterTransition`, serializable `TransitionCurve`, typed bubble split/merge requests and polygon replacement confirmations.

- [ ] **Step 1: Write failing transition and structural-operation tests**

```swift
func testNewTransitionForSameParameterReplacesPriorTransitionDeterministically()
func testBubbleSplitConservesConfiguredSizeSharesAndProducesSeparatedTransientShapes()
func testBubbleMergeCarriesMomentumAndStartsAtContactRegion()
func testPolygonReplacementIsAtomicAndRebuildsOnlyAffectedCollisionState()
```

- [ ] **Step 2: Run transition tests**

Run: `swift test --filter 'TransitionTests|NativeMetalStructuralOperationTests'`
Expected: FAIL because transition scheduling and semantic operations do not exist.

- [ ] **Step 3: Implement simulation-time transition scheduler and structural staging**

Support `linear`, named easing and cubic Bézier curves as codable values. Schedule material/world/style/local presentation/target-radius channels by simulation time; a new same-target `ParameterID` replaces the old entry. For bubble operations, create GPU-native transient contours and transfer mass/momentum before invalidating only relevant contacts. For polygon operations, accept game-supplied descriptors and use the existing all-or-nothing stager; do not infer fracture lines.

- [ ] **Step 4: Run transition, contour and quality-envelope tests**

Run: `swift test --filter 'TransitionTests|NativeMetalStructuralOperationTests|NativeMetalContourTests|NativeMetalQualityEnvelopeTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysicsPublic Sources/BubblePhysicsRuntime Sources/BubblePhysicsNativeMetal Tests/BubblePhysicsPublicTests/TransitionTests.swift Tests/BubblePhysicsNativeMetalTests/NativeMetalStructuralOperationTests.swift
git commit -m "feat: add transitions and semantic bubble operations"
```

### Task 9: Provide direct Metal rendering and prove the production path

**Files:**
- Create: `Sources/BubblePhysicsMetalRender/BubblePhysicsMetalRender.swift`
- Create: `Sources/BubblePhysicsMetalRender/RenderStylePipeline.swift`
- Modify: `Package.swift`
- Modify: `Sources/BubblePhysicsRuntime/FixedStepDriver.swift`
- Modify: `Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- Modify: `Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- Create: `Sources/BubblePhysicsNativeMetal/Shaders/NativeRenderKernels.metal-source`
- Test: `Tests/BubblePhysicsMetalRenderTests/MetalRenderIntegrationTests.swift`
- Test: `Tests/BubblePhysicsNativeMetalTests/NativeMetalRenderHandoffTests.swift`
- Modify: `Benchmarks/iOS/BubblePhysicsBench/*` (replace diagnostic CPU contour presentation only for the public API demonstration)

**Interfaces:**
- Consumes: published runtime frame from Tasks 4–8.
- Produces: `BubblePhysicsMetalRender`, `encode(world:viewport:commandBuffer:renderPassDescriptor:) throws`, optional CPU debug snapshot adapter.

- [ ] **Step 1: Write failing render-handoff tests**

```swift
func testRendererUsesPublishedNativeBuffersWithoutContourCPUReadback()
func testRendererAcceptsViewportAndCallerCommandBuffer()
func testTechnicalStyleRendersWithoutGamePipelineAndCustomPipelineReceivesStyleChannels()
```

- [ ] **Step 2: Run renderer tests**

Run: `swift test --filter 'MetalRenderIntegrationTests|NativeMetalRenderHandoffTests'`
Expected: FAIL because the native runner commits its own buffer and only exposes CPU contour data.

- [ ] **Step 3: Split private native submission into encode and publication phases**

Replace the current internal “encode, await, publish” monolith with an opaque published-buffer handoff. `BubbleWorld.advance` encodes physics to the app-provided command buffer when rendering is requested; publication occurs only after completion and retains the old complete frame on failure. `BubblePhysicsMetalRender` encodes contour/render work after physics against that opaque handoff. It must not expose `MTLBuffer` or native structs through the gameplay module.

- [ ] **Step 4: Implement renderer API and debug adapter**

Expose the renderer in a separate product, accept caller-owned `MTLCommandBuffer`, `MTLRenderPassDescriptor`, `Viewport` and optional custom pipeline/style resolver. Ship only a neutral technical preview style. Keep CPU contour snapshots behind a clearly named debug/adapter API and do not call it from the benchmark render path.

- [ ] **Step 5: Run tests, build and device gate**

Run: `swift test`
Expected: PASS.

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer xcodebuild -project Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj -scheme BubblePhysicsBench -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
Expected: SUCCESS.

Run on physical iPhone X: Release `stress-300`, limit 4, with public world plus direct renderer, 30 warm-up and 300 measured frames.
Expected: zero fallback/containment/non-finite, `native_quality_envelope=pass`, no contour CPU readback in production trace, and p95 no worse than CEO-accepted `10.4568 ms` without explicit CEO approval.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/BubblePhysicsMetalRender Sources/BubblePhysicsRuntime Sources/BubblePhysicsNativeMetal Tests/BubblePhysicsMetalRenderTests Tests/BubblePhysicsNativeMetalTests Benchmarks/iOS/BubblePhysicsBench
git commit -m "feat: add direct Metal renderer for public world"
```

## Self-review

1. **Spec coverage:** World/region/viewport (Tasks 2, 4, 5); all object kinds and roles (Tasks 2, 5, 6); resources and parameter transitions (Tasks 2, 3, 8); atomic transactions/time/pause (Tasks 3, 4); force/drive feedback (Task 6); sensors/events/merge masks (Task 7); semantic bubble and polygon operations (Task 8); direct Metal rendering (Task 9). Out-of-scope items remain excluded.
2. **Step scan:** Every task starts with a named failing test, has an exact focused command, specifies the introduced interface, and ends with a dedicated commit.
3. **Type consistency:** `BubbleWorld` owns `WorldTransaction` submission and emits `WorldFrame`; `TransactionStager` creates `StagedWorldChange`; `BubblePhysicsMetalRender` consumes only a published world/runtime handoff. Public object/resource IDs are introduced before all commands that use them.
4. **Review focus:** The five high-risk input classes map respectively to Tasks 3, 5, 7, 6 and 9.
5. **Proportion:** The plan names contracts and verification but deliberately does not prescribe shader bodies, collision decomposition algorithms, or solver kernels; those remain implementation choices behind tested semantics.
