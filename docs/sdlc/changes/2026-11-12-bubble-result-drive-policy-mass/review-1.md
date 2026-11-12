# Review: 2026-11-12-bubble-result-drive-policy-mass — run 1

**Date:** 2026-11-12
**Artifact:** review
**Verdict:** APPROVED — no blocking findings
**Rounds:** 1
**Feature artifacts:** light-design.md
**Base:** origin/main
**Base SHA:** d93d7a2c2792272baf8bc63e2815fffb7519a39d
**Head SHA:** 4cc3343b679e3ed84a94ed65896b472314f7eee0
**Reviewer model:** sonnet
**Challenger model:** opus
**Brief-writer model:** opus
**Template version:** default/0.2.0

**Plugin version:** 0.7.10
**Agent Sessions:** claude-code: d5007db8-6043-4c61-acee-71b0edaebd33

---

## What changed

<!-- brief:what-changed -->
`BubbleResult` gains two defaulted fields, `drivePolicy` and `mass`, so a merge result carries its own drive policy instead of always `.standard` and can override its mass (`light-design.md`, Why & what). Linear and angular velocity of a merge result still come from the summed source mass (`light-design.md`, LD-D-1 and deviation 5). A split part with non-nil `mass` is rejected with `invalidStructuralOperation` (LD-D-2). The release is v2.1.0 with a new `CHANGELOG.md` (LD-D-3).
<!-- /brief:what-changed -->

## Where human judgement is needed

<!-- brief:human-judgement -->
- `Sources/BubblePhysicsPublic/Model/WorldTransaction.swift:39` (F-1): the type accepts `mass` for split parts and the runtime rejects it; LD-D-2 chose this, so you decide whether the generic rejection reason is enough.
- Merge velocity (`light-design.md`, LD-D-1): momentum is not conserved when `mass` differs from the source sum; this is a gameplay choice the review could not judge.
- `Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift:167` (F-3): the literal "2.1.0" fails at the next version bump; LD-D-3 asked for it, so you decide whether that cost is intended.
- `docs/MIGRATION-v2.md:18` (F-5): the row omits `drivePolicy:` and `mass:`; deviation 3 left it unchanged on purpose, so you decide whether the guide lists them anyway.
- `Sources/BubblePhysicsRuntime/StructuralOperations.swift:25` (F-2): source mass is summed a second time, added by deviation 5; you decide whether to keep both sums.
<!-- /brief:human-judgement -->

## What was not verified

<!-- brief:not-verified -->
`Gaps` lists `light-design.md` as withheld from every read set, so reviewers saw it only as diff text. `Findings` marks all five findings, F-1 to F-5, as not challenged. `Coverage` shows tools-verify ran only `swift test --filter TransactionStagerTests`; the review did not run the GPU test in `MotionCommandTests` or the full `swift test`.
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
| F-1 | minor | not challenged | design |  | `Sources/BubblePhysicsPublic/Model/WorldTransaction.swift:39` | BubbleResult is shared by merge and split, but the new `mass` field is valid only for merge; split rejects non-nil at runtime (TransactionStager split guard), so the public type admits a state its consumer rejects. | a caller setting mass on a split result gets the whole transaction rejected with a generic invalidStructuralOperation instead of a compile-time error or a specific reason. |  |
| F-2 | minor | not challenged | design |  | `Sources/BubblePhysicsRuntime/StructuralOperations.swift:25` | initializeMerge re-sums source mass (sourceMass) although TransactionStager.merge already computes the same total from descriptor.mass; two independent sums of one quantity (object.mass! vs descriptor.mass) can drift apart. | none under current inputs; a later change to either sum could make linear and angular velocity of a merge result use different masses. |  |
| F-3 | minor | not challenged | testability |  | `Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift:167` | README assertion hardcodes the literal "2.1.0", so the test fails on the next release bump regardless of correctness; it is shaped around this release rather than a requirement (README states a version and links the changelog). | none |  |
| F-4 | minor | not challenged | testability |  | `Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift:251` | Mass validation tests cover only 0 and +infinity; negative and NaN mass (the other branches of requirePositive/finite check for bubble.mass) are untested, and no test shows an overridden mass reaches the solver beyond the staged descriptor. | none |  |
| F-5 | minor | not challenged | conventions |  | `docs/MIGRATION-v2.md:18` | Row says BubbleResult.init ends with layer: and decal:, but the diff (WorldTransaction.swift init) appends drivePolicy: and mass: after decal:, and the migration guide was not updated. | none |  |

## Refuted findings

None.

## Dimensions that produced no findings

- correctness
- contracts
- security
- performance
- docs-coherence
- tools-verify

## Coverage

| Dimension | State | Reason | Model | Findings |
|-----------|-------|--------|-------|----------|
| correctness | reviewed |  | sonnet | 0 |
| contracts | reviewed |  | sonnet | 0 |
| design | reviewed |  | sonnet | 2 |
| security | reviewed |  | sonnet | 0 |
| performance | reviewed |  | sonnet | 0 |
| testability | reviewed |  | sonnet | 2 |
| conventions | reviewed |  | sonnet | 1 |
| docs-coherence | reviewed |  | sonnet | 0 |
| dependencies | not applicable | no dependency manifest or lockfile changed | none | 0 |
| infra | not applicable | no .tf or .tfvars file changed | none | 0 |
| tools-verify | reviewed |  | none | 0 |

**correctness** checked:
- TransactionStager.merge: result.mass override flows into resultDescriptor; velocity still from source momentum/mass
- StructuralOperations.initializeMerge: angularVelocity now uses summed source mass, consistent with source-derived momentum
- TransactionStager.split: mass != nil guard placed before remove(source), rejects with invalidStructuralOperation
- BubbleDescriptor init validation (Objects.swift) of mass via requirePositive covers non-positive and non-finite override
- resultDescriptor passes drivePolicy through to BubbleDescriptor; drivePolicy consumers in MotionControllers
**contracts** checked:
- resultDescriptor and BubbleDescriptor.init (Objects.swift): drivePolicy parameter order and requirePositive validation of overridden mass reached via merge
- StructuralOperations.initializeMerge/initializeSplit: consumers of object.mass! now seeing an overridden mass (split inertia, source loop), and sourceMass replacing result.mass
- TransactionStager applyImpulse and MotionControllers.prepare: consumers of RuntimeObject.mass and bubble.drivePolicy; grep of drivePolicy and .mass across Sources
- split guard ordering: mass nil check precedes remove(source), no state mutation before rejection
**design** checked:
- diff of WorldTransaction.swift BubbleResult new fields and init
- TransactionStager.merge and split: where mass and drivePolicy flow, resultDescriptor
- StructuralOperations.initializeMerge and its only caller (grep)
- BubbleSplitPart/BubbleResult reuse in split path
- precedent: filter/layer/decal were added to BubbleResult the same way
**security** checked:
- diff.txt all code hunks: no secrets, logging, shell, path or template use
- BubbleResult.mass path through resultDescriptor validated by new tests (zero and infinity rejected)
- BubbleDrivePolicy throwing init, drivePolicy passed into descriptor in TransactionStager.resultDescriptor
- splitBubble mass guard versus merge sibling checks in TransactionStager
- StructuralOperations.initializeMerge sourceMass division: sources already validated positive
- no dependency or Package changes in diff; no deserialization or eval
**performance** checked:
- TransactionStager.merge: new result.mass ?? Float(mass) is O(1), no added loop
- StructuralOperations.initializeMerge: sourceMass accumulated inside existing per-source loop, no extra pass
- TransactionStager.split: added mass==nil guard is O(1) before remove(source)
- BubbleResult new fields are value types copied per transaction, no collection or buffer growth
- Tests and docs in diff: no runtime hot-path impact
**testability** checked:
- TransactionStagerTests new tests vs merge/split changes in TransactionStager.swift (drivePolicy, mass override, split rejection both orders)
- angular velocity test traced through StructuralOperations.initializeMerge (only caller is TransactionStager.swift:594, so stager tests exercise it; old code would give differing values at mass 10)
- MotionCommandTests GPU test: 0.05 vs 0.2 discriminates policy 3 from standard 12
- MigrationGuideTests README assertion hardcodes 2.1.0
- helpers bubble()/state() in TransactionStagerTests (mass 2 each, so sum 4 assertion is sound)
**conventions** checked:
- BubbleResult doc comments and init parameter order vs layer/decal precedent in WorldTransaction.swift
- grep BubbleResult in README, MIGRATION-v2.md, integration-guide.md for stale docs
- CHANGELOG.md, README and MigrationGuideTests wording vs behaviour
- StructuralOperations.initializeMerge comment and TransactionStager merge/split comments vs code
- new tests in TransactionStagerTests and MotionCommandTests naming and doc-comment style vs neighbours
**docs-coherence** checked:
- CHANGELOG.md 2.1.0 claims vs BubbleResult init, merge/split staging in TransactionStager.swift
- integration-guide.md line 205 paragraph vs StructuralOperations.initializeMerge angular velocity
- BubbleDrivePolicy .standard defaults (rigidifies, maximumSpeed 12) in Motion.swift vs CHANGELOG
- requirePositive/invalidValue error names (bubble.mass) in Objects.swift and WorldConfiguration.swift
- README version line and links; MIGRATION-v2.md BubbleResult init rows (grep of BubbleResult in docs)
**tools-verify** checked:
- ran `swift test --filter TransactionStagerTests` in the checkout root; exit 0

## What each reviewer was given

Diff: `origin/main...HEAD` (d93d7a2c..4cc3343b).

**correctness**:
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/StructuralOperations.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**contracts**:
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/StructuralOperations.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**design**:
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/StructuralOperations.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**security**:
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/StructuralOperations.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**performance**:
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/StructuralOperations.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**testability**:
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/StructuralOperations.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**conventions**:
- `/Users/adamowim/priv/ios/bubble_phisics/CHANGELOG.md`
- `/Users/adamowim/priv/ios/bubble_phisics/README.md`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/StructuralOperations.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/integration-guide.md`

**docs-coherence**:
- `/Users/adamowim/priv/ios/bubble_phisics/CHANGELOG.md`
- `/Users/adamowim/priv/ios/bubble_phisics/README.md`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/integration-guide.md`

Withheld (under `docs/sdlc/changes/2026-11-12-bubble-result-drive-policy-mass/`):
- `docs/sdlc/changes/2026-11-12-bubble-result-drive-policy-mass/light-design.md`

Sent to every dimension (matched no routing rule):
- none

## Fixes

No fix wave ran.

## Gaps

- Withheld from every read set: `docs/sdlc/changes/2026-11-12-bubble-result-drive-policy-mass/light-design.md` — they are part of the change, so they remain visible in the diff every reviewer reads.
