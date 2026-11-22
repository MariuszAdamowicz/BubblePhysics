# Review: 2026-11-22-wall-center-crossing-deep-squeeze — run 1

**Date:** 2026-11-22
**Artifact:** review
**Verdict:** APPROVED — no blocking findings
**Rounds:** 1
**Feature artifacts:** bugfix.md
**Base:** origin/main
**Base SHA:** 1c51657a0f013dc99492e01421c0b5c1066f8f98
**Head SHA:** 6241f3253cf99d93d2914b0c44366800198a853c
**Reviewer model:** sonnet
**Challenger model:** opus
**Brief-writer model:** opus
**Template version:** default/0.2.0
**Plugin version:** 0.7.11
**Agent Sessions:** claude-code: 6471f48c-4231-467f-bc2e-ff8385f2d538

---

## What changed

<!-- brief:what-changed -->
In 3.0.1, a crowd pressing a soft bubble into a wall above r_ref/c₀ caused repeated step rejections with `SolverGuardCause.centerCrossing` (bugfix.md:13). The author decided a center behind the entry edge is a valid state, so the bubble now settles at ε = c₀·F/r_ref also for ε > 1 (bugfix.md:15, BF-D-5). The contact kernel remembers the entry edge between steps (BF-D-1). The center guard no longer pulls the center back or rejects the step for that edge (BF-D-2, BF-D-3).
<!-- /brief:what-changed -->

## Where human judgement is needed

<!-- brief:human-judgement -->
`Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift:297` (F-7): the bound moved from −1e−3 to −r/10 against a measured 0.2. The author has not yet confirmed this (bugfix.md:124). You decide how much slack is acceptable.

`Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift:114` (F-8): the soft crowd now accepts centers up to 0.5·r behind the frame, measured 0.18·r (bugfix.md:124). The same confirmation is open.

`Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source:221` (F-1): the new branch skips the moving-segment exemption. Whether a static polygon can share an owner with a moving segment depends on scenes the review did not see.

Entry-edge rule in the guard (bugfix.md:120, bugfix.md:126): the game case, crowd pressure with the predicted center in front of the line, has no test that asserts ε > 1.

Corner residual risk (bugfix.md:127): accepted without a change. You decide whether that is acceptable.
<!-- /brief:human-judgement -->

## What was not verified

<!-- brief:not-verified -->
The security dimension wrote no findings file, so no one reviewed security (`Coverage`, `Gaps`). Reviewers did not get `bugfix.md` (`Gaps`). All eight findings, F-1 to F-8, reached you without a challenge (`Findings`). The tools-verify run executed only `DeepSqueezeWallTests`, not the full suite (`Coverage`).
<!-- /brief:not-verified -->

---

## Rounds

| Round | Critical | Major | Minor | Action | Fix commits |
|-------|----------|-------|-------|--------|-------------|
| 1 | 0 | 0 | 8 | stop | 0 |

## Findings

Round 1.

| ID | Severity | Verdict | Dimension | Also flagged by | Site | Summary | Effect | Evidence |
|----|----------|---------|-----------|-----------------|------|---------|--------|----------|
| F-7 | minor | not challenged | testability | conventions | `Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift:297` | The fast-bubble bound was loosened from -1e-3 to -r/10 (1.2 units) although the measured overshoot is 0.2; the test would now pass with a six-fold deeper center-behind-front error, and it no longer distinguishes a CCD regression from the intended squeeze. | A fast bubble could be pushed noticeably deeper into a wall after impact without any test failing. |  |
| F-1 | minor | not challenged | contracts |  | `Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source:221` | The owner-has-entry-edge branch of nativeGuardForbidsCrossing calls nativeCenterCrossing directly and skips the first guard of nativeForbiddenCenterCrossing (line 61: start already on the wrong side of a moving segment s.flags.z is allowed so the guard can repair it), a precondition the old path honored for every segment of the owner. | A soft bubble pressed into a static polygon that shares an owner with a moving segment could have its repair crossing forbidden, so the step is rejected or the bubble is held instead of being freed. |  |
| F-2 | minor | not challenged | design |  | `Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source:252` | nativeGuardedOwner copies the whole owner-walk loop of nativeContainingOwner (testedOwner memo, filter check, nativeInsideOwner) and only adds an extra predicate; the two can drift (a change to the memo or filter rule must be made twice). A predicate/flag parameter on the existing function would avoid the fork. | none |  |
| F-3 | minor | not challenged | design |  | `Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source:158` | The entry-edge concept is encoded twice with different cache semantics: nativeRememberedEntryEdge (previous cache, metadata.z + 1 == limits.x, response.w == 1) and nativeEntryEdge in PostSolve (working cache, metadata.z == limits.x, response.w == 1), each with its own owner scan (nativeOwnerRemembersEntry / nativeOwnerHasEntryEdge). Kernels depend on raw cache fields (response.w feature code, metadata.z frame, frame counter incrementing by 1) with no shared named accessor, so a change to the cache record layout or frame counter breaks both silently. | none |  |
| F-4 | minor | not challenged | design |  | `Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalCenterGuardEdgeTests.swift:220` | GuardKernelFixture re-implements device/queue/library setup, buffer helper and single-thread dispatch that ContainmentKernelFixture in NativeMetalContainmentParallelTests.swift already has (both private, compile the same shader sources); the setup is duplicated instead of shared. | none |  |
| F-5 | minor | not challenged | performance |  | `Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source:205` | nativeOwnerHasEntryEdge rescans all S segments (nativeEntryEdge does a binary search on candidates) and is re-invoked per candidate segment of the same owner in nativeGuardForbidsCrossing and again in the validation loop, instead of once per owner per bubble; per-bubble cost grows toward O(S^2) for crowded static polygons. | On scenes with many static-polygon edges and many soft bubbles near walls the GPU guard kernel step time could grow, causing frame-time spikes; unmeasured and bounded by candidate gating. |  |
| F-6 | minor | not challenged | testability |  | `Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalCenterGuardEdgeTests.swift:290` | buildContact never passes compliance to bubble(), so every nativeBuildContacts case uses a soft bubble; the `soft &&` gating of the memory and exit rule (hard bubble behaves as in 3.0.1) has no test, and removing it would leave all kernel tests green. | A regression making hard (c0 = 0) bubbles use the new edge memory would go unnoticed and could change hard-bubble trajectories near thin walls. |  |
| F-8 | minor | not challenged | testability |  | `Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift:114` | The soft-crowd check now accepts centers up to 0.5 r behind the frame (measured 0.18 r) and the deepest-depth metric only looks at outsideFrame samples, so the assertion is a loose crowd-level bound rather than a requirement-shaped check. | A crowd regression that pushes bubbles about 0.4 r behind the wall would not be detected. |  |

## Refuted findings

None.

## Dimensions that produced no findings

- correctness
- docs-coherence
- tools-verify

## Coverage

| Dimension | State | Reason | Model | Findings |
|-----------|-------|--------|-------|----------|
| correctness | reviewed |  | sonnet | 0 |
| contracts | reviewed |  | sonnet | 1 |
| design | reviewed |  | sonnet | 3 |
| security | gap | no findings file was written at agents/security/findings.json | sonnet | 0 |
| performance | reviewed |  | sonnet | 1 |
| testability | reviewed |  | sonnet | 3 |
| conventions | reviewed |  | sonnet | 1 |
| docs-coherence | reviewed |  | sonnet | 0 |
| dependencies | not applicable | no dependency manifest or lockfile changed | none | 0 |
| infra | not applicable | no .tf or .tfvars file changed | none | 0 |
| tools-verify | reviewed |  | none | 0 |

**correctness** checked:
- nativePolygonEdgeFeature, nativePolygonEdgeExit and nativePathCrossesSegment sign and denominator reasoning (previousSide/centerSide cases)
- nativeBuildContacts new buffers 5/6 against NativeContactControl fields limits.w, limits.x and counts.z, and Swift dispatch buffer order
- nativeEntryEdge, nativeGuardForbidsCrossing, nativeGuardedOwner in NativePostSolveKernels against the working cache and participant keys (bubble identity vs segment identity)
- BF-D-4 outward fallback when distance is zero or NaN in nativeGuardCenter projection
- moved cache search helpers from NativeXPBDKernels to NativeGeometryKernels (same shader library, no duplicate definitions)
- NativeMetalCenterGuardEdgeTests fixtures: buffer indices and control values match kernel signatures
**contracts** checked:
- NativeMetalSolver.swift dispatch sites for nativeBuildContacts and nativeApplyCenterGuards: new buffers 5/6 and 8 bound to contactCache/control/workingCache, grep shows no other Swift callers except diagnostics tests
- cache contract: nativeCacheFind relies on sorted key, counts.z/limits.w counts, metadata.z frame stamp; traced nativeMatchContactCache/nativeRetainContactCache in NativeXPBDKernels to confirm stamps and ordering hold
- nativeForbiddenCenterCrossing preconditions (moving-segment repair exemption, start-inside-owner exemption) versus new nativeGuardForbidsCrossing branches
- nativeCountWork slot 6 usage and nativeContactCompliance/nativeCenterCrossing definition order across the concatenated metal sources
- nativeGuardCenter position.xy meaning (predicted center until the line 1010 write) versus nativeEntryEdge use
**design** checked:
- nativeContainingOwner in NativePostSolveKernels.metal-source:144-155 compared with new nativeGuardedOwner (same owner-walk loop copied)
- entry-edge predicate pair nativeRememberedEntryEdge (previous cache, frame+1) vs nativeEntryEdge (working cache, frame equal) and owner loops nativeOwnerRemembersEntry vs nativeOwnerHasEntryEdge
- cache helpers moved from NativeXPBDKernels to NativeGeometryKernels and host buffer wiring in NativeMetalSolver.swift
- grep for KernelFixture/makeLibrary(source in Tests: ContainmentKernelFixture precedent vs new GuardKernelFixture
- nativeBuildContacts signature (extra previous/world buffers) and nativeGuardCenter signature growth
**performance** checked:
- nativeBuildContacts: nativeRememberedEntryEdge binary search and nativeOwnerRemembersEntry segment scan, gated behind soft && feature==1 && exit short-circuit
- nativeGuardCenter loops: nativeGuardForbidsCrossing/nativeOwnerHasEntryEdge/nativeGuardedOwner per-segment and per-pass cost versus prior nativeForbiddenCenterCrossing O(S) scan
- NativeMetalSolver.swift dispatch changes: two extra buffer bindings only, no new dispatches or allocations
- moved nativeCacheLowerBound/nativeCacheLess to geometry kernels: no duplicate work, same O(log n) lookup
**testability** checked:
- NativeMetalCenterGuardEdgeTests: guard and buildContact cases vs the soft/hard and remembered-edge branches in the diff
- buildContact fixture helper: compliance parameter never passed, so the hard-bubble gate in nativeBuildContacts is untested
- DeepSqueezeWallTests: settle loop and thin-wall assertions can fail on pre-change behavior
- StaticPolygonEdgeTests and CrowdCompressionTests: loosened thresholds (-r/10, 0.5 r) against measured values 0.2 and 0.18 r
- grep of tests using compliance 0 / hard bubble in kernel-level fixtures
**conventions** checked:
- CHANGELOG.md 3.0.2 entry and README version line against 3.0.1 precedent and MigrationGuideTests version assertions
- metal-source comments in NativeGeometryKernels/NativePostSolveKernels vs. code (BF-D-n tags, kernel buffer lists in NativeMetalSolver.swift)
- nativeCacheLess/LowerBound/Same move from XPBD to Geometry kernels and the updated header comment in NativeXPBDKernels
- grep for 3.0.1 / krawędź wejścia in docs, README, Tests (integration-guide.md, AcceptanceEquivalenceTests comments)
- test docstrings and assertion messages in StaticPolygonEdgeTests, CrowdCompressionTests, CrowdSceneSupport, DeepSqueezeWallTests
**docs-coherence** checked:
- CHANGELOG 3.0.2 entry against shader comments and NativeMetalSolver cache-argument comments in the diff
- README version line and MigrationGuideTests assertion/comment both moved to 3.0.2
- grep for 3.0.0/3.0.1 version strings in docs/*.md and Package.swift: only historical mentions remain
- docs/integration-guide.md lines 93-99 (centerCrossing guard, soft contact deflection) read against the new entry-edge behavior
- BF-D-1/BF-D-2/BF-D-3 labels in new comments cross-checked for consistency across kernels
**tools-verify** checked:
- ran `swift test --filter DeepSqueezeWallTests` in the checkout root; exit 0

## What each reviewer was given

Diff: `origin/main...HEAD` (1c51657a..6241f325).

**correctness**:
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalCenterGuardEdgeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/DeepSqueezeWallTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift`

**contracts**:
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalCenterGuardEdgeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/DeepSqueezeWallTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift`

**design**:
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalCenterGuardEdgeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/DeepSqueezeWallTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift`

**security**:
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalCenterGuardEdgeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/DeepSqueezeWallTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift`

**performance**:
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalCenterGuardEdgeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/DeepSqueezeWallTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift`

**testability**:
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalCenterGuardEdgeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/DeepSqueezeWallTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift`

**conventions**:
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/CHANGELOG.md`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/README.md`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalCenterGuardEdgeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/CrowdSceneSupport.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/DeepSqueezeWallTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift`

**docs-coherence**:
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/CHANGELOG.md`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/README.md`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-center-crossing-deep-squeeze/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`

Withheld (under `docs/sdlc/changes/2026-11-22-wall-center-crossing-deep-squeeze/`):
- `docs/sdlc/changes/2026-11-22-wall-center-crossing-deep-squeeze/bugfix.md`

Sent to every dimension (matched no routing rule):
- `Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`

## Fixes

No fix wave ran.

## Gaps

- Withheld from every read set: `docs/sdlc/changes/2026-11-22-wall-center-crossing-deep-squeeze/bugfix.md` — they are part of the change, so they remain visible in the diff every reviewer reads.
- security is gap: no findings file was written at agents/security/findings.json
