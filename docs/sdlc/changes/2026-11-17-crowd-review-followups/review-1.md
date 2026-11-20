# Review: 2026-11-17-crowd-review-followups — run 1

**Date:** 2026-11-17
**Artifact:** review
**Verdict:** APPROVED — no blocking findings
**Rounds:** 1
**Feature artifacts:** light-design.md
**Base:** origin/main
**Base SHA:** c636893d0be7668eeab3ab92ecdeb901310c1e76
**Head SHA:** b63e31ccceae194f9b8955d28aee533cbb2495b1
**Reviewer model:** sonnet
**Challenger model:** opus
**Brief-writer model:** opus
**Template version:** default/0.2.0

**Plugin version:** 0.7.10
**Agent Sessions:** claude-code: fcd747da-6c74-45fd-807d-41b665ecf122

---

## What changed

<!-- brief:what-changed -->
This branch acts on review-1 of v2.2.0 (light-design.md). It rewrites the prose `verify:` snippets in the v2.2.0 change-design.md as shell commands, so the review script can run them (LD-D-3). It replaces crowd and warm-start assertions that could not fail, puts the compliance formula in one place, passes the solver position tolerance to the stager, and removes repeated GPU and CPU work. Solver results and golden hashes are meant to stay as in 2.2.0 (light-design.md).
<!-- /brief:what-changed -->

## Where human judgement is needed

<!-- brief:human-judgement -->
- `NativeXPBDKernels.metal-source` warm start: with 4+ contacts the summed correction is not bounded by the radius, and the physics was left unchanged on purpose (light-design.md LD-D-1, deviation 4). You decide if this risk stays accepted.
- `Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift:23`: the B = 2.5 scene never reaches 0 contained pairs (light-design.md deviation 2), and change-design.md G2-AC5 still describes the removed per-frame check (F-8). You decide how to restate the v2.2.0 promise.
- `Sources/BubblePhysicsRuntime/CompleteStep.swift:226`: tolerance reaches the stager as one more protocol requirement with several default sites (F-2, F-3, LD-D-4); one config value is the alternative.
- `docs/sdlc/changes/2026-11-14-crowd-solver-compression/change-design.md`: an approved document was rewritten, and its model-tests line names a command that does not run them (light-design.md deviation 1).
- `Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift:116`: a fixed count of 305 and a not-equal hash stand in for proof that the pair limit works (F-7).
<!-- /brief:human-judgement -->

## What was not verified

<!-- brief:not-verified -->
All ten findings, F-1 to F-10, reached you unchallenged (Findings). light-design.md was withheld from every read set (Gaps). The review ran only `swift test --filter BubblePhysicsNativeMetalDiagnosticsTests.NativeMetalXPBDTests`; it did not run the full `swift test` or `BubblePhysicsPerfGuard` (Coverage). Dependencies and infra were not applicable (Coverage).
<!-- /brief:not-verified -->

---

## Rounds

| Round | Critical | Major | Minor | Action | Fix commits |
|-------|----------|-------|-------|--------|-------------|
| 1 | 0 | 0 | 10 | stop | 0 |

## Findings

Round 1.

| ID | Severity | Verdict | Dimension | Also flagged by | Site | Summary | Effect | Evidence |
|----|----------|---------|-----------|-----------------|------|---------|--------|----------|
| F-1 | minor | not challenged | design |  | `Sources/BubblePhysicsRuntime/PlacementGeometry.swift:295` | Two `issue` overloads (with and without precomputed rigidBodies) duplicate the region/rigid-body/bubble sequence; only the body loop differs, and the first overload's `positionTolerance` default adds a second default site beside stage/stageBatch. | none |  |
| F-2 | minor | not challenged | design |  | `Sources/BubblePhysicsRuntime/PlacementGeometry.swift:268` | defaultPositionTolerance is a package-wide default that reads NativePublicWorld's static, so the stager's defaults (stage, stageBatch, issue, CompleteStepper extension) all silently depend on the Metal world; four default sites can drift from a stepper's real value if one caller omits the argument. | none |  |
| F-3 | minor | not challenged | design |  | `Sources/BubblePhysicsRuntime/CompleteStep.swift:226` | CompleteStepper protocol grows another requirement (positionTolerance) for one stager threshold, same pattern as baseContactCompliance; solver-config knobs reach the stager through a widening protocol surface instead of a single config value. | none |  |
| F-4 | minor | not challenged | testability |  | `Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift:799` | testPreparedContactCarriesTheSumOfEndComplianceInRhoZ covers only a bubble-bubble contact; the kind != 0 branch (rho.z = c_a only, segment/wall) and the inactive-contact (endpoints.w == 0) skip in nativePrepareSolverContacts have no test that would fail if broken. | A regression adding c_b to wall/segment contacts or leaving stale rho.z would change contact stiffness against walls and static bodies without any test failing. |  |
| F-5 | minor | not challenged | testability |  | `Tests/BubblePhysicsRuntimeTests/PlacementValidationTests.swift:134` | testNativeStepperExposesTheSolverPositionTolerance compares the stepper to the same constant it returns and never checks that NativePublicWorld actually passes positionTolerance into NativeSolverConfiguration (NativePublicWorld.swift:235); the wiring that makes stager and solver agree is untested. | If the world stopped passing the tolerance to the solver, stager and solver thresholds could diverge silently and placements the stager accepts could be unstable on the GPU. |  |
| F-6 | minor | not challenged | testability |  | `Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source:147` | nativeContainingOwner was rewritten to a testedOwner memory, but the diff adds no test with interleaved or non-contiguous owner edges or a filtered-out owner among consecutive edges, so behaviour that differs from the old first-edge scan would go unnoticed. | A wrong containing-owner result could push a bubble centre out of the wrong polygon or fail to project it, with no failing test. |  |
| F-7 | minor | not challenged | testability |  | `Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift:116` | Hard-coded object count 305 and a NotEqual hash between limited and unlimited twins: the count is a magic number unrelated to the requirement and the hash inequality passes for any difference, not for the limit working as intended. | none |  |
| F-8 | minor | not challenged | conventions |  | `Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift:23` | The diff deletes the per-frame finite and non-negative assertions on containedBubblePairCount from assertCrowdKeptStepsAccepted, but change-design.md G2-AC5 (rewritten in this diff) still says the count is finite and non-negative in every frame and verified by 'asercja w teście G1-AC1'. | none |  |
| F-9 | minor | not challenged | docs-coherence |  | `docs/sdlc/changes/2026-11-14-crowd-solver-compression/change-design.md:164` | Doc says NativeContactCache.rho is (rho_a, rho_b, reserve, reserve), but the change now stores the summed compliance c_a+c_b in rho.z (NativeMetalBufferLayout.swift rho doc, NativeGeometryKernels comment, nativePrepareSolverContacts); only w is reserved. | none |  |
| F-10 | minor | not challenged | docs-coherence |  | `docs/sdlc/changes/2026-11-14-crowd-solver-compression/change-design.md:232` | Citation NativeMetalBufferLayout.swift:89-94 for NativeContactCacheRecord no longer covers the struct: the diff expanded the rho field into a 3-line doc comment, shifting the field and following lines past 94. | none |  |

## Refuted findings

None.

## Dimensions that produced no findings

- correctness
- contracts
- security
- performance
- tools-verify

## Coverage

| Dimension | State | Reason | Model | Findings |
|-----------|-------|--------|-------|----------|
| correctness | reviewed |  | sonnet | 0 |
| contracts | reviewed |  | sonnet | 0 |
| design | reviewed |  | sonnet | 3 |
| security | reviewed |  | sonnet | 0 |
| performance | reviewed |  | sonnet | 0 |
| testability | reviewed |  | sonnet | 4 |
| conventions | reviewed |  | sonnet | 1 |
| docs-coherence | reviewed |  | sonnet | 2 |
| dependencies | not applicable | no dependency manifest or lockfile changed | none | 0 |
| infra | not applicable | no .tf or .tfvars file changed | none | 0 |
| tools-verify | reviewed |  | none | 0 |

**correctness** checked:
- nativePrepareSolverContacts rho.z write: gating on endpoints.w and limited versus nativeEmitAdjacency, nativeUpdateContactRho order in NativeMetalSolver.swift dispatch
- nativeContactAlpha consumers (UpdateContactMultipliers, MeasureResidual) read only adjacency/active contacts, so stale rho.z on inactive records is unused
- nativeContainingOwner testedOwner memory versus original first-edge scan: result equivalent even for non-contiguous owners
- scaledBase refactor in Resources.swift versus validateWorstAlpha in TransactionStager and NativePublicProperties.contact: same Double formula, base<=0 guarded by caller
- positionTolerance plumbing (stepper protocol, BubbleWorld stageBatch, PlacementGeometry issue overloads, rigidBodies caching in merge/split)
**contracts** checked:
- rho.z producer nativePrepareSolverContacts vs consumers nativeUpdateContactMultipliers and nativeMeasureResidual (both read only active contacts via endpoints.w / adjacency; prepare dispatched at NativeMetalSolver.swift:697 after nativeUpdateContactRho:688 and before the solver loop)
- end ordering a/b and rho.x/rho.y pairing in nativeEmitAdjacency vs old nativeContactAlpha call sites; cache carry-over of rho in merge (line 204) and safety isfinite(c.rho) check
- positionTolerance plumbing: CompleteStepper default, NativeCompleteStepper, BubbleWorld stageBatch call, StagingContext, all three PlacementGeometry.issue callers; NativePublicWorld NativeSolverConfiguration use at line 235 (grep for other configuration builders found none)
- BubbleContactCompliance.scaledBase vs validateWorstAlpha and NativePublicProperties.contact (base>0 guard preserved, Double formula identical)
- PlacementGeometry.rigidBodies snapshot reuse in merge and split (bodies unchanged in snapshot, excluded filter by id preserved)
**design** checked:
- diff lines 1-620: PlacementGeometry, TransactionStager, CompleteStepper, NativePublicWorld, Resources.scaledBase, Metal kernels
- grep PlacementGeometry.issue/rigidBodies/defaultPositionTolerance and NativePublicWorld.positionTolerance in Sources/BubblePhysicsRuntime
- Package.swift target dependencies: Runtime depends on NativeMetal and Model; scaledBase lives in Model
- positionTolerance threading through stage/stageBatch/StagingContext/BubbleWorld.stageBatch
- rho.z contract duplicated across Swift layout, MSL struct and kernel comments
**security** checked:
- diff.txt all Swift/Metal source hunks: no logging, secrets, error strings or credentials introduced
- trust boundaries: no shell, SQL, path, template or URL use in changed lines (grep for Process/exec/path/URL/print/log)
- no deserialization or eval; Resources.swift change only adds import Foundation
- new positionTolerance parameter on stageBatch fed via CompleteStepper protocol default and NativeCompleteStepper override: both siblings supply it
- no Package.swift or dependency changes in the diff; shader rho.z read/write stays within existing cache index bounds check
**performance** checked:
- nativePrepareSolverContacts: compliance computed once per active contact, single conditional cache write; nativeContactAlpha now reads rho.z with no pow in the iteration loop
- nativeContainingOwner: owner memory replaces the quadratic earlier-edge scan; still O(n) per thread, same as before for the inner nativeInsideOwner
- PlacementGeometry.rigidBodies hoisted out of issue() in merge and split resolution; built once per operation, same total shape work as the old loop on a miss
- positionTolerance plumbing through stager, stepper and BubbleWorld.stageBatch: static let, no per-call recomputation or growth
- BubbleContactCompliance.scaledBase and the validateWorstAlpha call site: one pow per bubble as before
**testability** checked:
- diff of NativeMetalXPBDTests.swift: rho.z test and four-contact warm-start test, extracted twin helpers
- PlacementValidationTests.swift additions: stepper tolerance, prebuilt rigid bodies equivalence, NativeCompleteStepper tolerance test
- grep for rho.z and containingOwner in Tests: only the new rho.z test; containingOwner covered by older SafetyTests/SolverGuardCauseTests
- CrowdCompressionTests and CrowdSceneSupport diff: peak/last contained pair assertions
- AcceptanceEquivalenceTests twin-run assertion and NativeMetalShaderABITests safety layout test
**conventions** checked:
- diff of Swift sources and Metal comments vs NativeMetalSafetyControl layout and NativeContactCacheRecord.rho docs (comments match code)
- grep for stale references (NativePublicWorld.swift:217, minimumContainedPairs, wasContainedCountFinite, nativeContactAlpha callers): none left in Sources/Tests
- test helper naming/MARK pattern in NativeMetalXPBDTests vs NativeMetalSafetyTests (assert* private helpers) - follows precedent
- change-design.md G2-AC5 and G1-AC verify lines against the assertions removed from CrowdCompressionTests
- PlacementGeometry/TransactionStager/CompleteStepper positionTolerance parameter naming vs baseContactCompliance precedent
**docs-coherence** checked:
- change-design.md claims about NativeContactCache.rho (line 164) against the new rho.z use in NativeMetalBufferLayout.swift and the .metal-source structs
- change-design.md line-number citations (NativeMetalBufferLayout.swift:89-94, NativePublicWorld.swift:158-171) against current files
- diff of change-design.md (only checkbox flips) and CD-D-7 text vs stepper-supplied positionTolerance
- new comments in NativePostSolveKernels ABI header vs NativeMetalSafetyControl in NativeMetalBufferLayout.swift
**tools-verify** checked:
- ran `swift test --filter BubblePhysicsNativeMetalDiagnosticsTests.NativeMetalXPBDTests` in the checkout root; exit 0

## What each reviewer was given

Diff: `origin/main...HEAD` (c636893d..b63e31cc).

**correctness**:
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/CompleteStep.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/PlacementGeometry.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/PlacementValidationTests.swift`

**contracts**:
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/CompleteStep.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/PlacementGeometry.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/PlacementValidationTests.swift`

**design**:
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/CompleteStep.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/PlacementGeometry.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/PlacementValidationTests.swift`

**security**:
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/CompleteStep.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/PlacementGeometry.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/PlacementValidationTests.swift`

**performance**:
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/CompleteStep.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/PlacementGeometry.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/PlacementValidationTests.swift`

**testability**:
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/CompleteStep.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/PlacementGeometry.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/PlacementValidationTests.swift`

**conventions**:
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/CompleteStep.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/PlacementGeometry.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/PlacementValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/sdlc/changes/2026-11-14-crowd-solver-compression/change-design.md`

**docs-coherence**:
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/sdlc/changes/2026-11-14-crowd-solver-compression/change-design.md`

Withheld (under `docs/sdlc/changes/2026-11-17-crowd-review-followups/`):
- `docs/sdlc/changes/2026-11-17-crowd-review-followups/light-design.md`

Sent to every dimension (matched no routing rule):
- `Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`

## Fixes

No fix wave ran.

## Gaps

- Withheld from every read set: `docs/sdlc/changes/2026-11-17-crowd-review-followups/light-design.md` — they are part of the change, so they remain visible in the diff every reviewer reads.
