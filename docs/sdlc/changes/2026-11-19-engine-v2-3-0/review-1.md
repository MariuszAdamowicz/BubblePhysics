# Review: 2026-11-19-engine-v2-3-0 — run 1

**Date:** 2026-11-19
**Artifact:** review
**Verdict:** APPROVED — no blocking findings
**Rounds:** 1
**Feature artifacts:** change-design.md, plan.md
**Base:** feature/crowd-review-followups
**Base SHA:** a0a77d2c8ca2a9b02e6e32be06c096121e5699a8
**Head SHA:** e38760690c32da9e2c886bfaeee4887e49b77138
**Reviewer model:** sonnet
**Challenger model:** opus
**Brief-writer model:** opus
**Template version:** default/0.2.0

**Plugin version:** 0.7.10
**Agent Sessions:** claude-code: 94ace24f-1fe6-4256-8a0d-a04cb178f0bc

---

## What changed

<!-- brief:what-changed -->
v2.3.0 changes how the native engine handles player drive and soft contact (`change-design.md`, Summary). It adds an optional band mode to `BubbleDrivePolicy`: a grabbed bubble receives a clamped spring force through its mass instead of an overwritten velocity (G1). Contact ρ is computed each step from predicted positions, and the contour depends only on current contacts (G2, G3). Soft contacts get the full XPBD velocity correction and per-contact damping from `contactDampingRatio` (G4).
<!-- /brief:what-changed -->

## Where human judgement is needed

<!-- brief:human-judgement -->
- `NativePostSolveKernels.metal-source:637` (F-2): the structural-result branch was kept on purpose as a second barrier behind the host cache invalidation (`plan.md:560`, deviation 13). You decide whether code that is unreachable by design stays in the kernel.
- `ReferenceSolverInputAdapter.swift:47` (F-1): the reference backend keeps `deformationRecoveryRate` by design (`plan.md:563`, `change-design.md:166`). You decide whether native-vs-reference comparisons may now differ in contour recovery.
- `NativeXPBDKernels.metal-source:1065` (F-5): averaging ζ_c for a soft-hard pair follows CD-D-6 (`change-design.md:196`) but has only an ABI-level test. You decide whether that coverage is enough.
- `RhoGridReportTests.swift:95` (F-6): G2-AC3 defines this as a report without a threshold that the author judges, with scene parameters chosen during implementation (`plan.md:569`). You decide whether the report values are acceptable.
<!-- /brief:human-judgement -->

## What was not verified

<!-- brief:not-verified -->
The tools-verify dimension is a gap: its verify command `przegląd diffu dokumentacji` was not found, exit 127 (`Coverage`, `Gaps`). `change-design.md` and `plan.md` were withheld from every read set (`Gaps`). All seven findings, F-1 to F-7, reached you not challenged, and no fix wave ran (`Findings`, `Fixes`).
<!-- /brief:not-verified -->

---

## Rounds

| Round | Critical | Major | Minor | Action | Fix commits |
|-------|----------|-------|-------|--------|-------------|
| 1 | 0 | 0 | 7 | stop | 0 |

## Findings

Round 1.

| ID | Severity | Verdict | Dimension | Also flagged by | Site | Summary | Effect | Evidence |
|----|----------|---------|-----------|-----------------|------|---------|--------|----------|
| F-2 | minor | not challenged | design | testability | `Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source:637` | nativeUpdateContactRho keeps a nativeIsStructuralResult branch (and the structuralHeaders/contour buffers it needs) that its own comment calls a redundant backstop, since the host already invalidates such cache records; unreachable-by-design code kept in a kernel. | none |  |
| F-4 | minor | not challenged | design | conventions | `Sources/BubblePhysicsPublic/Model/Motion.swift:33` | Band-field validation is hand-written inline guards in BubbleDrivePolicy.init with a garbled, duplicated comment (refers to G1-AC5 and repeats the sentence), while the sibling fields use requirePositive; the stability rule K·dt²/m<1 lives separately in TransactionStager so the policy cannot validate itself. | none |  |
| F-1 | minor | not challenged | contracts |  | `Sources/BubblePhysicsNativeMetalDiagnostics/ReferenceSolverInputAdapter.swift:47` | Adapter drops deformationRecoveryRate when converting a reference configuration to NativeSolverConfiguration, but ReferenceConfiguration and the reference Metal kernel (p.shape.y relaxation) still apply it, so native-vs-reference comparisons now differ silently in contour recovery. | none |  |
| F-3 | minor | not challenged | design |  | `Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source:453` | Soft/hard contact classification is the implicit test record.rho.z == 0 / > 0, a float lane overloaded as compliance sum, repeated in prepare, multiplier update and the damping kernel; no named helper, so a future change to how rho.z is produced silently flips three decisions. | none |  |
| F-5 | minor | not challenged | testability |  | `Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source:1065` | Per-contact damping ratio for a soft-hard pair (average of soft bubble zeta_c and hard bubble's zeta_c lane, new CD-D-6 lane .z kept for hard bubbles) is only covered at ABI level; ContactDynamicsTests pairSeries uses two soft materials, so a wrong partner index or ignoring the hard end's zeta would not fail. | A soft bubble touching a hard bubble could be damped with the wrong ratio (over or under-damped bounce) without any test failing. |  |
| F-6 | minor | not challenged | testability |  | `Tests/BubblePhysicsRuntimeTests/RhoGridReportTests.swift:95` | XCTAssertEqual(points.count, baseCompliances.count * compressionExponents.count) can never fail (loop builds exactly that many points), and the test body is an opt-in report writing into docs/ with a date-stamped filename, so it is skipped in normal runs and verifies nothing about behaviour. | none |  |
| F-7 | minor | not challenged | testability |  | `Tests/BubblePhysicsRuntimeTests/ContactDynamicsTests.swift:141` | New dynamics/probe tests emit print() diagnostics (also in PairLambdaCeilingProbeTests and ContactVelocityCorrectionProbeTests) and the wall/pair series setup is duplicated in near-identical scene builders, while tolerances (10 percent) are tuned to measured values; the prints carry information that should be in assertion messages. | none |  |

## Refuted findings

None.

## Dimensions that produced no findings

- correctness
- security
- performance
- docs-coherence

## Coverage

| Dimension | State | Reason | Model | Findings |
|-----------|-------|--------|-------|----------|
| correctness | reviewed |  | sonnet | 0 |
| contracts | reviewed |  | sonnet | 1 |
| design | reviewed |  | sonnet | 3 |
| security | reviewed |  | sonnet | 0 |
| performance | reviewed |  | sonnet | 0 |
| testability | reviewed |  | sonnet | 4 |
| conventions | reviewed |  | sonnet | 1 |
| docs-coherence | reviewed |  | sonnet | 0 |
| dependencies | not applicable | no dependency manifest or lockfile changed | none | 0 |
| infra | not applicable | no .tf or .tfvars file changed | none | 0 |
| tools-verify | gap | verify command `przegląd diffu dokumentacji` not found (exit 127) | none | 0 |

**correctness** checked:
- nativeUpdateContactRho rewrite: segment and pair branches, early returns, overlap sharing, hard-pair rho=1 case
- nativeUpdateVelocities soft/hard branch and bubbleContactCorrection lifecycle (warm start write, Jacobi accumulate, dispatch order in NativeMetalSolver.swift)
- nativeDampContactNormalMotion per-contact factor: edge.y partner indexing, rho.z>0 gate, zero inverseMassSum, segment vs pair zeta
- MotionControllers band force branch, externalForce extraction, exp damping; TransactionStager validateBandStability and requireBandDriveTarget call sites
- BubbleDrivePolicy and PhysicsMaterial validation (NaN/inf, rigid kind); grep of PhysicsMaterial( reconstruction sites for dropped contactDampingRatio
**contracts** checked:
- nativeUpdateVelocities/nativeApplyWarmStart/nativeSolveJacobi: every dispatch site of bubbleContactCorrection (grep shows only NativeMetalSolver.swift), buffer zeroed by warm start before Jacobi accumulates
- nativeUpdateContactRho reading record.response.y (written by nativeFinalizeSolverContacts and build step) and rho.z consumers in nativeDampContactNormalMotion/nativeUpdateContactMultipliers
- bubble.contact lane .z now nonzero for hard bubbles: grep of .contact consumers and contact.x<=0 gates
- TransactionStager.validate/validateBandStability vs RuntimeObject.mass (derived from descriptor) and MotionControllers band path
- contour.shape.y and deformationRecoveryRate remaining readers (grep): reference module and ReferenceSolverInputAdapter
- PhysicsMaterial construction sites (grep PhysicsMaterial(kind) in Sources): MotionControllers transition now forwards the new field
**design** checked:
- diff of NativeMetalSolver.swift, NativeMetalBufferLayout.swift, NativePublicWorld.swift: new bubbleContactCorrection buffer plumbing, ζ_c packed into contact lane z, removed deformationRecoveryRate (grep for leftovers returned none outside docs)
- NativeXPBDKernels.metal-source: hard/soft discrimination via record.rho.z == 0 at prepare, multiplier update and damping; traced nativePrepareSolverContacts writes rho.z before use
- NativePostSolveKernels.metal-source: rewritten nativeUpdateContactRho and retained nativeIsStructuralResult backstop; adjacency edge layout in nativeEmitAdjacency
- Motion.swift / Resources.swift / MotionControllers.swift / TransactionStager.swift: band drive validation placement, externalForce extraction, material rebuild now copying contact fields
- precedent: existing CD-D-n comments in sources and requirePositive/requireDriveMagnitude helpers in the stager
**security** checked:
- grep of diff.txt for Process/URL/FileManager/getenv/JSONDecoder/NSKeyedUnarchiver/log calls: only test print() of physics numbers and one opt-in report writer
- RhoGridReportTests path built from #filePath plus fixed prefix and ISO date, env flag only gates opt-in; no external input in path
- MotionControllers band drive and externalForce refactor: pure numeric, no secrets or injection; bandStiffness validated like sibling drive fields in TransactionStager
- Metal shader and solver/public world diffs: numeric ABI fields only, no new entry point bypassing checks
- Package.swift and dependency changes: none in diff, no new dependencies
- error messages in validation tests carry only field names (valueOutOfRange drive.bandStiffness), no sensitive data
**performance** checked:
- nativeUpdateContactRho rewrite in NativePostSolveKernels: two binary searches (nativeFindBubble, same helper as NativeXPBDKernels.metal-source:247) per cache record replace atan2 plus previous-contour lookups, net cheaper
- bubbleContactCorrection buffer: one float2 per bubble, written in nativeApplyWarmStart then accumulated in nativeSolveJacobi, no growth and no per-step clearing needed
- nativeDampContactNormalMotion per-contact sqrt/exp and nativeUpdateVelocities extra branch: constant-size ALU work inside the existing adjacency loop
- nativeAccumulateContactPressure: removed previous-frame resampling and buffer bindings, dispatch size count*contourStride unchanged
- MotionControllers band drive: externalForce extraction keeps the same single pass over fields, one exp per player-driven bubble per step
- TransactionStager validateBandStability/requireBandDriveTarget: O(1) checks per staged command
**testability** checked:
- NativeMetalStructuralOperationTests merge/split rho tests vs nativeIsStructuralResult backstop in NativePostSolveKernels (tests state the branch is not executed)
- ContactDynamicsTests and ContactVelocityCorrectionProbeTests vs nativeDampContactNormalMotion zeta_c averaging and nativeUpdateVelocities soft branch (CrowdSceneSupport softBubblePhysics callers grepped)
- BandDriveTests, MotionControllersPrepareTests, TransactionStagerTests, MotionCommandTests band force, clamp, stability, huge-target assertions
- NativeMetalXPBDTests wall/pair rho tests, NativeMetalContourTests circular-contour tests, ContactRhoHistoryTests, PairLambdaCeilingProbeTests control vs limited runs
- RhoGridReportTests opt-in report (XCTSkipUnless, file write, assertions) and print() usage across new tests
**conventions** checked:
- CHANGELOG.md 2.3.0 entry and README version line against integration-guide.md sections
- grep for deformationRecoveryRate/wygładzon/recovery/publishedDeformation leftovers in Sources
- Metal kernel and Swift comments in diff vs the code they sit on (rho, contact correction, pair limit)
- NativeMetalBufferLayout lane comments (contact.z, rho, contour shape) vs usage
- grep of CD-D-/G1-AC/P-B- plan IDs in Sources for precedent in comments
**docs-coherence** checked:
- CHANGELOG 2.3.0 entry against Motion.swift BubbleDrivePolicy validation (field names, drive.* error names, defaults)
- Resources.swift contactDampingRatio validation vs CHANGELOG and integration-guide claims
- grep for deformationRecoveryRate, wygładz, relaksac, poprzedniej klatki across README, docs, Sources: no stale native references remain
- integration-guide new sections (Chwyt gumką, ugięcie, tłumienie, wystrzał) vs shader comments and restSpeed code
- README version bump and benchmark report vs RhoGridReportTests parameters

## What each reviewer was given

Diff: `feature/crowd-review-followups...HEAD` (a0a77d2c..e3876069).

**correctness**:
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalBenchmarkRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/ReferenceSolverInputAdapter.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Motion.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldFrame.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/MotionControllers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/StructuralOperations.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/HitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialTextureRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalStructuralOperationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/BandDriveTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactDynamicsTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactRhoHistoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactVelocityCorrectionProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/MotionControllersPrepareTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/PairLambdaCeilingProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RhoGridReportTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**contracts**:
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalBenchmarkRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/ReferenceSolverInputAdapter.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Motion.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldFrame.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/MotionControllers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/StructuralOperations.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/HitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialTextureRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalStructuralOperationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/BandDriveTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactDynamicsTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactRhoHistoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactVelocityCorrectionProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/MotionControllersPrepareTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/PairLambdaCeilingProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RhoGridReportTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**design**:
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalBenchmarkRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/ReferenceSolverInputAdapter.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Motion.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldFrame.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/MotionControllers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/StructuralOperations.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/HitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialTextureRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalStructuralOperationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/BandDriveTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactDynamicsTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactRhoHistoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactVelocityCorrectionProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/MotionControllersPrepareTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/PairLambdaCeilingProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RhoGridReportTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**security**:
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalBenchmarkRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/ReferenceSolverInputAdapter.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Motion.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldFrame.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/MotionControllers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/StructuralOperations.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/HitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialTextureRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalStructuralOperationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/BandDriveTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactDynamicsTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactRhoHistoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactVelocityCorrectionProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/MotionControllersPrepareTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/PairLambdaCeilingProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RhoGridReportTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**performance**:
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalBenchmarkRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/ReferenceSolverInputAdapter.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Motion.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldFrame.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/MotionControllers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/StructuralOperations.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/HitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialTextureRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalStructuralOperationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/BandDriveTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactDynamicsTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactRhoHistoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactVelocityCorrectionProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/MotionControllersPrepareTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/PairLambdaCeilingProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RhoGridReportTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**testability**:
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalBenchmarkRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/ReferenceSolverInputAdapter.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Motion.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldFrame.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/MotionControllers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/StructuralOperations.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/HitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialTextureRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalStructuralOperationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/BandDriveTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactDynamicsTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactRhoHistoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactVelocityCorrectionProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/MotionControllersPrepareTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/PairLambdaCeilingProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RhoGridReportTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**conventions**:
- `/Users/adamowim/priv/ios/bubble_phisics/CHANGELOG.md`
- `/Users/adamowim/priv/ios/bubble_phisics/README.md`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalBenchmarkRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/ReferenceSolverInputAdapter.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Motion.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldFrame.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/MotionControllers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/StructuralOperations.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/HitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialTextureRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalStructuralOperationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/BandDriveTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactDynamicsTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactRhoHistoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactVelocityCorrectionProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/MotionControllersPrepareTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/PairLambdaCeilingProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RhoGridReportTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/benchmarks/v2.3.0-rho-grid-2026-11-19.md`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/integration-guide.md`

**docs-coherence**:
- `/Users/adamowim/priv/ios/bubble_phisics/CHANGELOG.md`
- `/Users/adamowim/priv/ios/bubble_phisics/README.md`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/benchmarks/v2.3.0-rho-grid-2026-11-19.md`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/integration-guide.md`

Withheld (under `docs/sdlc/changes/2026-11-19-engine-v2-3-0/`):
- `docs/sdlc/changes/2026-11-19-engine-v2-3-0/change-design.md`
- `docs/sdlc/changes/2026-11-19-engine-v2-3-0/plan.md`

Sent to every dimension (matched no routing rule):
- `Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`

## Fixes

No fix wave ran.

## Gaps

- Withheld from every read set: `docs/sdlc/changes/2026-11-19-engine-v2-3-0/change-design.md`, `docs/sdlc/changes/2026-11-19-engine-v2-3-0/plan.md` — they are part of the change, so they remain visible in the diff every reviewer reads.
- verify command `przegląd diffu dokumentacji` not found (exit 127)
- tools-verify is gap: verify command `przegląd diffu dokumentacji` not found (exit 127)
