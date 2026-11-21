# Review: 2026-11-20-engine-3-0-0 — run 1

**Date:** 2026-11-21
**Artifact:** review
**Verdict:** ESCALATE — fix worker blocked: the only finding is not a code defect: the recorded verify command `test integracyjny, dwa światy` is prose, not a command (/bin/sh ran it as the `test` builtin and exited 2). The review scope needs …
**Rounds:** 1
**Feature artifacts:** change-design.md, plan.md
**Base:** origin/main
**Base SHA:** e669fb1c2c1ed34abbce55f0e12b6cccf654f1ef
**Head SHA:** 4c62b13b76de5ae1e3f52e19a8ce93e55aac33e6
**Reviewer model:** sonnet
**Challenger model:** opus
**Brief-writer model:** opus
**Template version:** default/0.2.0

**Plugin version:** 0.7.11
**Agent Sessions:** claude-code: 756dc9d6-0b66-4388-9b5e-b43e18736f88

---

## What changed

<!-- brief:what-changed -->
Version 3.0.0 fixes two 2.3.0 defects that kept a bubble at rest from deflecting by c · F (change-design.md:25). Band damping is removed, and material damping now reduces velocity before F/m · dt is added (change-design.md:27). Static polygon edges push only from the outside, and a convex vertex counts once (change-design.md:27). Compliance becomes c₀ · r / r_ref, the player drive is band-only, and the contour is only drawn (change-design.md:27, change-design.md:94). Removed parameters make this a major version (change-design.md:29).
<!-- /brief:what-changed -->

## Where human judgement is needed

<!-- brief:human-judgement -->
- F-4 (`NativeGeometryKernels.metal-source:180`): linear damping moved to the host, while angular damping stays on the GPU. The design keeps rotation damping out of scope (change-design.md:107, plan.md:588), so you decide if two code paths for one coefficient are acceptable.
- F-6 (`AcceptanceEquivalenceTests.swift:27`): golden hashes were regenerated from the new output, and plan.md:638 calls the stated reason probable but not proven.
- F-7 (`NativeMetalMotionRoleTests.swift:39`): the penetration tolerance went from 1.001 to 1.01 (plan.md:629); you decide if the new bound still expresses the requirement.
- F-3 (`NativeSolverInput.swift:60`): `convexEnd` is packed into the GPU ABI, but no kernel reads it, a deviation the plan accepted (plan.md:637).
- F-11 (`change-design.md:78`): the recorded verify step is prose, not a command; you choose which test stands for it.
<!-- /brief:human-judgement -->

## What was not verified

<!-- brief:not-verified -->
The verify step never ran a real test: tools-verify is partial and F-11 records only a shell exit 2 (`Gaps`, `Coverage`). The reviewers did not read change-design.md and plan.md except through the diff (`Gaps`). F-1 to F-10 reached you without a challenger (`Findings`). Dependencies and infra were not applicable (`Coverage`).
<!-- /brief:not-verified -->

---

## Rounds

| Round | Critical | Major | Minor | Action | Fix commits |
|-------|----------|-------|-------|--------|-------------|
| 1 | 0 | 1 | 10 | stop | 0 |

## Findings

Round 1.

| ID | Severity | Verdict | Dimension | Also flagged by | Site | Summary | Effect | Evidence |
|----|----------|---------|-----------|-----------------|------|---------|--------|----------|
| F-11 | major | tool-proved | tools-verify |  | `docs/sdlc/changes/2026-11-20-engine-3-0-0/change-design.md:78` | verify command `test integracyjny, dwa światy` exited 2; output in agents/tools-verify/output.txt | not stated |  |
| F-1 | minor | not challenged | correctness | contracts | `Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source:703` | nativeBuildContacts still seeds the record's last float4 with (1, 1, 0, 0), the old rho default; the slot is now `compliance` (x = sum of end compliances, y/z/w reserved, Swift default .zero), so a fresh record starts with compliance.x = 1 and y = 1 until nativePrepareSolverContacts overwrites x for active contacts. | none today because only active records are read by the solver, but an inactive or test-inspected record shows a bogus unit compliance, and any later reader of the slot before PrepareSolverContacts would treat it as a soft contact. |  |
| F-2 | minor | not challenged | contracts | docs-coherence | `Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift:103` | NativeContactCacheRecord.response is still documented as 'lambda, penetration, allowedSide, reserved' but lane w now carries the polygon-edge feature (0/1/2) that nativeConstraintGeometry and nativeFinalizeSolverContacts read for the whole step; the Swift side gives no hint the lane is live. | none |  |
| F-10 | minor | not challenged | conventions | docs-coherence | `Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift:60` | The flags.w bit layout and the flags.z note are documented in a /// comment on NativeMetalSegment.init instead of on the flags field, where neighbouring fields keep their layout notes as trailing comments; the new region field above it follows the field convention. | none |  |
| F-3 | minor | not challenged | design |  | `Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift:60` | NativeSolverPolygonEdge.convexEnd is computed in NativeStaticPolygonEdges, stored, encoded as flags.w bit 2 in NativeMetalSegment and documented in the MSL struct, yet its own doc comment says no kernel reads it; a write-only field widens the host-GPU ABI for diagnostics only. | none |  |
| F-4 | minor | not challenged | design |  | `Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source:180` | Damping of one material coefficient is now split across layers: linear gamma is applied on the host in MotionControllers.dampedVelocity, while angular gamma for the same public bubble is still applied on GPU from material.x in nativePredict, with a different guard (publicFlags.x) for each; the two paths must be kept in sync by hand. | none |  |
| F-5 | minor | not challenged | testability |  | `Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift:30` | New test files copy the same scene helpers (world builder with receipt check, advance with lastAdvanceIssue check, settle/tail-spread loop) instead of extending CrowdSceneSupport.swift: compare MotionDampingTests.swift:32/64/231 and ContactComplianceTests modelWorld, so a change to scene setup must be repeated in several files. | none |  |
| F-6 | minor | not challenged | testability |  | `Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift:27` | Golden object, contour and pixel hashes (and the pair-limit variants) were regenerated from the implementation output on one device and pinned; they encode current behavior rather than a requirement, so any unintended change from the slices is silently absorbed by the re-pin and the check only runs on Apple M1 Pro. | none |  |
| F-7 | minor | not challenged | testability |  | `Tests/BubblePhysicsNativeMetalTests/NativeMetalMotionRoleTests.swift:39` | The no-teleport bound on a grabbed bubble pressed into a wall was loosened from 1.001 to 1.01 to fit the new band force; the test now tolerates penetration ten times larger and no assertion ties the allowed depth to c*F or the contact model. | none |  |
| F-8 | minor | not challenged | testability |  | `Tests/BubblePhysicsNativeMetalTests/NativeStaticPolygonContactTests.swift:107` | The vertex-region test only asserts at least one bubbleSegment contact and no two near-identical normals; it never checks that the normal points away from the polygon or that depth matches the distance, so a wrong-direction or wrong-depth contact in a region would still pass. | none |  |
| F-9 | minor | not challenged | conventions |  | `Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift:56` | Doc comment on convexStart says 'Wierzchołek początkowy (końcowy)' and claims the edge interior excludes the projection onto its convex end, which is a convexEnd concern; the next field says kernels do not read convexEnd and nativePolygonEdgeFeature uses only convexStart plus nativePastSegmentEnd, so the comment no longer matches the code. | none |  |

## Refuted findings

None.

## Dimensions that produced no findings

- security
- performance

## Coverage

| Dimension | State | Reason | Model | Findings |
|-----------|-------|--------|-------|----------|
| correctness | reviewed |  | sonnet | 1 |
| contracts | reviewed |  | sonnet | 2 |
| design | reviewed |  | sonnet | 2 |
| security | reviewed |  | sonnet | 0 |
| performance | reviewed |  | sonnet | 0 |
| testability | reviewed |  | sonnet | 4 |
| conventions | reviewed |  | sonnet | 2 |
| docs-coherence | reviewed |  | sonnet | 2 |
| dependencies | not applicable | no dependency manifest or lockfile changed | none | 0 |
| infra | not applicable | no .tf or .tfvars file changed | none | 0 |
| tools-verify | partial | adjusted 1 of 1 findings: findings\[0\] states no effect; recorded as 'not stated' | none | 1 |

**correctness** checked:
- NativeStaticPolygonEdges.segments and mergingCollinearEdges: empty/degenerate input, orientation sign, convexity, ID count vs points.count in NativePublicWorld
- nativeBuildContacts/nativePolygonEdgeFeature/nativeConstraintGeometry feature path, record drop via -FLT_MAX penetration, stale-record deactivation in nativeEmitAdjacency, consumers of compliance.x (PrepareSolverContacts, DampContactNormalMotion, adjacency-only loops)
- NativeMetalSolver readback relaxation (optional bounds, effective radius fallback), nativeSeedStructuralContours buffer index renumbering vs Swift dispatch list, deformation.xy readers in kernels
- MotionControllers.prepare host damping order, call site in NativeCompleteStepper, TransactionStager requireDrivePolicy/validateWorstAlpha/validateBandStability
- NativeMetalSegment/NativeContactCacheRecord Swift layout vs Metal struct field order
**contracts** checked:
- NativeContactCache.compliance producers/consumers: nativeBuildContacts initializer, nativeMatchContactCache, nativePrepareSolverContacts, nativeEmitAdjacency, nativeApplyWarmStart, nativeDampContactNormalMotion (active-only via adjacency)
- polygon-edge feature (response.w) through compaction (nativePrepareContactFlags/nativeCompactActiveContacts), retain kernel, solver readback filter lastSeenFrame, and nativeFinalizeSolverContacts
- MotionControllers.prepare host damping vs GPU nativePredict/nativeRigidPredict (fixed dt via BubbleWorld clock, material lookup, role coverage) and optional drivePolicy consumers (stager requireDrivePolicy, replace, Showcase BubbleScene)
- NativeStaticPolygonEdges input contract against PolygonGeometry validation (simple polygon, collinear allowed) and NativePublicWorld segment-ID/caching use
- removed contour/safety checks: bubbleBoundsRecords optional through NativePublicObject.adopt and NativeCompleteStepper.publishedObjectStates fallback; nativeCheckFinite deformation.xy consumers; seed-kernel buffer index shift vs dispatch
- grep for NativeSegment/NativeMetalSegment stride users, rigidity/material.z, nativeUpdateContactRho, .standard drive policy leftovers
**design** checked:
- NativeStaticPolygonEdges.swift and its only caller in NativePublicWorld.swift; grep for .fixed(id: shows no second polygon-to-segment builder to duplicate
- MotionControllers.prepare/dampedVelocity versus NativeGeometryKernels nativePredict (line 180): linear damping moved to host, angular damping still on GPU from material.x
- grep for nativeUpdateContactRho, compressionExponent, radiusExponent, bandDamping, rigidifies, capturedRadius in Sources: no stale references in code
- test seams debugBubbleRadii, persistentState, NativeCompleteStepper.init(world:) against existing precedent cachedContacts and debugContourSnapshot (same package-level seam pattern)
- TransactionStager requireDrivePolicy/requireBandDriveTarget and validateWorstAlpha single-source formula via scaledBase
- BubbleDrivePolicy, BubbleDescriptor, BubbleResult public surface after removal of fields and .standard
**security** checked:
- grep of diff.txt for shell/process, dlopen, deserialization, eval, FileManager, logging calls: only test-path helpers removed, no secrets or logging added; 'token' hits are TransactionToken ids
- TransactionStager.swift diff: new requireDrivePolicy guard on beginPlayerDrive and requireBandDriveTarget keep the same finite/magnitude checks as updatePlayerDrive and siblings
- MotionControllers.swift diff: damping read from PhysicsMaterial validated nonnegative in Resources.swift (requireNonnegative); bandStiffness validated finite and positive in Motion.swift
- NativeMetalSolver.swift nativeSeedStructuralContours dispatch (line ~799) buffer list vs. shader signature: 11 buffers match indices 0-10 after safety buffer removal
- NativeStaticPolygonEdges.swift new file: pure geometry, index arithmetic modulo ring count, count>=3 guard; no external input parsing
- Package manifests: no Package.swift or Package.resolved change in diff, so no new dependency
**performance** checked:
- NativeStaticPolygonEdges.swift mergingCollinearEdges: O(n^2) worst case, but only run on polygon cache miss in NativePublicWorld.swift (cached by geometry/position/rotation)
- MotionControllers.prepare: per-object exp() and lazy damping closure with a single dictionary lookup only for damped roles; dictionary copy is copy-on-write
- NativeMetalSolver.swift diff: nativeUpdateContactRho dispatch and per-contour edge-length checks removed, so less per-step GPU/CPU work; bubbleBounds reserved capacity kept
- Metal kernels diff (Geometry, PostSolve, XPBD): polygon edge feature selection is constant-time per contact with no new loops; read-back loop in solver unchanged in complexity
- TransactionStager.swift: validateWorstAlpha now computes one max instead of pow; no new collections or per-frame growth
**testability** checked:
- MotionDampingTests and MotionControllersPrepareTests assertions against closed-form v*exp(-g*dt)+F/m*dt; gamma 4 vs 0.6 and a distinct rigid gamma make a wrong-material or double-damping bug fail
- StaticPolygonEdgeTests (thin vs thick wall, winding reversal, convex vertex, fast bubble) and NativeStaticPolygonEdgesTests; each fails if a back edge or double vertex contact returns
- NativeStaticPolygonContactTests contact-count and duplicate-normal assertions, helper reuse via CrowdSceneSupport.swift precedent
- ContactComplianceTests/TransactionStagerTests worst-alpha, drive-policy rejection and grab-ending paths; NativeMetalSafetyTests contour-only acceptance with valid-value counterparts
- AcceptanceEquivalence/AcceptanceRenderEquivalence golden hash re-pins and NativeMetalMotionRoleTests tolerance change
**conventions** checked:
- grep of Sources, Tests, docs/*.md, README, Examples for removed symbols (nativeUpdateContactRho, radiusExponent, compressionExponent, bandDamping, rigidifies, .standard, rigidity, capturedRadius): only historical CHANGELOG/MIGRATION text remains
- CHANGELOG.md, README.md, docs/MIGRATION-v3.md, docs/integration-guide.md against the code diff, and guide-region markers against BubbleScene.swift and MetalHostView.swift (same marker format as the existing regions)
- Metal kernel comments and renamed rho to compliance lane across NativeGeometryKernels, NativeXPBDKernels, NativePostSolveKernels and NativeMetalBufferLayout.swift
- NativeSolverInput.swift NativeSolverPolygonEdge doc comments against NativeGeometryKernels nativePolygonEdgeFeature (which fields the kernel reads)
- MigrationGuideTests.swift version assertions and test naming (testXxx pattern) against neighbours; debugBubbleRadii naming against debugContourSnapshot in BubbleWorld.swift
**docs-coherence** checked:
- CHANGELOG.md 3.0.0 entry, README.md version line, docs/MIGRATION-v3.md and docs/integration-guide.md read against MotionControllers.swift damping and drive code
- grep for radiusExponent, compressionExponent, bandDamping, rigidif, nativeUpdateContactRho, maximumSpeed outside history docs: no stale user-facing hits
- NativeMetalBufferLayout.swift comments against NativeGeometryKernels and NativeXPBDKernels metal-source (flags.w, response.w readers)
- NativeStaticPolygonEdges.swift doc comment against its code and the changelog claims on 1e-5 collinear tolerance and stride 112 to 128 (ABI test probes region)
- integration-guide grip-policy region and damping 1.5 material example against the diff of BubbleScene.swift
**tools-verify** checked:
- ran `test integracyjny, dwa światy` in the checkout root; exit 2

## What each reviewer was given

Diff: `origin/main...HEAD` (e669fb1c..4c62b13b).

**correctness**:
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Examples/BubblePhysicsShowcase/App/BubbleScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeStaticPolygonEdges.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/Motion.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/Objects.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsRuntime/MotionControllers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSafetyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSolverLifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalBoundsPublicationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalChainKernelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalMotionRoleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalPublicObjectTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalStructuralOperationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeSolverInputTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeStaticPolygonContactTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeStaticPolygonEdgesTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/BandDriveTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactDynamicsTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactRhoHistoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactVelocityCorrectionProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContainmentResolutionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContourIsDrawOnlyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/JointStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/MotionControllersPrepareTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/MotionDampingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/PairLambdaCeilingProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/RhoGridReportTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**contracts**:
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Examples/BubblePhysicsShowcase/App/BubbleScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeStaticPolygonEdges.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/Motion.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/Objects.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsRuntime/MotionControllers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSafetyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSolverLifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalBoundsPublicationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalChainKernelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalMotionRoleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalPublicObjectTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalStructuralOperationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeSolverInputTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeStaticPolygonContactTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeStaticPolygonEdgesTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/BandDriveTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactDynamicsTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactRhoHistoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactVelocityCorrectionProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContainmentResolutionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContourIsDrawOnlyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/JointStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/MotionControllersPrepareTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/MotionDampingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/PairLambdaCeilingProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/RhoGridReportTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**design**:
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Examples/BubblePhysicsShowcase/App/BubbleScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeStaticPolygonEdges.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/Motion.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/Objects.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsRuntime/MotionControllers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSafetyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSolverLifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalBoundsPublicationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalChainKernelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalMotionRoleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalPublicObjectTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalStructuralOperationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeSolverInputTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeStaticPolygonContactTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeStaticPolygonEdgesTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/BandDriveTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactDynamicsTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactRhoHistoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactVelocityCorrectionProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContainmentResolutionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContourIsDrawOnlyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/JointStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/MotionControllersPrepareTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/MotionDampingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/PairLambdaCeilingProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/RhoGridReportTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**security**:
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Examples/BubblePhysicsShowcase/App/BubbleScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeStaticPolygonEdges.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/Motion.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/Objects.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsRuntime/MotionControllers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSafetyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSolverLifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalBoundsPublicationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalChainKernelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalMotionRoleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalPublicObjectTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalStructuralOperationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeSolverInputTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeStaticPolygonContactTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeStaticPolygonEdgesTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/BandDriveTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactDynamicsTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactRhoHistoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactVelocityCorrectionProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContainmentResolutionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContourIsDrawOnlyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/JointStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/MotionControllersPrepareTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/MotionDampingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/PairLambdaCeilingProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/RhoGridReportTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**performance**:
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Examples/BubblePhysicsShowcase/App/BubbleScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeStaticPolygonEdges.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/Motion.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/Objects.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsRuntime/MotionControllers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSafetyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSolverLifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalBoundsPublicationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalChainKernelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalMotionRoleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalPublicObjectTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalStructuralOperationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeSolverInputTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeStaticPolygonContactTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeStaticPolygonEdgesTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/BandDriveTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactDynamicsTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactRhoHistoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactVelocityCorrectionProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContainmentResolutionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContourIsDrawOnlyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/JointStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/MotionControllersPrepareTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/MotionDampingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/PairLambdaCeilingProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/RhoGridReportTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**testability**:
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Examples/BubblePhysicsShowcase/App/BubbleScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeStaticPolygonEdges.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/Motion.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/Objects.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsRuntime/MotionControllers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSafetyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSolverLifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalBoundsPublicationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalChainKernelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalMotionRoleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalPublicObjectTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalStructuralOperationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeSolverInputTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeStaticPolygonContactTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeStaticPolygonEdgesTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/BandDriveTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactDynamicsTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactRhoHistoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactVelocityCorrectionProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContainmentResolutionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContourIsDrawOnlyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/JointStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/MotionControllersPrepareTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/MotionDampingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/PairLambdaCeilingProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/RhoGridReportTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**conventions**:
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/CHANGELOG.md`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Examples/BubblePhysicsShowcase/App/BubbleScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/README.md`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/NativeStaticPolygonEdges.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/Motion.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/Objects.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsRuntime/MotionControllers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSafetyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSolverLifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalBoundsPublicationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalChainKernelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalMotionRoleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalPublicObjectTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeMetalStructuralOperationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeSolverInputTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeStaticPolygonContactTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsNativeMetalTests/NativeStaticPolygonEdgesTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/BandDriveTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactComplianceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactDynamicsTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactRhoHistoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContactVelocityCorrectionProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContainmentResolutionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/ContourIsDrawOnlyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/JointStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/MotionControllersPrepareTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/MotionDampingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/PairLambdaCeilingProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/RhoGridReportTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/docs/MIGRATION-v3.md`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/docs/integration-guide.md`

**docs-coherence**:
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/CHANGELOG.md`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/README.md`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/docs/MIGRATION-v3.md`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/band-damping-two-sided-wall-edges/docs/integration-guide.md`

Withheld (under `docs/sdlc/changes/2026-11-20-engine-3-0-0/`):
- `docs/sdlc/changes/2026-11-20-engine-3-0-0/change-design.md`
- `docs/sdlc/changes/2026-11-20-engine-3-0-0/plan.md`

Sent to every dimension (matched no routing rule):
- `Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`

## Fixes

### Round 1

BLOCKED: the only finding is not a code defect: the recorded verify command `test integracyjny, dwa światy` is prose, not a command (/bin/sh ran it as the `test` builtin and exited 2). The review scope needs …

## Gaps

- Withheld from every read set: `docs/sdlc/changes/2026-11-20-engine-3-0-0/change-design.md`, `docs/sdlc/changes/2026-11-20-engine-3-0-0/plan.md` — they are part of the change, so they remain visible in the diff every reviewer reads.
- tools-verify is partial: adjusted 1 of 1 findings: findings\[0\] states no effect; recorded as 'not stated'
