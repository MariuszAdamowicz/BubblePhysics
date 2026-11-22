# Review: 2026-11-21-wall-contact-damping-inside-edge — run 1

**Date:** 2026-11-22
**Artifact:** review
**Verdict:** APPROVED — no blocking findings
**Rounds:** 1
**Feature artifacts:** bugfix.md
**Base:** origin/main
**Base SHA:** 2e07451a2102751ba6bd587197b7fbcc852dc23d
**Head SHA:** 4311f1fbca7fc8bc5bbc2847c60815d4602d2f6a
**Reviewer model:** sonnet
**Challenger model:** opus
**Brief-writer model:** opus
**Template version:** default/0.2.0

**Plugin version:** 0.7.11
**Agent Sessions:** claude-code: 9973b99e-3184-4f51-8b32-9d7cd39602b3

---

## What changed

<!-- brief:what-changed -->
This branch fixes a bug in the native path where a small soft bubble pushed by the band into a wall stays with its center on the wall edge (ε 0.9999) instead of settling at c·F (bugfix.md:12). The soft-contact dashpot now damps at every approach speed; hard contacts keep the restSpeed skip (BF-D-2, bugfix.md:116). A static polygon edge also pushes out a center whose step path crossed that edge segment (BF-D-1, bugfix.md:152). CHANGELOG gains a 3.0.1 section (bugfix.md:122).
<!-- /brief:what-changed -->

## Where human judgement is needed

<!-- brief:human-judgement -->
- `Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift:30`: the golden hashes were regenerated because the entry-edge rule also changes hard contacts (BF-D-4, F-4); you decide whether that change for hard contacts is wanted, since the hashes show only that results changed.
- `Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift:171`: the test moved to dampingRatio 0 (BF-D-5, F-1); you decide whether the damped release at ζ_c 1 needs its own assertion.
- `Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source:1093`: soft contacts now damp also against fast kinematic obstacles (BF-D-2, F-2); the right behavior there depends on how the game uses moving obstacles.
- `bugfix.md:93`: the entry edge depends on the center guard leaving the center on the entry side, and a center that starts inside a solid gets no edge contact (BF-D-1, bugfix.md:136).
- `docs/integration-guide.md:100`: you decide whether the wall paragraph must describe the entry-edge rule (F-5).
<!-- /brief:human-judgement -->

## What was not verified

<!-- brief:not-verified -->
The docs-coherence dimension wrote no findings file, so documentation was not checked against code (Gaps, Coverage). bugfix.md was withheld from every read set (Gaps). The verify step ran only `grep -n "## 3.0.1" CHANGELOG.md`, not `swift test` (Coverage). F-1 to F-5 reached you unchallenged (Findings).
<!-- /brief:not-verified -->

---

## Rounds

| Round | Critical | Major | Minor | Action | Fix commits |
|-------|----------|-------|-------|--------|-------------|
| 1 | 0 | 0 | 5 | stop | 0 |

## Findings

Round 1.

| ID | Severity | Verdict | Dimension | Also flagged by | Site | Summary | Effect | Evidence |
|----|----------|---------|-----------|-----------------|------|---------|--------|----------|
| F-1 | minor | not challenged | testability |  | `Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift:171` | Test changed from dampingRatio 1 to 0 to dodge the new always-on soft dashpot; the contained-pair launch is no longer exercised with damping, and nothing asserts the damped release behavior the new comment claims (pair critically damped, small bubble does not reach the obstacle). | A regression in damped soft-contact release of a contained pair would go unnoticed by tests. |  |
| F-2 | minor | not challenged | testability |  | `Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source:1093` | The gate change `record.compliance.x <= 0 && abs(normalVelocity) > restSpeed` is covered by a single wall-impact scenario; no test covers soft contact against a fast kinematic obstacle or high-speed separation, which the new comment explicitly says behave specially. | Dashpot braking of fast approaching or separating soft contacts could regress without any test failing. |  |
| F-3 | minor | not challenged | testability |  | `Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift:300` | The new entry-edge branch (previousSide<0 return 0, crossing-point test, previous exactly on the line) is covered by one oblique-corner scenario; the thin-wall back-edge and straight-through cases named in the shader comment have no direct test, and in-loop assertions run only at indices 1 and 2. | A regression in entry-edge selection for other approach angles could let bubbles tunnel through or snag on thin walls undetected. |  |
| F-4 | minor | not challenged | testability |  | `Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift:30` | Behavior change is absorbed by regenerating opaque golden hashes (object, contour, pixel, pair-limit) pinned to one GPU and a referenceCommit; the hashes cannot show the new values are correct, only that they changed. | A wrong simulation result in these dense scenes would be baked into the reference and pass silently. |  |
| F-5 | minor | not challenged | conventions |  | `docs/integration-guide.md:100` | The 'Ściany i krawędzie wielokątów' paragraph still defines edge contact only as the edge-interior area or a convex vertex; the diff adds the entry-edge rule (center behind the line, path crossing the segment) and the CHANGELOG says hard-contact wall trajectories change, but this paragraph was not updated while the neighbouring damping paragraph was. | none |  |

## Refuted findings

None.

## Dimensions that produced no findings

- correctness
- contracts
- design
- security
- performance
- tools-verify

## Coverage

| Dimension | State | Reason | Model | Findings |
|-----------|-------|--------|-------|----------|
| correctness | reviewed |  | sonnet | 0 |
| contracts | reviewed |  | sonnet | 0 |
| design | reviewed |  | sonnet | 0 |
| security | reviewed |  | sonnet | 0 |
| performance | reviewed |  | sonnet | 0 |
| testability | reviewed |  | sonnet | 4 |
| conventions | reviewed |  | sonnet | 1 |
| docs-coherence | gap | no findings file was written at agents/docs-coherence/findings.json | sonnet | 0 |
| dependencies | not applicable | no dependency manifest or lockfile changed | none | 0 |
| infra | not applicable | no .tf or .tfvars file changed | none | 0 |
| tools-verify | reviewed |  | none | 0 |

**correctness** checked:
- nativePolygonEdgeFeature crossing interpolation: denominator positive, fraction in \[0,1), previousSide==0 case
- position.zw holds start-of-step center (NativeGeometryKernels line 172, nativePredict) so the new previous argument is valid
- only caller of nativePolygonEdgeFeature updated (grep)
- dashpot threshold change in nativeDampContactNormalMotion: hard contacts keep restSpeed skip, soft contacts damp at all speeds
- test diffs skimmed for wrong conditions
**contracts** checked:
- nativePolygonEdgeFeature sole caller in nativeBuildContacts (grep): new previous arg is a.position.zw
- nativePredict sets position.zw = position.xy at step start, same slot used by CCD/post-solve kernels (grep position.zw)
- nativeDampContactNormalMotion: compliance.x > 0 branch vs restSpeed gate, compliance semantics at lines 340-373 and 1075-1093 of NativeXPBDKernels
- previousSide/centerSide denominator positivity and crossing projection in the new edge-feature branch
**design** checked:
- diff of NativeGeometryKernels nativePolygonEdgeFeature new previous parameter and its single call site in nativeBuildContacts
- grep for other implementations of PolygonEdgeFeature/pastSegmentEnd in Sources and Tests: only the metal kernel, no duplicated CPU logic
- position.zw as previous-step center: precedent in nativePredict (line 172) and NativeXPBDKernels lines 717-747 using a.position.zw the same way
- nativeDampContactNormalMotion change in NativeXPBDKernels: branching on record.compliance.x is consistent with the existing compliance.x use a few lines above
- test diffs skimmed for boundary/placement of helpers
**security** checked:
- secrets/credentials: diff changes are shader math, tests, docs; no log, error message or caller output of credentials added
- injection: no shell, path, SQL or template construction in added lines (shader kernels and XCTest code only)
- deserialization/evaluation: no decode, load or eval calls added; Metal sources are static kernels
- new entry points: nativePolygonEdgeFeature gained a previous-center argument, single caller nativeBuildContacts updated; no new kernel or API surface
- shader arithmetic in nativePolygonEdgeFeature: division by (previousSide - centerSide) is positive on that path (previousSide>=0>centerSide), no divide-by-zero or OOB buffer index added
- dependencies: no Package.swift or manifest change in the diff file list
**performance** checked:
- nativePolygonEdgeFeature in NativeGeometryKernels.metal-source: new branch adds one dot, one divide and one segment test, no loop, per edge contact only
- nativeBuildContacts caller: passes a.position.zw from the already-loaded bubble struct, no extra buffer read or per-iteration recompute
- nativeDampContactNormalMotion in NativeXPBDKernels.metal-source: the changed continue condition adds a compliance compare; soft contacts now run the dashpot instead of skipping it, still inside the existing per-record loop
- diff hunks for tests, docs and CHANGELOG: no collections, buffers, I/O or loops that could grow or block
**testability** checked:
- diff of NativeGeometryKernels nativePolygonEdgeFeature branches vs StaticPolygonEdgeTests oblique-entry test
- diff of NativeXPBDKernels dashpot gate (record.compliance.x <= 0) vs WallImpactTests (a)/(b) and CrowdCompressionTests change
- WallImpactTests run() helper: preconditions and assertions that can fail without the fix
- golden hash updates in AcceptanceEquivalenceTests / AcceptanceRenderEquivalenceTests and referenceCommit values
**conventions** checked:
- diff.txt read in full: CHANGELOG, README, both metal-source files, six test files, integration-guide
- grep nativePolygonEdgeFeature: only definition and one caller, both updated to the new signature
- git cat-file f65b13c: referenceCommit exists in history, matches the reference-hash comments
- grep for restSpeed/max(40 and version 3.0.0 in docs and README: integration-guide damping paragraph and MigrationGuideTests already updated
- integration-guide.md line 100 wall paragraph compared with the new entry-edge rule in the shader and CHANGELOG
**tools-verify** checked:
- ran `grep -n "## 3.0.1" CHANGELOG.md` in the checkout root; exit 0

## What each reviewer was given

Diff: `origin/main...HEAD` (2e07451a..4311f1fb).

**correctness**:
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsRuntimeTests/WallImpactTests.swift`

**contracts**:
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsRuntimeTests/WallImpactTests.swift`

**design**:
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsRuntimeTests/WallImpactTests.swift`

**security**:
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsRuntimeTests/WallImpactTests.swift`

**performance**:
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsRuntimeTests/WallImpactTests.swift`

**testability**:
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsRuntimeTests/WallImpactTests.swift`

**conventions**:
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/CHANGELOG.md`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/README.md`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsRuntimeTests/CrowdCompressionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsRuntimeTests/StaticPolygonEdgeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Tests/BubblePhysicsRuntimeTests/WallImpactTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/docs/integration-guide.md`

**docs-coherence**:
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/CHANGELOG.md`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/README.md`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/.claude/worktrees/wall-contact-damping-inside-edge/docs/integration-guide.md`

Withheld (under `docs/sdlc/changes/2026-11-21-wall-contact-damping-inside-edge/`):
- `docs/sdlc/changes/2026-11-21-wall-contact-damping-inside-edge/bugfix.md`

Sent to every dimension (matched no routing rule):
- `Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`

## Fixes

No fix wave ran.

## Gaps

- Withheld from every read set: `docs/sdlc/changes/2026-11-21-wall-contact-damping-inside-edge/bugfix.md` — they are part of the change, so they remain visible in the diff every reviewer reads.
- docs-coherence is gap: no findings file was written at agents/docs-coherence/findings.json
