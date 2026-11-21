# Review: 2026-11-20-engine-3-0-0 — run 2

**Date:** 2026-11-21
**Artifact:** review
**Verdict:** APPROVED — no blocking findings
**Rounds:** 1
**Feature artifacts:** change-design.md, plan.md
**Base:** origin/main
**Base SHA:** e669fb1c2c1ed34abbce55f0e12b6cccf654f1ef
**Head SHA:** 3dffd033f0d783907be862cf7c9af919ffb2ea59
**Reviewer model:** sonnet
**Challenger model:** opus
**Brief-writer model:** opus
**Template version:** default/0.2.0

**Plugin version:** 0.7.11
**Agent Sessions:** claude-code: f5cbe17c-3e25-4a0c-8e89-346e05bfa66f

---

## What changed

<!-- brief:what-changed -->
BubblePhysics 3.0.0 fixes two errors that kept a bubble at rest from deflecting by c · F. The band damping is removed, and the material damping now multiplies velocity before the force increment F/m · dt is added. Static polygon edges push only from the outside, and a convex vertex gives one contact. Compliance drops ρ and the exponents, the player drive is band-only, and the contour is draw-only and can no longer reject a step (change-design.md, plan.md).
<!-- /brief:what-changed -->

## Where human judgement is needed

<!-- brief:human-judgement -->
- `Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift:1010` (F-1): removing the contour guards is the accepted trade-off of CD-D-2 in change-design.md; you decide whether an unflagged broken outline far from the origin is acceptable.
- `Sources/BubblePhysicsRuntime/MotionControllers.swift:46` (F-3): plan.md:166 keeps `collisionRadius` as a copy of `targetRadius`; you decide whether to keep or remove the duplicate field.
- `Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift:60` (F-4): `convexEnd` is packed for the GPU but no kernel reads it; you decide whether to keep it for later use or remove it.
- `Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source:423` (F-5): the region formulas exist in two kernels; you decide whether a shared function is worth the change.
- `Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift:277` (F-6): the winding test also passes with no wall; you decide whether it meets the intent of G2-AC3 in change-design.md.
<!-- /brief:human-judgement -->

## What was not verified

<!-- brief:not-verified -->
The review did not run the test suite: tools-verify is a gap because the verify command exceeded 10 minutes (Coverage, Gaps). change-design.md, plan.md and review-1.md were withheld from every read set (Gaps). All nine findings, F-1 to F-9, reached you unchallenged (Findings). Dependencies and infra were not applicable (Coverage).
<!-- /brief:not-verified -->

---

## Rounds

| Round | Critical | Major | Minor | Action | Fix commits |
|-------|----------|-------|-------|--------|-------------|
| 1 | 0 | 0 | 9 | stop | 0 |

## Findings

Round 1.

| ID | Severity | Verdict | Dimension | Also flagged by | Site | Summary | Effect | Evidence |
|----|----------|---------|-----------|-----------------|------|---------|--------|----------|
| F-1 | minor | not challenged | correctness |  | `Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift:1010` | Contour finite/segment-length/range guards removed from frame read-back and kernels; non-finite or oversized contour points (e.g. from very large centers) are now published unchanged with no error or event, only bounds/effectiveRadius fall back silently. | A bubble far from the origin can be drawn with NaN or overlong contour vertices (glitched or invisible outline) while the step reports success. |  |
| F-2 | minor | not challenged | contracts |  | `Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source:703` | nativeBuildContacts still seeds the renamed `compliance` lane with the old rho default float4(1, 1, 0, 0), contradicting the documented layout (x = c_a + c_b, y/z/w reserved) and the Swift default `.zero`; a new record carries compliance.x = 1 until nativePrepareSolverContacts overwrites it, and an inactive record keeps that stale 1 in the retained cache. | none |  |
| F-3 | minor | not challenged | design |  | `Sources/BubblePhysicsRuntime/MotionControllers.swift:46` | collisionRadius is now unconditionally reset to targetRadius every step, so RuntimeObject/NativePublicObject.collisionRadius is a redundant second copy of targetRadius that callers still read (StructuralOperations, stager worst-alpha, NativePublicWorld) and debugBubbleRadii exposes both. | none |  |
| F-4 | minor | not challenged | design |  | `Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift:60` | NativeSolverPolygonEdge.convexEnd is a package field computed on the host and packed into flags.w bit 2 of every polygon segment record, but no kernel reads it (the doc comments say so), so it widens the package surface and GPU layout with unused data. | none |  |
| F-5 | minor | not challenged | design |  | `Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source:423` | The polygon-edge feature 1/2 normal and penetration formulas are written twice, in nativeBuildContacts (Geometry kernels, line 689) and in nativeConstraintGeometry; a future change to one region rule must be mirrored by hand in the other or contact build and solver normals diverge. | none |  |
| F-6 | minor | not challenged | testability |  | `Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift:277` | The only absolute check in the winding test, slid.y < corner.y - 300, also holds with no wall at all: bubble 3 pushed along 195 deg with force 600, gamma 2, m 1.36 for 600 steps drifts about 570 units down in y; bubbles 1, 2 and 4 are compared only between the two worlds, so identical wall-ignoring behavior in both passes. | A regression that made polygon walls non-solid (or mishandled both windings the same way) would pass this test, so bubbles could fly through walls until another test catches it. |  |
| F-7 | minor | not challenged | testability |  | `Tests/BubblePhysicsNativeMetalTests/NativeStaticPolygonContactTests.swift:36` | Helper contains(_:_:) is copied verbatim from NativeStaticPolygonEdgesTests.swift (same target), and the world/advance/settle scaffolding in StaticPolygonEdgeTests and MotionDampingTests is near-identical instead of living in CrowdSceneSupport.swift where the shared scene helpers already are. | none |  |
| F-8 | minor | not challenged | docs-coherence |  | `docs/MIGRATION-v3.md:38` | Claims the approximation K*s/(m*gamma) of the steady-state velocity K*s*dt/(m*(1-e^(-gamma*dt))) is off by a fraction of a percent at gamma*dt about 0.03, but the ratio is x/(1-e^-x) = 1+x/2, i.e. about 1.5% (about 1.25% for the example gamma 1.5 at dt 1/60). | A game developer tuning K from the documented formula gets a grip speed about 1 to 1.5% lower than the approximation predicts, a small mismatch versus the doc's stated accuracy. |  |
| F-9 | minor | not challenged | docs-coherence |  | `Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift:102` | Doc of NativeSolverSegment.fixed still says 'Statyczny, dwustronny segment bez ruchu (krawędź statycznej bryły)', but this change makes static polygon edges one-sided (NativeStaticPolygonEdges sets polygonEdge on top of fixed), so the comment no longer describes how polygon edges behave. | none |  |

## Refuted findings

None.

## Dimensions that produced no findings

- security
- performance
- conventions

## Coverage

| Dimension | State | Reason | Model | Findings |
|-----------|-------|--------|-------|----------|
| correctness | reviewed |  | sonnet | 1 |
| contracts | reviewed |  | sonnet | 1 |
| design | reviewed |  | sonnet | 3 |
| security | reviewed |  | sonnet | 0 |
| performance | reviewed |  | sonnet | 0 |
| testability | reviewed |  | sonnet | 2 |
| conventions | reviewed |  | sonnet | 0 |
| docs-coherence | reviewed |  | sonnet | 2 |
| dependencies | not applicable | no dependency manifest or lockfile changed | none | 0 |
| infra | not applicable | no .tf or .tfvars file changed | none | 0 |
| tools-verify | gap | verify command exceeded 10 minutes | none | 0 |

**correctness** checked:
- NativeStaticPolygonEdges.swift: signedArea, collinear merge loop, outwardSign and convex flags vs nativePolygonEdgeFeature region complement in NativeGeometryKernels.metal-source
- nativeBuildContacts feature 0 (-FLT_MAX) dropped by nativePrepareContactFlags/nativeCompactActiveContacts; stale cached edge records deactivated in nativeEmitAdjacency (metadata.z vs limits.x)
- MotionControllers.prepare host damping vs removed GPU damping in nativePredict/nativeRigidPredict; requireDrivePolicy and band stability in TransactionStager
- NativeMetalSolver frame read-back: removed contour guards, nil bounds and effectiveRadius fallbacks; grep for leftover nativeUpdateContactRho/rho references (none)
- Removed safety param from nativeSeedStructuralContours and matching Swift buffer list; BubbleContactCompliance/scaledBase and validateWorstAlpha
**contracts** checked:
- NativeGeometryKernels/NativeXPBDKernels/NativePostSolveKernels: every reader of the contact cache record (response.w feature, compliance lanes) after nativeBuildContacts, incl. emitAdjacency stale-record path, compaction of -FLT_MAX candidates, nativeDampContactNormalMotion and nativeAccumulateContactPressure
- NativePublicWorld/NativeMetalBufferLayout/NativeMetalSolver: segment ID allocation, segment change detection, NativeMetalSegment stride, nativeSeedStructuralContours buffer indices vs host dispatch, stageNames after nativeUpdateContactRho removal
- contour finite/length checks removed: grep of GPU readers of bubble.deformation.xy and bounds (only hit test and render prep), host sanitizing of effectiveRadius and bounds, QueryIndex and publishedObjectStates fallbacks
- MotionControllers.prepare host damping vs nativePredict/nativeRigidPredict, NativeCompleteStepper call site, PhysicsMaterial damping validation, collisionRadius consumers
- TransactionStager requireDrivePolicy/beginPlayerDrive/merge result drivePolicy, BubbleScene example call sites, grep for removed rho/rigidity/bandDamping/capturedRadius symbols in Sources and Examples
**design** checked:
- Sources/BubblePhysicsRuntime/MotionControllers.swift: damping moved to host prepare; grep of material.x in shaders shows GPU linear damping kept only for the non-public path and angular damping still read from the same lane
- grep collisionRadius across Sources: after the change it is assigned from targetRadius every step and only read as a second copy in stager, structural ops and debugBubbleRadii
- NativeStaticPolygonEdges.swift, NativeSolverInput.swift, NativeMetalBufferLayout.swift: grep convexEnd shows it is written and packed into flags.w bit 2 but no kernel reads it
- NativeGeometryKernels.metal-source nativeBuildContacts vs NativeXPBDKernels.metal-source nativeConstraintGeometry: feature 1/2 normal and penetration formulas written in both places
- TransactionStager.swift requireDrivePolicy / requireBandDriveTarget and BubbleWorld.debugBubbleRadii (precedent debugContourSnapshot in the same file) for public surface width
**security** checked:
- secrets/credentials: grep of the diff and read set for logs, error messages and strings; the only error paths are ModelValidationError and TransactionRejectionReason with field names and object IDs, no secrets
- injection and deserialization: no shell, SQL, path, template, eval or decoding code in the changed Swift or Metal sources; NativeStaticPolygonEdges.segments takes only numeric vertices
- new entry points: beginPlayerDrive now goes through requireDrivePolicy; TransactionStager setMotionRole(.playerDriven) still requires an active playerDriveTarget (line 285), so the drive-policy check cannot be bypassed; updatePlayerDrive keeps requireBandDriveTarget
- GPU buffer bounds: nativeSeedStructuralContours buffer indices (8-10) match the Swift dispatch list in NativeMetalSolver; nativeEmitAdjacency guards b < control.counts.y before reading segments\[b\]; NativeSegment.region added on both the Swift and Metal sides
- dependencies: no Package.swift or Package.resolved change in the diff, no new imports beyond simd
- removed safety checks in contour kernels: contour output is draw-only, physics finiteness stays in nativeCheckFinite; no trust boundary or secret involved
**performance** checked:
- MotionControllers.prepare: per-object lazy damping closure and hash lookup of state.physicsMaterials, captured once per step as a CoW reference (no dictionary copy, no lookup for static/kinematic/path roles)
- NativeStaticPolygonEdges.segments and mergingCollinearEdges: O(n^2) ring.remove only at staging time per polygon (cached in candidatePolygons), not per frame
- nativeBuildContacts / nativePolygonEdgeFeature / nativePastSegmentEnd and nativeEmitAdjacency: constant work per candidate, extra segments\[b\] read only; removal of nativeUpdateContactRho dispatch and pow() shrinks per-step GPU work
- NativeMetalSolver frame readback loop: per-bubble guards replaced by O(1) fallbacks, bubbleBounds optional array reserved up front; removed isfinite/edge-length validation loops in render-data kernels
- Unbounded growth: NativeMetalSegment gains one float4 per segment (fixed size), cache records for stale polygon edges still bounded by the existing 30-frame retention; debugBubbleRadii is a test-only seam
**testability** checked:
- MotionControllers.prepare damping/band changes vs MotionDampingTests, MotionControllersPrepareTests, BandDriveTests (behaviour pinned with closed-form expectations for dynamic, motorDriven, playerDriven, path, kinematic)
- TransactionStager requireDrivePolicy and validateWorstAlpha vs TransactionStagerTests and ContactComplianceTests (reject, boundary accept, replace/merge/split, running transition)
- NativeStaticPolygonEdges and nativePolygonEdgeFeature kernel vs NativeStaticPolygonEdgesTests, NativeStaticPolygonContactTests, StaticPolygonEdgeTests (both windings, ULP boundaries, thin wall, vertex, fast bubble)
- Safety/contour draw-only changes vs NativeMetalSafetyTests, NativeMetalBoundsPublicationTests, ContourIsDrawOnlyTests, NativeMetalChainKernelTests (corruption injected, accepted-frame and repaired values asserted)
- StaticPolygonEdgeTests.testWindingOfTheVerticesDoesNotChangeTheTrajectories assertions traced against a scene with no wall contact
- read of duplicated test helpers (contains, distance, world, advance) across the new test files
**conventions** checked:
- grep Sources/Examples/README/integration-guide/Tests for removed names (nativeUpdateContactRho, rigidifies, maximumSpeed, distanceResponse, bandDamping, radiusExponent, compressionExponent, BubbleDrivePolicy.standard): only CHANGELOG/MIGRATION removal notes and the integration-guide statement that bandDamping does not exist remain
- NativeGeometryKernels.metal-source nativePredict comment vs MotionControllers.dampedVelocity: comment matches the code
- CHANGELOG.md 3.0.0 section vs MIGRATION-v3.md and README version line: version and links consistent, older 2.3.0 entries keep historical wording
- Resources.swift PhysicsMaterial doc comments (contactDampingRatio, contactCompliance) vs diff: match
- Tests directory for files named in the diff (ContactRhoHistoryTests) that no longer exist: deleted, no dangling references
- grep of added lines in diff.txt for TODO/FIXME/HACK markers: none
**docs-coherence** checked:
- CHANGELOG.md 3.0.0 entry against the diff of Resources.swift, Motion.swift, Objects.swift, NativeMetalBufferLayout.swift (segment 112 to 128 B, compliance.x, polygon edge flags) and MotionControllers.swift
- docs/MIGRATION-v3.md formulas (steady-state velocity, K = v*m*gamma/s example numbers 18 and 2400) recomputed against the host damping step v*e^(-gamma*dt)+F/m*dt
- docs/integration-guide.md grip-policy region compared with BubbleScene.swift guide-region (K 20, force 600, damping 1.5); grep of README, guide and Sources for leftover bandDamping, rigidifies, radiusExponent, rho, .standard, nativeUpdateContactRho
- README.md version line and Metal shader comments (NativeGeometry/PostSolve/XPBD kernels) for stale rho or two-sided wording
- NativeSolverInput.swift doc comments around the new polygonEdge field

## What each reviewer was given

Diff: `origin/main...HEAD` (e669fb1c..3dffd033).

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
- `docs/sdlc/changes/2026-11-20-engine-3-0-0/review-1.md`

Sent to every dimension (matched no routing rule):
- `Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`

## Fixes

No fix wave ran.

## Gaps

- Withheld from every read set: `docs/sdlc/changes/2026-11-20-engine-3-0-0/change-design.md`, `docs/sdlc/changes/2026-11-20-engine-3-0-0/plan.md`, `docs/sdlc/changes/2026-11-20-engine-3-0-0/review-1.md` — they are part of the change, so they remain visible in the diff every reviewer reads.
- verify command exceeded 10 minutes
- tools-verify is gap: verify command exceeded 10 minutes
