# Massless Surface Sensors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zbudować pierwszy wiarygodny prototyp pojedynczej deformowalnej bańki, której ruch wynika z jednej centralnej masy, a kształt z bezmasowych czujników radialnych.

**Architecture:** Stan dynamiczny bańki zostanie rozdzielony na centralne ciało sztywne i cykliczne pole bezmasowych czujników. Najpierw powstanie deterministyczny model referencyjny CPU, następnie jego odpowiednik Metal i osobna scena jednej bańki na iPhone. Obecny solver masowych punktów nie będzie używany przez nowy prototyp.

**Tech Stack:** Swift 5, XCTest, Metal compute, MetalKit, Swift Package Manager, iOS benchmark app.

**Spec:** `docs/superpowers/specs/2026-10-01-massless-surface-sensors-design.md`

## Global Constraints

- Pierwszy etap obejmuje dokładnie jedną bańkę, granice planszy i jeden kinematyczny wielokąt.
- Jedynym stanem masowym bańki jest centralne ciało; czujniki powierzchni są bezmasowe.
- Długość radialna czujnika nigdy nie jest ujemna, ale nie ma dodatniego minimalnego promienia.
- Pole powierzchni nie jest zachowywane ani ograniczane.
- Nowa bańka zaczyna z długościami radialnymi równymi zero lub bliskimi zeru i rośnie kontrolowanie.
- Liczba czujników wynika z bieżącego obwodu i maksymalnej długości segmentu; model domenowy nie ma arbitralnego górnego limitu `N`.
- Docelowym urządzeniem walidacyjnym jest iPhone X; obsługa macOS nie jest wymaganiem produktu.
- Ocena wiarygodności wizualnej na fizycznym iPhonie X należy do CEO.
- Nie dodawać zależności zewnętrznych.

## Review Focus

- Zerowy promień narodzin: kierunki i kontakty pozostają skończone, a wzrost rozpoczyna się symetrycznie — test w Task 2.
- Ekstremalne przyszpilenie do rogu: długości mogą zbliżyć się do zera bez NaN, wartości ujemnych i wybuchu energii — test w Task 4.
- Symetryczny nacisk: nie generuje translacji poprzecznej ani momentu obrotowego — test w Task 3.
- Zmiana `N` podczas deformacji: resampling zachowuje średni promień, orientację i gładkość na szwie 0/2π — test w Task 5.
- Wielokrotna kolejność kontaktów: redukcja daje ten sam wynik niezależnie od kolejności wejścia — testy CPU w Task 3 i GPU w Task 6.
- Cykliczna zmiana numeracji czujników nie zmienia ruchu centralnej masy ani ewolucji kształtu po odpowiednim przesunięciu indeksów — test w Task 4.

---

### Task 1: Przywrócenie czystej bazy po nieudanym eksperymencie

**Files:**
- Restore to `f25e3cf`: `Sources/BubblePhysics/BubbleWorld.swift`
- Restore to `f25e3cf`: `Sources/BubblePhysics/PrototypeScene.swift`
- Restore to `f25e3cf`: `Sources/BubblePhysicsMetal/MetalBubbleSolver.swift`
- Restore to `f25e3cf`: `Sources/BubblePhysicsMetal/Shaders/BubblePhysicsKernels.metal`
- Restore to `f25e3cf`: `Sources/BubblePhysicsMetal/Shaders/ContourContactKernels.metal`
- Restore to `f25e3cf`: `Tests/BubblePhysicsMetalTests/MetalPackedSceneTests.swift`
- Restore to `f25e3cf`: `Tests/BubblePhysicsTests/BubbleWorldTests.swift`
- Preserve untouched: `Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj/project.pbxproj` and all Xcode user-data artifacts.

**Interfaces:**
- Consumes: committed baseline `f25e3cf`.
- Produces: working tree without the uncommitted point-mass-solver experiments from the interrupted debugging turn.

- [ ] **Step 1: Inspect the exact uncommitted diff**

Run: `git diff -- Sources/BubblePhysics/BubbleWorld.swift Sources/BubblePhysics/PrototypeScene.swift Sources/BubblePhysicsMetal/MetalBubbleSolver.swift Sources/BubblePhysicsMetal/Shaders/BubblePhysicsKernels.metal Sources/BubblePhysicsMetal/Shaders/ContourContactKernels.metal Tests/BubblePhysicsMetalTests/MetalPackedSceneTests.swift Tests/BubblePhysicsTests/BubbleWorldTests.swift`

Expected: only the abandoned initial-scale, Jacobi-spring, contact-clamp and contour-regression experiments.

- [ ] **Step 2: Reverse only those hunks with `apply_patch`**

Do not modify the Xcode project or untracked user files. Verify the seven listed files match `git show f25e3cf:<path>` byte-for-byte.

- [ ] **Step 3: Run the committed baseline test suite**

Run: `swift test --skip BenchmarkScenarioTests`

Expected: 144 tests pass, zero failures.

- [ ] **Step 4: Verify cleanup state**

Run: `git status --short`

Expected: no modifications in the seven restored files; pre-existing Xcode project and user-data changes remain visible and untouched.

No commit is required because this task removes uncommitted experiments.

### Task 2: Domena centralnej masy i bezmasowych czujników

**Files:**
- Create: `Sources/BubblePhysics/RadialBubbleState.swift`
- Create: `Tests/BubblePhysicsTests/RadialBubbleStateTests.swift`

**Interfaces:**
- Consumes: `Vector2`, `SpringMaterial`.
- Produces: `RadialBubbleBody`, `RadialSurfaceSensor`, `RadialBubbleState`, `RadialBubbleState.surfacePoint(at:)`, `RadialBubbleState.surfacePoints`.

- [ ] **Step 1: Write failing construction and geometry tests**

Add tests named:

- `testCollapsedBubbleHasOneMassBodyAndMasslessCoincidentSensors`
- `testSurfacePointsComeOnlyFromBodyPoseAndRadialLengths`
- `testNegativeSensorLengthIsClampedToZero`
- `testChangingBodyPoseRigidlyTransformsEverySurfacePoint`
- `testChangingTargetRadiusDoesNotInstantlyScaleCurrentSurface`

Assert that a bubble created by
`RadialBubbleState.collapsed(id:center:targetRadius:maxSegmentLength:mass:)`
starts with one body at `center`, at least 8 sensors, zero sensor lengths and
finite surface points equal to the center.

- [ ] **Step 2: Run tests to verify RED**

Run: `swift test --filter RadialBubbleStateTests`

Expected: compile failure because the radial state types do not exist.

- [ ] **Step 3: Implement the domain types**

In `RadialBubbleState.swift` define:

```swift
public struct RadialBubbleBody: Equatable, Sendable
public struct RadialSurfaceSensor: Equatable, Sendable
public struct RadialBubbleState: Equatable, Sendable

public static func collapsed(
    id: BubbleID,
    center: Vector2,
    targetRadius: Float,
    maxSegmentLength: Float,
    mass: Float
) -> RadialBubbleState

public func surfacePoint(at sensorIndex: Int) -> Vector2
public var surfacePoints: [Vector2] { get }
```

`RadialBubbleBody` stores center, linear velocity, angle, angular velocity, mass
and moment of inertia. `RadialBubbleState` stores target radius and birth/resize
progress separately from current geometry, so future merge and split operations
can create collapsed successors without teleporting their contours.
`RadialSurfaceSensor` stores material angle, current
length, radial velocity, target length and pressure. Sensor count is
`max(8, ceil(2π * currentRadius / maxSegmentLength))`; the collapsed constructor
uses 8 sensors as the seed topology.

- [ ] **Step 4: Run tests to verify GREEN**

Run: `swift test --filter RadialBubbleStateTests`

Expected: all five tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysics/RadialBubbleState.swift Tests/BubblePhysicsTests/RadialBubbleStateTests.swift
git commit -m "feat: add massless radial bubble state"
```

### Task 3: Deterministyczna redukcja nacisków do siły i momentu

**Files:**
- Create: `Sources/BubblePhysics/RadialContactResponse.swift`
- Create: `Tests/BubblePhysicsTests/RadialContactResponseTests.swift`

**Interfaces:**
- Consumes: `RadialBubbleState` from Task 2.
- Produces: `RadialSurfaceContact`, `RadialBodyLoad`, `RadialContactResponse.reduce(contacts:for:)`.

- [ ] **Step 1: Write failing response tests**

Add tests named:

- `testSingleSurfaceContactCompressesSensorAndPushesBodyAlongNormal`
- `testOffCenterContactProducesTorque`
- `testSymmetricOpposingContactsProduceNoNetForceOrTorque`
- `testContactReductionIsIndependentOfInputOrder`

Use exact tolerances `1e-5` for force and torque comparisons. The order test
must evaluate all permutations of three contacts with stable `sourceID` values.

- [ ] **Step 2: Run tests to verify RED**

Run: `swift test --filter RadialContactResponseTests`

Expected: compile failure because contact response types do not exist.

- [ ] **Step 3: Implement contact records and deterministic reduction**

Define:

```swift
public struct RadialSurfaceContact: Equatable, Sendable
public struct RadialBodyLoad: Equatable, Sendable
public enum RadialContactResponse {
    public static func reduce(
        contacts: [RadialSurfaceContact],
        for bubble: RadialBubbleState
    ) -> RadialBodyLoad
}
```

Sort by `sourceID`, distribute penetration and pressure barycentrically between
neighboring sensors, sum `force`, and calculate torque as the 2D cross product
of contact arm and force. The reducer returns sensor pressure deltas separately
from body force and torque.

- [ ] **Step 4: Run tests to verify GREEN**

Run: `swift test --filter RadialContactResponseTests`

Expected: all four tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysics/RadialContactResponse.swift Tests/BubblePhysicsTests/RadialContactResponseTests.swift
git commit -m "feat: reduce radial contacts to body loads"
```

### Task 4: Narodziny i stabilna radialna dynamika referencyjna

**Files:**
- Create: `Sources/BubblePhysics/RadialBubbleIntegrator.swift`
- Create: `Tests/BubblePhysicsTests/RadialBubbleIntegratorTests.swift`

**Interfaces:**
- Consumes: state from Task 2 and loads from Task 3.
- Produces: `RadialBubbleMaterial`, `RadialBubbleIntegrator.step(state:load:deltaTime:)`.

- [ ] **Step 1: Write failing integration tests**

Add tests named:

- `testCollapsedBubbleBeginsGrowingSymmetricallyAndStaysFinite`
- `testUnloadedBubbleConvergesTowardTargetRadiusWithoutOvershootExplosion`
- `testLocalPressureCreatesSmoothLocalIndentation`
- `testReleasedIndentationRecoversWithDecreasingEnergy`
- `testSymmetricPressureDoesNotTranslateOrRotateBody`
- `testCornerPinCanApproachZeroRadiusWithoutGoingNegativeOrNonFinite`
- `testCyclicSensorRenumberingProducesEquivalentEvolution`

For 600 steps at `1/60`, assert every scalar remains finite, every radial length
is `>= 0`, and the energy envelope after pressure release is non-increasing over
successive 30-frame windows.

- [ ] **Step 2: Run tests to verify RED**

Run: `swift test --filter RadialBubbleIntegratorTests`

Expected: compile failure because the integrator does not exist.

- [ ] **Step 3: Implement material and fixed-step integrator**

Define:

```swift
public struct RadialBubbleMaterial: Equatable, Sendable
public enum RadialBubbleIntegrator {
    public static func step(
        state: inout RadialBubbleState,
        load: RadialBodyLoad,
        deltaTime: Float
    )
}
```

Use semi-implicit integration for body translation and rotation. Update all
sensor radii from the same pre-step snapshot (Jacobi), using a nonlinear radial
restoring force, damping and a periodic neighbor Laplacian. Clamp only the final
radial length to zero. Birth progress changes target lengths continuously rather
than teleporting surface points.

- [ ] **Step 4: Run tests to verify GREEN**

Run: `swift test --filter RadialBubbleIntegratorTests`

Expected: all seven tests pass.

- [ ] **Step 5: Run all CPU physics tests**

Run: `swift test --filter BubblePhysicsTests`

Expected: zero failures.

- [ ] **Step 6: Commit**

```bash
git add Sources/BubblePhysics/RadialBubbleIntegrator.swift Tests/BubblePhysicsTests/RadialBubbleIntegratorTests.swift
git commit -m "feat: integrate radial bubble birth and deformation"
```

### Task 5: Adaptacyjne `N` i zachowanie deformacji

**Files:**
- Create: `Sources/BubblePhysics/RadialSensorRemesher.swift`
- Create: `Tests/BubblePhysicsTests/RadialSensorRemesherTests.swift`

**Interfaces:**
- Consumes: `RadialBubbleState` from Task 2.
- Produces: `RadialSensorRemesher.requiredCount(for:maxSegmentLength:)` and `RadialSensorRemesher.resample(_:to:)`.

- [ ] **Step 1: Write failing remeshing tests**

Add tests named:

- `testRequiredCountTracksCurrentCircumferenceWithoutMaximumCap`
- `testCollapsedBubbleUsesEightSensors`
- `testResamplingPreservesMeanRadiusAndBodyPose`
- `testResamplingInterpolatesIndentationAcrossAngularSeam`
- `testRepeatedUpAndDownSamplingDoesNotCreateVisibleEnergy`

Use a synthetic indentation centered at material angle `0`; after resampling,
compare values immediately below and above `2π` with tolerance `1e-4`.

- [ ] **Step 2: Run tests to verify RED**

Run: `swift test --filter RadialSensorRemesherTests`

Expected: compile failure because the remesher does not exist.

- [ ] **Step 3: Implement periodic resampling**

Define:

```swift
public enum RadialSensorRemesher {
    public static func requiredCount(
        for state: RadialBubbleState,
        maxSegmentLength: Float
    ) -> Int
    public static func resample(
        _ state: RadialBubbleState,
        to count: Int
    ) -> RadialBubbleState
}
```

Interpolate radial length, radial velocity, target length and pressure on a
periodic angular domain. Preserve body state byte-for-byte. If the required GPU
buffer cannot be allocated, return an explicit resource error instead of
silently capping `N` or lowering contour quality.

- [ ] **Step 4: Run tests to verify GREEN**

Run: `swift test --filter RadialSensorRemesherTests`

Expected: all five tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/BubblePhysics/RadialSensorRemesher.swift Tests/BubblePhysicsTests/RadialSensorRemesherTests.swift
git commit -m "feat: adapt radial surface sensor count"
```

### Task 6: Bufory i kernela Metal dla jednej bańki

**Files:**
- Create: `Sources/BubblePhysicsMetal/Radial/MetalRadialBufferLayout.swift`
- Create: `Sources/BubblePhysicsMetal/Radial/MetalRadialSimulation.swift`
- Create: `Sources/BubblePhysicsMetal/Shaders/RadialBubbleKernels.metal`
- Create: `Tests/BubblePhysicsMetalTests/MetalRadialSimulationTests.swift`

**Interfaces:**
- Consumes: CPU types and update rules from Tasks 2–5.
- Produces: `MetalRadialSimulation`, `MetalRadialFrameResources`, GPU kernels `radialPredictBody`, `radialBuildSurface`, `radialReduceContacts`, `radialIntegrateSurface`.

- [ ] **Step 1: Write failing CPU/GPU parity tests**

Add tests named:

- `testMetalBirthMatchesCPUReferenceForTenSteps`
- `testMetalSymmetricPressureProducesNoTorque`
- `testMetalContactOrderDoesNotChangeReducedLoad`
- `testMetalExtremeCompressionStaysFiniteAndNonnegative`
- `testMetalBuffersSupportSensorCountAboveSixtyFour`

Compare center, angle and every radial length after 10 fixed steps with tolerance
`2e-3`. The last test uses 257 sensors.

- [ ] **Step 2: Run tests to verify RED**

Run: `swift test --filter MetalRadialSimulationTests`

Expected: compile failure because Metal radial types do not exist.

- [ ] **Step 3: Implement GPU buffer records**

Define fixed-layout records corresponding to `RadialBubbleBody`,
`RadialSurfaceSensor`, contact input, reduced force/torque and frame resources.
Add `MemoryLayout` assertions to `MetalRadialSimulationTests`.

- [ ] **Step 4: Implement deterministic Metal passes**

Create kernels named in the Interfaces block. Surface integration reads one
immutable pre-step sensor buffer and writes a second buffer. Contact reduction
sorts or uses stable integer accumulation keyed by `sourceID`; it must not rely
on unordered floating-point atomics.

- [ ] **Step 5: Run parity tests to verify GREEN**

Run: `swift test --filter MetalRadialSimulationTests`

Expected: all five tests pass and the command buffers finish with `.completed`.

- [ ] **Step 6: Run Metal regression suite**

Run: `swift test --filter BubblePhysicsMetalTests --skip BenchmarkScenarioTests`

Expected: zero failures.

- [ ] **Step 7: Commit**

```bash
git add Sources/BubblePhysicsMetal/Radial Sources/BubblePhysicsMetal/Shaders/RadialBubbleKernels.metal Tests/BubblePhysicsMetalTests/MetalRadialSimulationTests.swift
git commit -m "feat: run radial bubble dynamics on Metal"
```

### Task 7: Kontakty ze ścianami i kinematycznym wielokątem

**Files:**
- Create: `Sources/BubblePhysics/RadialEnvironmentContacts.swift`
- Create: `Sources/BubblePhysicsMetal/Shaders/RadialContactKernels.metal`
- Modify: `Sources/BubblePhysicsMetal/Radial/MetalRadialSimulation.swift`
- Create: `Tests/BubblePhysicsTests/RadialEnvironmentContactTests.swift`
- Create: `Tests/BubblePhysicsMetalTests/MetalRadialEnvironmentTests.swift`

**Interfaces:**
- Consumes: radial contour and GPU simulation from Tasks 2–6; existing `AABB` and `SimulationPolygonSnapshot`.
- Produces: CPU reference `RadialEnvironmentContacts.generate(...)` and equivalent GPU contact generation.

- [ ] **Step 1: Write failing CPU contact tests**

Cover left/right/top/bottom walls, a stationary triangle, a translating triangle,
a rotating triangle and a bubble pinned into a corner. Assert normals point out
of obstacles and surface velocity includes polygon linear and angular velocity.

- [ ] **Step 2: Run CPU tests to verify RED**

Run: `swift test --filter RadialEnvironmentContactTests`

Expected: compile failure because the generator does not exist.

- [ ] **Step 3: Implement CPU reference generator**

Define:

```swift
public enum RadialEnvironmentContacts {
    public static func generate(
        bubble: RadialBubbleState,
        bounds: AABB,
        polygons: [SimulationPolygonSnapshot]
    ) -> [RadialSurfaceContact]
}
```

- [ ] **Step 4: Run CPU tests to verify GREEN**

Run: `swift test --filter RadialEnvironmentContactTests`

Expected: all environment contact tests pass.

- [ ] **Step 5: Write and run failing GPU parity tests**

Run: `swift test --filter MetalRadialEnvironmentTests`

Expected: failures because environment contacts are not encoded by the GPU session.

- [ ] **Step 6: Implement GPU wall and polygon contacts**

Generate contacts from radial surface segments, feed them through the Task 6
deterministic reducer, and integrate the body and sensors in the same command buffer.

- [ ] **Step 7: Run GPU tests to verify GREEN**

Run: `swift test --filter MetalRadialEnvironmentTests`

Expected: CPU/GPU contact counts and resulting body loads agree within `2e-3`.

- [ ] **Step 8: Commit**

```bash
git add Sources/BubblePhysics/RadialEnvironmentContacts.swift Sources/BubblePhysicsMetal/Shaders/RadialContactKernels.metal Sources/BubblePhysicsMetal/Radial/MetalRadialSimulation.swift Tests/BubblePhysicsTests/RadialEnvironmentContactTests.swift Tests/BubblePhysicsMetalTests/MetalRadialEnvironmentTests.swift
git commit -m "feat: collide radial bubble with environment"
```

### Task 8: Osobna scena wizualna jednej bańki na iPhone

**Files:**
- Create: `Sources/BubblePhysicsMetal/Radial/MetalRadialRenderer.swift`
- Create: `Benchmarks/iOS/BubblePhysicsBench/App/RadialBubblePrototypeView.swift`
- Modify: `Benchmarks/iOS/BubblePhysicsBench/App/BubblePhysicsBenchApp.swift`
- Create: `Tests/BubblePhysicsMetalTests/MetalRadialRendererTests.swift`

**Interfaces:**
- Consumes: `MetalRadialFrameResources` from Task 6 and environment contacts from Task 7.
- Produces: a selectable `Radial` prototype mode showing one growing bubble, board bounds and the moving triangle.

- [ ] **Step 1: Write failing renderer geometry tests**

Add tests named:

- `testRendererBuildsOrderedFanFromRadialSurface`
- `testCollapsedContourDoesNotProduceNonFiniteVertices`
- `testLabelUsesBodyCenterAndBodyAngle`

- [ ] **Step 2: Run tests to verify RED**

Run: `swift test --filter MetalRadialRendererTests`

Expected: compile failure because the renderer does not exist.

- [ ] **Step 3: Implement radial renderer**

Build a triangle fan from the body center and ordered surface points. Render the
label from body center and angle. Do not use the even-odd stencil workaround,
because the radial contour is star-shaped by construction.

- [ ] **Step 4: Integrate the iOS prototype mode**

Add a `Radial` selector without removing the existing `40` and `300` diagnostic
scenes. The new mode starts with one collapsed bubble and the existing moving
triangle. Reset recreates the collapsed state.

- [ ] **Step 5: Run renderer tests and generic iOS build**

Run: `swift test --filter MetalRadialRendererTests`

Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer xcodebuild -project Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj -scheme BubblePhysicsBench -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`

Expected: tests pass and `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add Sources/BubblePhysicsMetal/Radial/MetalRadialRenderer.swift Benchmarks/iOS/BubblePhysicsBench/App/RadialBubblePrototypeView.swift Benchmarks/iOS/BubblePhysicsBench/App/BubblePhysicsBenchApp.swift Tests/BubblePhysicsMetalTests/MetalRadialRendererTests.swift
git commit -m "feat: add single radial bubble iOS prototype"
```

### Task 9: Telemetria, długi test i przekazanie na iPhone X

**Files:**
- Modify: `Sources/BubblePhysicsMetal/FrameTelemetry.swift`
- Modify: `Benchmarks/iOS/BubblePhysicsBench/App/RadialBubblePrototypeView.swift`
- Create: `Tests/BubblePhysicsMetalTests/MetalRadialEnduranceTests.swift`
- Create: `docs/benchmarks/iphone-x-radial-prototype.md`

**Interfaces:**
- Consumes: complete single-bubble prototype from Task 8.
- Produces: visible radial telemetry and repeatable physical-device acceptance procedure.

- [ ] **Step 1: Write failing endurance test**

Run 10,000 fixed steps alternating free growth, wall compression, triangle pin
and release. Assert ready session status, finite body/sensors, nonnegative radii,
bounded kinetic energy and no buffer overflow.

- [ ] **Step 2: Run endurance test to verify RED or expose defects**

Run: `swift test --filter MetalRadialEnduranceTests`

Expected before completion: at least one acceptance assertion fails until all
phase transitions and telemetry are connected.

- [ ] **Step 3: Add telemetry and finish endurance behavior**

Display FPS, p50, p95, GPU frame time, sensor count, minimum/mean/maximum radial
length, body speed, angular speed, maximum pressure, overflow and non-finite flags.

- [ ] **Step 4: Run complete automated verification**

Run: `swift test --skip BenchmarkScenarioTests`

Run the generic iOS build command from Task 8 in both Debug and Release.

Expected: all tests pass; both builds report `BUILD SUCCEEDED`.

- [ ] **Step 5: Install and launch with Xcode 26.6**

Use `/Applications/Xcode-26.6.app`, destination `iPhone (Mariusz)`. Confirm in
Xcode that the process remains running without Metal runtime issues for at least
60 seconds.

- [ ] **Step 6: Record physical-device acceptance results**

In `docs/benchmarks/iphone-x-radial-prototype.md`, record the telemetry supplied
by the app and CEO's qualitative decision for growth, compression, recovery,
translation and rotation. Do not mark visual physics accepted without CEO input.

- [ ] **Step 7: Commit and push**

```bash
git add Sources/BubblePhysicsMetal/FrameTelemetry.swift Benchmarks/iOS/BubblePhysicsBench/App/RadialBubblePrototypeView.swift Tests/BubblePhysicsMetalTests/MetalRadialEnduranceTests.swift docs/benchmarks/iphone-x-radial-prototype.md
git commit -m "test: validate radial bubble prototype"
git push origin main
```
