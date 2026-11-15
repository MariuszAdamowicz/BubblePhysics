# Review: 2026-11-14-crowd-solver-compression — run 1

**Date:** 2026-11-15
**Artifact:** review
**Verdict:** ESCALATE — fix wave made 0 commits
**Rounds:** 2
**Feature artifacts:** change-design.md, plan.md
**Base:** origin/main
**Base SHA:** afe237a8e346b6415766ff6a497ec7b26daacf4a
**Head SHA:** 986d748f874c50540fe142e1d27c00620ce606a9
**Reviewer model:** sonnet
**Challenger model:** opus
**Brief-writer model:** opus
**Template version:** default/0.2.0

**Plugin version:** 0.7.10
**Agent Sessions:** claude-code: 01600dd6-f8a5-4d5f-9bc5-56da83b8ddcc

---

## What changed

<!-- brief:what-changed -->
Version 2.2.0 stops the engine from rejecting simulation steps in dense bubble crowds, which ended 36 of 36 crowd-growth runs of the 2KBubbles game (change-design.md:22). A crowd now resolves by compressing contours under a soft XPBD contact whose compliance comes from the material; the default compliance of 0 keeps the v2.1.0 hard contact (change-design.md:29). A bad placement from the game rejects only its transaction, with a named cause (change-design.md:26). Diagnostics report the guard cause and the contained-pair count (plan.md:24).
<!-- /brief:what-changed -->

## Where human judgement is needed

<!-- brief:human-judgement -->
- F-1 (`NativeXPBDKernels.metal-source:355`): the pair λ limit replaces the per-bubble warm-start bound by design, without division by contact count (change-design.md:260). You decide whether a shift above one radius in a bubble with four or more contacts is acceptable, and whether the old comment should be rewritten.
- F-2 (`PlacementGeometry.swift:20`): CD-D-7 chose the default `positionTolerance` so Runtime does not read the GPU configuration (change-design.md:258). You decide whether that second configuration path is acceptable.
- F-3 (`TransactionStager.swift:553`): the compliance formula exists in two modules. You decide whether a shared helper is worth a new module dependency.
- F-11 (`AcceptanceEquivalenceTests.swift:29`): CD-D-20 proves limit-caused changes with twin tests (change-design.md:262), but the default-path hashes are recorded on one GPU. You decide whether that evidence is enough.
- F-14 (`change-design.md:114`): the `verify:` text is prose, not a command; the full `swift test` passed instead (`Fixes`, round 1). You decide whether to rewrite such lines.
<!-- /brief:human-judgement -->

## What was not verified

<!-- brief:not-verified -->
The design, the plan and two `wip/` files were withheld from every reviewer's read set (`Gaps`). tools-verify is partial in both rounds (`Gaps`, `Coverage`). F-1 to F-3 and F-5 to F-13 reached you without a challenger (`Findings`). The round-2 fix wave made 0 commits (`Fixes`). Dependencies and infra were not applicable (`Coverage`).
<!-- /brief:not-verified -->

---

## Rounds

| Round | Critical | Major | Minor | Action | Fix commits |
|-------|----------|-------|-------|--------|-------------|
| 1 | 0 | 3 | 11 | fix | 1 |
| 2 | 0 | 1 | 12 | stop | 0 |

## Findings

Round 2.

| ID | Severity | Verdict | Dimension | Also flagged by | Site | Summary | Effect | Evidence |
|----|----------|---------|-----------|-----------------|------|---------|--------|----------|
| F-14 | major | tool-proved | tools-verify |  | `docs/sdlc/changes/2026-11-14-crowd-solver-compression/change-design.md:114` | verify command `test publicznego BubbleWorld` exited 2; output in agents/tools-verify/output.txt | not stated |  |
| F-2 | minor | not challenged | design | testability, conventions | `Sources/BubblePhysicsRuntime/PlacementGeometry.swift:20` | Stager reads positionTolerance from a default NativeSolverConfiguration() while baseContactCompliance is passed from the real stepper configuration via CompleteStepper; two ways of sharing solver config with one stager, one of which silently diverges if the world ever builds a non-default tolerance. | none today; if the solver tolerance becomes configurable, placements near another bubble's centre would be accepted or rejected inconsistently with what the solver can actually separate. |  |
| F-1 | minor | not challenged | contracts |  | `Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source:355` | For bubble-bubble contacts the warm-start cap is replaced by nativePairLambdaLimit (approach + 0.25*min r per pair) instead of min-ed with the per-bubble r/(invMass*degree) bound; nativeApplyWarmStart still sums corrections over all `degree` contacts, so the comment's invariant (sum of warm corrections <= radius) no longer holds for a bubble with 4+ contacts. | In a dense crowd a bubble can be shifted by more than its radius by cached multipliers in one step, which can push its centre across a thin wall and make the step get rejected by the solver guard (visible as a stalled simulation step). |  |
| F-3 | minor | not challenged | design |  | `Sources/BubblePhysicsRuntime/TransactionStager.swift:553` | validateWorstAlpha re-implements c0*(r/r_ref)^s in Double in Runtime while NativePublicProperties.contact (NativePublicWorld.swift) computes the same expression in the native module; the two must be kept in sync by comment only, instead of one shared helper. | none now; a future change to the compliance formula in one place would let the stager approve values the GPU path overflows on, stopping the world. |  |
| F-5 | minor | not challenged | performance |  | `Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source:162` | nativeFreeCenter is evaluated for every edge of the containing owner on projection passes 1..4 and each call runs nativeContainingOwner (O(S^2)) plus an O(S) nativeInsideOwner for every segment, so a bubble stuck inside a polygon costs up to E*S^2 per pass, with SIMD divergence on the other threads of its group. | A step in which several bubbles end up inside rigid polygons can stall the GPU noticeably longer than a normal step, causing a visible frame hitch. |  |
| F-6 | minor | not challenged | performance |  | `Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source:21` | nativeContactCompliance does a pow() per contact end each time it is called from nativeContactAlpha in nativeUpdateContactMultipliers and nativeMeasureResidual, which run every solver iteration, although rho and the base are constant within the step; the factor could be computed once per contact (e.g. in nativePrepareSolverContacts). | Extra GPU transcendental work per contact per iteration (about 2 pow x 2 kernels x iteration count) with no change in result, slightly lowering frame rate in dense crowds. |  |
| F-7 | minor | not challenged | performance |  | `Sources/BubblePhysicsRuntime/TransactionStager.swift:427` | validatePlacement calls PlacementGeometry.issue per added/replaced bubble; issue scans all state.objects twice (Dictionary iteration) and rebuilds each rigid body's world-space shape (shape(of:) maps vertices into a new array) on every call, so a transaction adding N bubbles costs O(N*(M+R*V)); the same scan runs up to ~140 times in a merge/split candidate search. | Spawning a large batch of bubbles in one transaction, or many bad-contact merges in a frame, can cause a CPU hitch on the staging step before the physics step runs. |  |
| F-8 | minor | not challenged | testability |  | `Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift:21` | XCTAssertTrue(report.wasContainedCountFinite) cannot fail: the flag is only cleared when the Int containedBubblePairCount (filled from a UInt32 counter) is < 0, and an Int is never non-finite. | none |  |
| F-9 | minor | not challenged | testability |  | `Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift:22` | XCTAssertGreaterThanOrEqual(report.minimumContainedPairs, 0) cannot fail for a non-negative counter, so the crowd runs assert nothing about the contained-pair count they claim to check. | none |  |
| F-10 | minor | not challenged | testability |  | `Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift:66` | With the pair limit on, testWarmStartNeedsNoMoreIterationsThanColdStartAfterFirstFrame only asserts warmed <= cold and warmed <= initial; both exhaust the iteration budget so the test passes even if applyWarmStart were removed, and the convergence check moved to the pairCorrectionLimit=false twin. | A regression in warm start on the default (limit on) configuration would not be caught and would show up as extra solver cost per frame. |  |
| F-11 | minor | not challenged | testability |  | `Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift:29` | pairLimitObjectHash/pairLimitContourHash (and pairLimitPixelHash in AcceptanceRenderEquivalenceTests) are snapshots of the new implementation's output on one GPU, skipped on any other device, so the default pair-limit path has only a record-and-compare golden, not a requirement-derived expectation. | On other GPUs or after an intended change the default scene's behaviour is unverified, and any wrong-but-stable limit bug would be baked in as the new reference. |  |
| F-12 | minor | not challenged | testability |  | `Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift:48` | Twin tests for pairCorrectionLimit=false copy the whole bodies of the chain, warm-start, state-hash and inverse-mass tests, differing only in the flag and expected numbers, so the setup and loops are duplicated four times. | none |  |
| F-13 | minor | not challenged | conventions |  | `Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source:1` | Nagłówek ABI mówi o czterech atomikach uint, a ta zmiana dodaje zapis do `safety + 4` (liczba par bańka w bańce, `diagnostics.x`), więc bufor ma już osiem słów; komentarz zdania o czterech atomikach nie zgadza się z kodem. | none |  |

## Refuted findings

- Round 2, F-4 (major, `Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source:141`): nativeContainingOwner is called unconditionally on pass 0 of every bubble's guard in nativeGuardCenter and is O(S^2) in segment count (for each active segment an inner k<j dedup scan, plus an O(S) nativeInsideOwner per distinct owner), so the guard kernel goes from O(S) to O(S^2) per bubble per step.
  - Evidence: main:Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source:160-166 (merge-base afe237a) already ran, unconditionally per bubble per step in nativeGuardCenter, the same loop over all segments with the k<j owner-dedup scan and nativeInsideOwner per distinct owner (without early return); the branch moved it into nativeContainingOwner (lines 141-151, called at line 215) with an early return, so pass 0 costs at most what main did; passes 1-4 run only when the point is inside a polygon (line 216 break).
  - Repro: `git show main:Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source | sed -n 159,166p` → for (uint j = 0; j < control.counts.y; ++j) { ... for (uint k = 0; k < j; ++k) if (segments[k].flags.y && segments[k].identity.y == s.identity.y) first = false; if (!first || !nativeInsideOwner(end, ...)) continue;

## Dimensions that produced no findings

- correctness
- security
- docs-coherence

## Coverage

| Dimension | State | Reason | Model | Findings |
|-----------|-------|--------|-------|----------|
| correctness | reviewed |  | sonnet | 0 |
| contracts | reviewed |  | sonnet | 1 |
| design | reviewed |  | sonnet | 2 |
| security | reviewed |  | sonnet | 0 |
| performance | reviewed |  | sonnet | 4 |
| testability | reviewed |  | sonnet | 6 |
| conventions | reviewed |  | sonnet | 2 |
| docs-coherence | reviewed |  | sonnet | 0 |
| dependencies | not applicable | no dependency manifest or lockfile changed | none | 0 |
| infra | not applicable | no .tf or .tfvars file changed | none | 0 |
| tools-verify | partial | adjusted 1 of 1 findings: findings\[0\] states no effect; recorded as 'not stated' | none | 1 |

**correctness** checked:
- nativeGuardCenter multi-pass projection (tiers, keys, 5-pass bound, bit 2\|8 validation) and nativeFreeCenter/nativeEdgeCrossed against NativePostSolveKernels.metal-source
- safety bit protocol: grep of every nativeSafetyFailure/safety+3 writer vs host counts.w & 2/8/16 decoding and NativeMetalSafetyControl stride 32 reset/load
- nativeUpdateContactRho: indirect dispatch argument 3 = cache count, contour control counts.y/z, rho copy in MatchContactCache, endpoint a/b and edge.w orientation in accumulate/alpha/residual kernels
- nativePairLambdaLimit and nativeContactAlpha use in PrepareSolverContacts/UpdateContactMultipliers/MeasureResidual; normal orientation from nativeBuildContacts and nativeConstraintGeometry
- TransactionStager placement/worst-alpha validation, merge and split center resolution, relocateSplitParts momentum math; PlacementGeometry; BubbleWorld guard-cause plumbing (lastRejectionReason writers grep)
**contracts** checked:
- NativeMetalSafetyControl stride 32 vs shader safety+4 writes and the test safety buffer of 8 uints (NativeMetalContainmentParallelTests)
- nativeUpdateContactRho dispatch order vs contourControl/published buffers writes in NativeMetalSolver, indirect argument 3 and counts.z guard
- rho end mapping (a/b, edge.w) across nativeAccumulateContactPressure, nativeUpdateContactMultipliers, nativeMeasureResidual and cache match/retain copy
- NativeMetalConfiguration.sanitized preserving pairCorrectionLimit and the single NativeMetalControl construction site for contactDamping.y
- stager validateWorstAlpha vs GPU nativeContactCompliance and alpha (Float/Double, sanitized contactCompliance, dt), all startTransition/replace/add/updatePhysicsMaterial paths
- nativePrepareSolverContacts per-pair lambda cap vs nativeApplyWarmStart summing corrections over degree; lastSolverGuardCause reset sites in BubbleWorld
**design** checked:
- PlacementGeometry.swift (new) vs QueryIndex.swift: shape/contains/polygonContains moved and shared, no duplicate left in QueryIndex
- TransactionStager validateWorstAlpha vs NativePublicProperties.contact: same c0*(r/rref)^s formula in two modules
- StructuralOperations resolvedMergeCenter/resolvedSplitCenter/spiral and TransactionStager merge/resolveSplitCenters: candidate search and cause fallback
- Public SolverGuardCause vs NativeMetalGuardCause mapping in BubbleWorld.outcome (precedent: WorldRejectionReason mapping, left as is)
- CompleteStepper.baseContactCompliance protocol default and NativeCompleteStepper wiring through stageBatch
- Public surface additions (PlacementIssue, BubbleContactCompliance, SolverGuardCause, WorldDiagnostics fields) and package-only pairCorrectionLimit
**security** checked:
- grep of diff added lines for logging, Process, file/URL, decoding, dlopen, secrets: only test tokens (TransactionToken) matched
- traced PlacementGeometry.issue and its callers in TransactionStager (add, replace, merge, split) plus resolveSplitCenters in StructuralOperations; sibling ops in WorldTransaction enum checked, none else sets a bubble position
- validateWorstAlpha callers (add, replace, updatePhysicsMaterial, startTransition, merge, split) and baseContactCompliance plumbing from BubbleWorld/CompleteStep
- Metal shader sources and NativeMetalSolver/BufferLayout diffs for unchecked buffer indexing or new host-GPU inputs
- Package.swift: no dependency changes in the diff; no new imports beyond simd and in-repo modules
**performance** checked:
- NativePostSolveKernels nativeContainingOwner/nativeFreeCenter/nativeGuardCenter loop: traced segment-count complexity per bubble per step against old single-pass projection and nativeInsideOwner precedent
- NativeXPBDKernels nativeContactAlpha/nativeContactCompliance callers in nativeUpdateContactMultipliers and nativeMeasureResidual (dispatched per solver iteration in NativeMetalSolver.swift): pow recomputed from step-constant rho
- nativeUpdateContactRho and nativePreviousContourRatio: one thread per cache record, binary searches via nativeSafetyBubbleIndex/nativeFindBubble, no loops; extra buffer rho 16B/record bounded by cache capacity
- nativeValidateBubbleContainment: added atomic add only on contained pairs; removal of 8 repair passes and containmentRepairActive buffer reduces per-step dispatches
- PlacementGeometry.issue + TransactionStager validatePlacement/resolveSplitCenters/merge candidates: per-add O(objects) scans, shape(of:) allocation per rigid body, state copy-on-write in split
- QueryIndex refactor onto PlacementGeometry (complexity unchanged), BubbleWorld/Diagnostics/Resources/Objects diffs (no hot-path or growth changes)
**testability** checked:
- diff.txt test hunks: ContactComplianceTests, ContainmentResolutionTests, CrowdCompressionTests, CrowdSceneSupport, PlacementValidationTests, SolverGuardCauseTests, BubbleWorldCompletionTests read in full
- NativeMetalXPBDTests, NativeMetalSafetyTests, NativeMetalContainmentParallelTests, ShaderABITests and Acceptance*EquivalenceTests twin/hash tests read; compared against the pairCorrectionLimit, guard and validator source hunks
- PlacementGeometry.coincidentCenterTolerance (grep): only call from Tests is PlacementValidationTests:279 and tests use radius 2 only; NativeSolverConfiguration.positionTolerance default 0.0001 in NativeSolverInput.swift
- grep wasContainedCountFinite/minimumContainedPairs in Tests: only set in CrowdSceneSupport.swift:304-305 and asserted in CrowdCompressionTests.swift:21-22
- NativeMetalXPBDTests warm-start tests with and without pair limit, and duplicated twin test bodies
- StructuralOperations.relocateSplitParts and TransactionStager.validateWorstAlpha branches versus ContactComplianceTests and PlacementValidationTests coverage
**conventions** checked:
- CHANGELOG 2.2.0, README i integration-guide vs diff publicznego API (invalidPlacement, lastSolverGuardCause, containedBubblePairCount, contactCompliance): spójne
- grep po usuniętych kernelach i symbolach naprawy zawierania (SeparateContained, ReapplyCenterGuards, containmentRepair): brak osieroconych odwołań poza celowym komentarzem testu
- komentarze ABI w NativePostSolveKernels.metal-source i NativeMetalBufferLayout.swift vs użycie safety+4 w kernelu
- PlacementGeometry.swift: odwołania do numerów linii w innych plikach vs NativePublicWorld.swift
- NativeMetalShaderABITests: sondy ABI i asercja rozmiaru rekordu bańki 12*16 po dodaniu lane contact i rho; MigrationGuideTests wersja 2.2.0
- nazewnictwo nowych symboli (nativeContactAlpha, nativePairLambdaLimit, PlacementIssue, SolverGuardCause) vs sąsiedzi w shaderach i modelu
**docs-coherence** checked:
- CHANGELOG 2.2.0 pair lambda limit formula vs nativePairLambdaLimit and the pairCorrectionLimit flag default true in NativeMetalBackend/BubbleWorld.makeBenchmarkWorld
- CHANGELOG coincidentCenter tolerance (1e-4 * min radius, floor positionTolerance) vs PlacementGeometry.coincidentCenterTolerance
- README version 2.2.0 and grep of README/docs/MIGRATION-v2 for stale 2.1.0, containment-repair, wrap and rejection-reason statements (none stale)
- integration-guide new section vs Resources.swift (maximumLinearSpeed default nil, contactCompliance docs) and safety bit comments in post-solve and XPBD shaders (bit 2\|8 = 10u)
- shader ABI comments and struct additions (contact float4, rho in cache) vs NativeMetalBufferLayout.swift Swift mirrors
**tools-verify** checked:
- ran `test publicznego BubbleWorld` in the checkout root; exit 2

## What each reviewer was given

Diff: `origin/main...HEAD` (afe237a8..986d748f).

**correctness**:
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBackend.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalChainKernels.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeRenderKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalWorldRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/ReferenceSolverInputAdapter.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Diagnostics.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Objects.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldFrame.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/CompleteStep.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/PlacementGeometry.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/QueryIndex.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/StructuralOperations.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/HitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/LayerRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialColorRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContainmentParallelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSafetyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSolverLifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalChainKernelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/BubbleWorldCompletionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContainmentResolutionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/DecalStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/PlacementValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/QueryIndexTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RenderMaterialStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/SolverGuardCauseTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**contracts**:
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBackend.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalChainKernels.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeRenderKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalWorldRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/ReferenceSolverInputAdapter.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Diagnostics.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Objects.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldFrame.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/CompleteStep.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/PlacementGeometry.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/QueryIndex.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/StructuralOperations.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/HitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/LayerRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialColorRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContainmentParallelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSafetyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSolverLifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalChainKernelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/BubbleWorldCompletionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContainmentResolutionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/DecalStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/PlacementValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/QueryIndexTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RenderMaterialStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/SolverGuardCauseTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**design**:
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBackend.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalChainKernels.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeRenderKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalWorldRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/ReferenceSolverInputAdapter.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Diagnostics.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Objects.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldFrame.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/CompleteStep.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/PlacementGeometry.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/QueryIndex.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/StructuralOperations.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/HitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/LayerRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialColorRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContainmentParallelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSafetyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSolverLifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalChainKernelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/BubbleWorldCompletionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContainmentResolutionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/DecalStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/PlacementValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/QueryIndexTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RenderMaterialStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/SolverGuardCauseTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**security**:
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBackend.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalChainKernels.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeRenderKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalWorldRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/ReferenceSolverInputAdapter.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Diagnostics.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Objects.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldFrame.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/CompleteStep.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/PlacementGeometry.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/QueryIndex.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/StructuralOperations.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/HitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/LayerRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialColorRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContainmentParallelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSafetyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSolverLifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalChainKernelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/BubbleWorldCompletionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContainmentResolutionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/DecalStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/PlacementValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/QueryIndexTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RenderMaterialStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/SolverGuardCauseTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**performance**:
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBackend.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalChainKernels.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeRenderKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalWorldRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/ReferenceSolverInputAdapter.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Diagnostics.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Objects.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldFrame.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/CompleteStep.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/PlacementGeometry.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/QueryIndex.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/StructuralOperations.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/HitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/LayerRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialColorRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContainmentParallelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSafetyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSolverLifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalChainKernelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/BubbleWorldCompletionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContainmentResolutionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/DecalStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/PlacementValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/QueryIndexTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RenderMaterialStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/SolverGuardCauseTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**testability**:
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBackend.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalChainKernels.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeRenderKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalWorldRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/ReferenceSolverInputAdapter.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Diagnostics.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Objects.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldFrame.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/CompleteStep.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/PlacementGeometry.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/QueryIndex.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/StructuralOperations.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/HitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/LayerRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialColorRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContainmentParallelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSafetyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSolverLifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalChainKernelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/BubbleWorldCompletionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContainmentResolutionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/DecalStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/PlacementValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/QueryIndexTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RenderMaterialStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/SolverGuardCauseTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**conventions**:
- `/Users/adamowim/priv/ios/bubble_phisics/CHANGELOG.md`
- `/Users/adamowim/priv/ios/bubble_phisics/README.md`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBackend.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalChainKernels.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeRenderKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalWorldRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/ReferenceSolverInputAdapter.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Diagnostics.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Objects.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldFrame.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/CompleteStep.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/PlacementGeometry.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/QueryIndex.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/StructuralOperations.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/HitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/LayerRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialColorRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContainmentParallelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSafetyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSolverLifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalChainKernelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/BubbleWorldCompletionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContainmentResolutionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/DecalStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/PlacementValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/QueryIndexTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RenderMaterialStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/SolverGuardCauseTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/integration-guide.md`

**docs-coherence**:
- `/Users/adamowim/priv/ios/bubble_phisics/CHANGELOG.md`
- `/Users/adamowim/priv/ios/bubble_phisics/README.md`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeRenderKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/integration-guide.md`

Withheld (under `docs/sdlc/changes/2026-11-14-crowd-solver-compression/`):
- `docs/sdlc/changes/2026-11-14-crowd-solver-compression/change-design.md`
- `docs/sdlc/changes/2026-11-14-crowd-solver-compression/plan.md`
- `docs/sdlc/changes/2026-11-14-crowd-solver-compression/wip/prototype-pair-limit-approach.diff`
- `docs/sdlc/changes/2026-11-14-crowd-solver-compression/wip/xpbd-warmstart-outside-budget.metal-source.txt`

Sent to every dimension (matched no routing rule):
- `Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `Sources/BubblePhysicsNativeMetal/Shaders/NativeRenderKernels.metal-source`
- `Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`

## Fixes

### Round 1

- `986d748f` fix(runtime): walidacja punktu z filtrem kolizji i skończony czynnik ρ_min^k w Float

# Fix report — review-1, round 1

#### Covering tests

1. **GPU `nativeContactCompliance`: ρ_min^k overflows Float even when the stager's Double product is finite** (major). Fixed in the stager. `validateWorstAlpha` (`Sources/BubblePhysicsRuntime/TransactionStager.swift`) now also requires `pow(Float(0.01), min(k, 0))` to be a finite Float, which is the factor the GPU computes on its own before multiplying by c₀. The stager now rejects such a material, so it can no longer pass staging and then turn alpha into inf on the GPU.
   - Test: `Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`, `ContactComplianceTests.testWorstAlphaRejectsCompressionExponentWhoseMinimumRhoFactorOverflowsFloatEvenWithTinyBase`. With c₀ = 1e-20, k = -25 is rejected and k = -19 is accepted. It failed before the fix: k = -25 was accepted.
   - Commit: 986d748f874c50540fe142e1d27c00620ce606a9

2. **`PlacementGeometry.issue` ignores `CollisionFilter`** (major). `issue` now takes the placed bubble's `filter`. It skips any rigid body or bubble whose filter does not collide with it. The region check still applies. The add/replace caller (`validatePlacement`) passes `bubble.filter`, the merge caller passes `result.filter`, and the split caller passes each part's descriptor filter.
   - Tests: `Tests/BubblePhysicsRuntimeTests/PlacementValidationTests.swift`:
     - `PlacementValidationTests.testAddIgnoresBubblesAndBodiesWhoseCollisionFilterExcludesTheNewBubble` covers these cases: on a bubble's centre, inside a rigid body, two ghost bubbles at one point, and replace onto a centre. A point outside the region is still rejected.
     - `PlacementValidationTests.testMergeResultIgnoresBubblesWhoseCollisionFilterExcludesTheResult`: the merge result stays at the contact point on top of a non-colliding bubble.
   - Both failed before the fix: `coincidentCenter`/`insideRigidBody` rejections, and the merge moved to (-2.5, 0).
   - Commit: 986d748f874c50540fe142e1d27c00620ce606a9

3. **Verify command `test publicznego BubbleWorld` exited 2** (major). This is not a code defect. The recorded command is a Polish description ("the public BubbleWorld test"), not a shell command, so `/bin/sh` ran it as `test(1)`. No code change. The concrete command comes from the repository's test guidance (README.md, section "Testy": `swift build --build-tests` / `swift test`). The full suite includes every public `BubbleWorld` test, and it was run as below. Covered by the run itself, no commit.

#### Command

```
cd /Users/adamowim/priv/ios/bubble_phisics && swift test
```

#### Output

```
Building for debugging...
Build complete! (0.34s)
...
Test Suite 'All tests' started at 2026-11-15 23:51:53.360.
Test Suite 'All tests' passed at 2026-11-16 00:00:36.355.
	 Executed 1405 tests, with 1 test skipped and 0 failures (0 unexpected) in 522.867 (522.996) seconds
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
swift test  330,93s user 25,58s system 68% cpu 8:44,06 total
```

### Round 2

Recorded unfixed: the fix wave made 0 commits.

## Gaps

- Withheld from every read set: `docs/sdlc/changes/2026-11-14-crowd-solver-compression/change-design.md`, `docs/sdlc/changes/2026-11-14-crowd-solver-compression/plan.md`, `docs/sdlc/changes/2026-11-14-crowd-solver-compression/wip/prototype-pair-limit-approach.diff`, `docs/sdlc/changes/2026-11-14-crowd-solver-compression/wip/xpbd-warmstart-outside-budget.metal-source.txt` — they are part of the change, so they remain visible in the diff every reviewer reads.
- Round 1: tools-verify is partial: adjusted 1 of 1 findings: findings\[0\] states no effect; recorded as 'not stated'
- Round 2: tools-verify is partial: adjusted 1 of 1 findings: findings\[0\] states no effect; recorded as 'not stated'
