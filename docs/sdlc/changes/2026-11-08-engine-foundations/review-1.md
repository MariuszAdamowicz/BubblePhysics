# Review: 2026-11-08-engine-foundations — run 1

**Date:** 2026-11-11
**Artifact:** review
**Verdict:** APPROVED — no blocking findings
**Rounds:** 3
**Feature artifacts:** change-design.md, plan.md
**Base:** 5d2c9a7
**Base SHA:** 5d2c9a7c6e39fcf21aee0b76a45dc13d23aff66f
**Head SHA:** 1a7afd7a5ead62d4349bb4798a66eb36f4bc7621
**Reviewer model:** sonnet
**Challenger model:** opus
**Brief-writer model:** opus
**Template version:** default/0.2.0

**Plugin version:** 0.7.7
**Agent Sessions:** claude-code: deee7915-ab14-435b-8ec9-953c7d0fa180

---

## What changed

<!-- brief:what-changed -->
The branch turns BubblePhysics v1.0.0 into a breaking v2.0.0, so a game supplies only logic and graphic data while the engine owns physics and rendering (change-design.md, CD-D-1). It adds published object state, textured render materials, layers, decals, a kinematic role, collision filters, contact events, spatial queries, joints and rigid circles and capsules. It removes the diagnostic reference solver and O(n²) loops from the production step (CD-D-17). An iPhone X run measures capacity at 60 FPS, without a required minimum (CD-D-30).
<!-- /brief:what-changed -->

## Where human judgement is needed

<!-- brief:human-judgement -->
- F-3, `Sources/BubblePhysicsRuntime/QueryIndex.swift:47`: synchronous queries treat a bubble as a circle of its minimum contour radius, which G8-AC1 and CD-D-10 in change-design.md accepted; you decide whether misses on a bulging bubble are acceptable.
- F-19 and F-20, `Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift:61`: the reference-hash tests run only on an "Apple M1 Pro" and skip elsewhere; you decide whether CI needs a failing gate instead.
- F-1, `Sources/BubblePhysicsRuntime/TransactionStager.swift:297`: path drives are outside the 1e6 limit; whether the limit must cover them depends on what the limit is meant to protect.
- F-4, `Sources/BubblePhysicsPublic/Model/WorldConfiguration.swift:29`: published bounds can have zero size, against the documented `WorldRectangle` invariant; you choose between changing the documentation and clamping the bounds.
- F-11, `Sources/BubblePhysicsPublic/BubbleWorld.swift:192`: the hit-test queue has no cap, but G8-AC2 requires queries to wait during pause, so a cap changes a requirement.
<!-- /brief:human-judgement -->

## What was not verified

<!-- brief:not-verified -->
All 26 findings in `Findings` are "not challenged"; no challenger checked them. `scope.json` lists 13 paths that matched no reviewer dimension, among them the four `.metal-source` shader files, both Xcode project files and the signing xcconfig files. `Gaps`: change-design.md and plan.md were withheld from every read set. `Coverage` shows tools-verify ran only `test obrazu`, not the iPhone X capacity run.
<!-- /brief:not-verified -->

---

## Rounds

| Round | Critical | Major | Minor | Action | Fix commits |
|-------|----------|-------|-------|--------|-------------|
| 1 | 0 | 4 | 23 | fix | 4 |
| 2 | 0 | 1 | 22 | fix | 1 |
| 3 | 0 | 0 | 26 | stop | 0 |

## Findings

Round 3.

| ID | Severity | Verdict | Dimension | Also flagged by | Site | Summary | Effect | Evidence |
|----|----------|---------|-----------|-----------------|------|---------|--------|----------|
| F-22 | minor | not challenged | conventions | docs-coherence | `docs/MIGRATION-v2.md:65` | Wpis o limicie 1e6 nadal mówi tylko o napędzie kinematycznym (.target/.velocity), a stager odrzuca teraz też napęd silnikowy, kotwice, kąt odniesienia, parametry dystansu oraz zakres i prędkość docelową zawiasu (TransactionStager.swift add(_ joint:), setMotorDrive). | integrator czytający przewodnik migracji nie dowie się, że transakcja z kotwicą lub siłą silnika powyżej 1e6 jest teraz odrzucana z valueOutOfRange. |  |
| F-1 | minor | not challenged | correctness |  | `Sources/BubblePhysicsRuntime/TransactionStager.swift:297` | setKinematicDrive(.path) skips the 1e6 magnitude guard (comment says PathDrive.init checks it, but init only requires finite points and speed > 0), so finite huge points/speed reach applyKinematicDrive, which has no finite check, unlike .velocity/.target in the same switch; the same gap exists for setPathDrive. | A game that submits a kinematic or path drive with extreme finite coordinates or speed can push solver velocities to overflow, so steps get rejected or the world fails, the same stall the other drive limits were added to prevent. |  |
| F-2 | minor | not challenged | correctness |  | `Benchmarks/macOS/BubblePhysicsPerfGuard/DevicePrediction.swift:157` | sameCommit accepts any non-empty prefix match in either direction, so a truncated report commit (e.g. one hex digit) matches the current HEAD and calibrate() writes a calibration for a different commit. | A device report from another build can be accepted as calibration for the current commit, so later predictions pass or fail against the wrong baseline. |  |
| F-3 | minor | not challenged | contracts |  | `Sources/BubblePhysicsRuntime/QueryIndex.swift:47` | QueryIndex models a bubble as a circle of RuntimeObject.effectiveRadius, but the producer (publishedObjectStates comment in NativeCompleteStepper) defines effectiveRadius as the MINIMUM contour distance from the centre, so a deformed bubble's bulge lies outside the indexed circle, while ObjectState.bounds for the same bubble covers the whole contour. | A game calling objects(at:), objects(in:), objects(inCircle:) or raycast on a squeezed bubble gets false negatives over the part of the bubble that sticks out, and the answers disagree with the bubble's own published bounds. |  |
| F-4 | minor | not challenged | contracts |  | `Sources/BubblePhysicsPublic/Model/WorldConfiguration.swift:29` | New package init(uncheckedMin:max:) lets solver-produced rectangles (bubble bounds only checked min<=max, zero-size circle/capsule bounds) reach public ObjectState.bounds, while WorldRectangle is still documented (line 15) and validated by its public init as strictly positive width and height. | A game that trusts the documented WorldRectangle invariant and divides by bounds width or height can get a division by zero for a degenerate object. |  |
| F-5 | minor | not challenged | design |  | `Sources/BubblePhysicsMetalRenderBenchmark/PublicWorldStressBenchmark.swift:240` | pixelSize hard-codes the Metal texture limit 16_384.0 although BubblePhysicsAssets already exposes package AssetRegistry.maximumTextureDimension = 16384 and this module already depends on it; two copies of one limit can drift. | none |  |
| F-6 | minor | not challenged | design |  | `Benchmarks/macOS/BubblePhysicsPerfGuard/PerfGuard.swift:157` | iPhone X render size 1125x2436 is defined in PerfGuard.acceptanceRenderSize and again (with 700 region height) in BenchmarkSceneSpec.renderSize in the benchmark module; the device resolution constant has no single owner. | none |  |
| F-7 | minor | not challenged | design |  | `Benchmarks/macOS/BubblePhysicsPerfGuard/PerfGuard.swift:294` | benchmarkScene(named:) plus PerfGuard.scenes (line 151) re-encode the name to Scene mapping that Scene.name owns in the benchmark module, and the iOS PublicWorldStressView keeps a third list; adding a scene needs edits in three places. | none |  |
| F-8 | minor | not challenged | design |  | `Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalBenchmarkRunner.swift:225` | The conversion NativeMetalFrameBackend to ReferenceSimulationBackend is written inline as `== .nativeMetal ? .nativeMetal : .cpu` here and again in VisualSimulationDriver.swift:136 instead of one adapter helper in the diagnostics module (the new ReferenceSolverInputAdapter is the natural home). | none |  |
| F-9 | minor | not challenged | performance |  | `Sources/BubblePhysicsRuntime/EventCompactor.swift:21` | finish() sorts the whole contact history (history.sorted()) on every step even when removedObjects is empty; NativeCompleteStepper.removedContactObjects also scans all previousContacts with two dictionary lookups per pair each step, and NativePublicWorld.contactTransitions sorts contactHistory again: O(H log H) per step for H live contact pairs. | In a dense scene with many contact-interested pairs the main-thread step cost grows with the number of live contacts, adding avoidable frame-time during steady state. |  |
| F-10 | minor | not challenged | performance |  | `Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift:353` | contactHistory.sorted() runs every step to find ended pairs, although the loop only needs pairs absent from `current`; the sort could be limited to the (usually empty) difference set. | Extra per-step CPU sorting of all live contact pairs on the main actor in scenes with many contact-interested objects. |  |
| F-11 | minor | not challenged | performance |  | `Sources/BubblePhysicsPublic/BubbleWorld.swift:192` | pendingHitTests has no cap: each hitTest() call appends, the queue is copied into the GPU buffers (one thread per point scanning all bubbles/bodies), and resolveHitTests/cancelHitTest use firstIndex per entry, making resolution O(P^2); while paused or after rejected steps the queue only grows. | An app issuing a hitTest per touch-move event during pause or backlog sees growing memory and a step that stalls on a large GPU hit-test dispatch once resumed. |  |
| F-12 | minor | not challenged | performance |  | `Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift:562` | Hit-test points, results and counts use eventBuffer(), which calls device.makeBuffer three times per step while hit tests are pending, whereas the same diff moved sensor inputs to reusable buffers (NativeMetalReusableBuffer) to avoid per-frame allocation. | Frames with pending hit tests (for example during dragging) pay three Metal buffer allocations each, adding CPU time and memory churn. |  |
| F-13 | minor | not challenged | performance |  | `Sources/BubblePhysicsPublic/BubbleWorldRenderState.swift:64` | makeRenderState runs every frame (including interpolation-only frames at 120 Hz): sorts all object keys, regenerates each rigid body's ring via rigidRing (48 sin/cos plus allocation for circles/capsules) and the renderer then hashes the entire \[WorldPoint\] ring as the ringGeometryCache key per body per frame, although the ring depends only on the immutable shape. | Per-frame main-thread cost scales with body count times ring size, reducing frame-rate headroom in scenes with many rigid bodies. |  |
| F-14 | minor | not challenged | performance |  | `Sources/BubblePhysicsPublic/BubbleWorld.swift:339` | state.publishedObjectStates() rebuilds a dictionary of every object (with polygon bounds trig) on each published step, including each of up to 8 steps inside one advance without a command buffer, although only the last lastFrame survives. | Catch-up advances do up to 8x redundant O(N) allocation and bounds computation on the main actor. |  |
| F-15 | minor | not challenged | performance |  | `Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source:385` | In nativeRigidEmitCandidates the body-body loop runs on lane 0 only (other lanes return) over all counts.x bodies, loading two full NativeRigidBody structs per iteration, so each threadgroup does O(R) serial work and the pass is O(R^2) total with 255 idle lanes. | GPU step time grows quadratically with rigid body count, lowering frame rate in scenes with many bodies. |  |
| F-16 | minor | not challenged | performance |  | `Sources/BubblePhysicsAssets/AssetRegistry.swift:96` | register(font:characters:) runs SDFAtlasGenerator.generate synchronously on the @MainActor registry: per-glyph 4x oversampled raster plus two Felzenszwalb distance transforms with per-row/column array allocations, with no bound on the character count other than a 4096 atlas side. | Registering a font with a large character set freezes the UI thread for a noticeable time. |  |
| F-17 | minor | not challenged | performance |  | `Sources/BubblePhysicsAssets/AssetRegistry.swift:54` | register(CGImage) accepts up to 16384x16384 and allocates a zero-filled \[UInt8\] of width*height*4 (1 GiB) on the main actor before creating a second full texture copy; the dimension limit is the GPU texture limit, not a memory-safe decode limit. | Registering a very large image can get the app killed for memory or freeze the UI on lower-memory devices. |  |
| F-18 | minor | not challenged | performance |  | `Sources/BubblePhysicsRuntime/TransactionStager.swift:465` | validateJoints(attachedTo:) sorts all joints (O(J log J)) on every setMotion/replace/radius operation although it only needs the few attached to one body; removeJoints(attachedTo:) likewise scans all joints per removed object, so a transaction with N operations costs O(N*J log J). | Large transactions in scenes with many joints take longer to stage at the step boundary, adding frame-time spikes. |  |
| F-19 | minor | not challenged | testability |  | `Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift:61` | The only tests that compare scene state/pixels with the pre-optimization reference run solely when device.name == "Apple M1 Pro" (XCTSkipUnless); on any other Mac or CI they are skipped, leaving just the self-consistency test (two runs equal) which cannot detect a behaviour change. | A change that alters simulation or render output passes the test suite on any machine other than the owner's M1 Pro without any failure. |  |
| F-20 | minor | not challenged | testability |  | `Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift:87` | Same device-name gate for the reference pixel hash: the render regression guard is skipped (not failed) on every GPU except "Apple M1 Pro", and a skip reads as green. | A render regression goes unnoticed when the tests run on a different Mac or in CI. |  |
| F-21 | minor | not challenged | testability |  | `Tests/BubblePhysicsMetalRenderTests/DecalRenderTests.swift:270` | guard case .bubble ... else { throw XCTSkip("to nie bańka") } turns a wrong object kind (a real defect for the decal-on-deformed-bubble tests) into a skip instead of a failure, so the tests dependent on this helper can silently stop running. | If the bubble kind representation changes, the deformed-bubble decal tests are skipped and the decal clipping regression goes undetected. |  |
| F-23 | minor | not challenged | conventions |  | `README.md:14` | Tabela Produkty nie wymienia nowego produktu BubblePhysicsMetalRenderBenchmark dodanego w Package.swift, choć wszystkie pozostałe produkty biblioteczne są w niej opisane; wzmianka jest tylko w akapicie o benchmarku. | none |  |
| F-24 | minor | not challenged | conventions |  | `Sources/BubblePhysicsRuntime/TransactionStager.swift:525` | Nazwy maximumDriveMagnitude/requireDriveMagnitude i nagłówek doc-comment ('napędu kinematycznego') nie pasują już do użycia dla kotwic, długości, tłumienia i kąta zawiasu; dopisano tylko akapit na końcu komentarza. | none |  |
| F-25 | minor | not challenged | docs-coherence |  | `docs/migration/v1-api-diff.txt:142` | The file claims 'same HEAD gives the same file' and still lists PublicWorldStressBenchmark.measure/run as renamed inside BubblePhysicsMetalRender, but the benchmark moved to module BubblePhysicsMetalRenderBenchmark; regenerating would instead list it as removed from BubblePhysicsMetalRender. | none |  |
| F-26 | minor | not challenged | docs-coherence |  | `README.md:142` | Repository layout and product table do not list the new modules/products BubblePhysicsMetalRenderBenchmark and BubblePhysicsNativeMetalDiagnostics (nor the BubblePhysicsPerfGuard executable), although Package.swift defines them and the prose uses them; Diagnostics is not under 'ścieżka produkcyjna' nor described anywhere in the layout. | none |  |

## Refuted findings

None.

## Dimensions that produced no findings

- security
- dependencies
- tools-verify

## Coverage

| Dimension | State | Reason | Model | Findings |
|-----------|-------|--------|-------|----------|
| correctness | reviewed |  | sonnet | 2 |
| contracts | reviewed |  | sonnet | 2 |
| design | reviewed |  | sonnet | 4 |
| security | reviewed |  | sonnet | 0 |
| performance | reviewed |  | sonnet | 10 |
| testability | reviewed |  | sonnet | 3 |
| conventions | reviewed |  | sonnet | 3 |
| docs-coherence | reviewed |  | sonnet | 3 |
| dependencies | reviewed |  | sonnet | 0 |
| infra | not applicable | no .tf or .tfvars file changed | none | 0 |
| tools-verify | reviewed |  | none | 0 |

**correctness** checked:
- FixedStepDriver.swift accumulate/discardNextAdvance/backlog cap and WorldConfiguration.maximumBacklog validation
- QueryIndex.swift grid build, candidates(), raycast and containment math; WorldRectangle min<max invariant in WorldConfiguration.swift
- TransactionStager.swift joint/drive/kinematic staging, RegionPolicy.swift joint cleanup, MotionControllers.swift applyKinematicDrive and PathDrive init in Motion.swift
- BubbleWorld.swift advanceImpl publication/pause/hit-test paths, NativeCompleteStepper.swift no-GPU path and EventCompactor.swift ordering/history
- NativeJointState.swift prepare, nativeSolveJoints and nativeHitTest AABB reject in the .metal-source kernels
- AssetRegistry.swift, SDFAtlasGenerator.swift distance transform, PerfGuard.swift and DevicePrediction.swift parse/calibrate/predict
**contracts** checked:
- FixedStepDriver + WorldConfiguration.maximumBacklog -> BubbleWorld.advanceImpl (validation vs precondition, discardNextAdvance, stepLimit with commandBuffer)
- CompleteStepper.didPublish / NativeCompleteStepper.candidateHistory vs NativePublicWorld.contactHistory and forgetContactHistory (publication ordering, rejected frame paths)
- NativePublicWorld.step -> NativeMetalSolver frame arrays (bubbleEffectiveRadii/bubbleBoundsRecords index alignment with frame.bubbles, hitTestResults, joint sorting in NativeJointState.prepare, nativeSolveJoints guards)
- QueryIndex and ObjectState consumers of RuntimeObject.effectiveRadius/bounds and WorldRectangle invariant (WorldRectangle.swift, publishedObjectStates)
- BubblePhysicsMetalRender buildFrame/NativeMetalRenderHandoff (previousContoursValid, bubbleIndexByID, world.assets identity check, AssetRegistry texture/glyph lookups from stager)
- TransactionStager joints/texture/decal validation and RegionPolicy joint removal; PerfGuard/iOS bench callers of benchmark API and lifecycle pause
**design** checked:
- Package.swift target graph: new Assets, MetalRenderBenchmark, NativeMetalDiagnostics, PerfGuard targets and their dependency edges
- ReferenceSolverInputAdapter and the NativeMetal to Diagnostics split; grep for ReferenceSimulationBackend vs NativeMetalFrameBackend mappings
- PublicWorldStressBenchmark Scene/BenchmarkSceneSpec vs PerfGuard.scenes/benchmarkScene and iOS PublicWorldStressView scene list
- grep 16384/1125/2436 across Sources, Benchmarks, Tests (AssetRegistry.maximumTextureDimension precedent)
- PerfGuard.swift and DevicePrediction.swift structure (load/write helpers, median, parsing)
**security** checked:
- Signing.xcconfig/.local.example/.gitignore/project.yml/pbxproj for both iOS apps: team ID and bundle id removed, local override ignored, repo-wide grep for old team ID and personal prefix returns nothing in the tree
- PerfGuard.swift git() Process call: fixed /usr/bin/git path, constant argument arrays, no user input reaches the shell
- PerfGuard and DevicePrediction file I/O (JSONDecoder on calibration/baseline, CLI-supplied paths): local developer tool, Codable decode only, no deserialization of arbitrary types
- PackageGraphTests Process via /usr/bin/env swift dump-package: constant args, temp scratch path with UUID, timeout handled
- Package.swift diff: new targets and products are all in-repo, no new external dependencies; grep of diff for secrets/token/password/logging of credentials shows only transaction tokens
- Unsafe memory use (bindMemory on MTLBuffer contents) in NativeJointState/NativeMetalSolver/NativeRigidPolygonState and new input validation limits at transaction entry (1e6 caps)
**performance** checked:
- EventCompactor.finish, NativeCompleteStepper.removedContactObjects and NativePublicWorld.contactTransitions: per-step cost of contact history (sorted, Set scans)
- BubbleWorld hitTest queue (submit/cancel/resolve) and NativeMetalSolver hit-test buffer allocation vs sensorScratch reusable buffers
- BubbleWorld.advanceImpl/publishedObjectStates, BubbleWorldRenderState.makeRenderState and BubblePhysicsMetalRender.buildFrame/ringGeometry cache/ArenaPool per-frame work; NativeMetalRenderHandoff lazy index dictionaries
- QueryIndex build and query paths, TransactionStager joint validation (validateJoints/removeJoints), MotionControllers.prepare in-place loop
- AssetRegistry.register(CGImage/font) and SDFAtlasGenerator on MainActor; nativeRigidEmitCandidates, nativeHitTest, nativeEmitCandidates kernels; NativeJointState.prepare
**testability** checked:
- PerfGuardTests.swift (guard comparison, scaling, DevicePrediction parse/calibrate/predict): assertions pin exact values and boundaries, fail on regressions
- AcceptanceEquivalenceTests and AcceptanceRenderEquivalenceTests: reference-hash tests guarded by XCTSkipUnless on device name
- DecalRenderTests deformedBubbleScene helper: guard-case throws XCTSkip; grep of XCTSkip across Tests/ for precedent (mostly 'Metal unavailable' skips)
- grep of added test lines for XCTAssertNoThrow-only, XCTAssertTrue(true) and vacuous assertions in Tests diff
- CapacityMeasurementTests wiring tests (finite/positive p95 and CPU measurements on real scenes)
**conventions** checked:
- docs/MIGRATION-v2.md line 65 (limit 1e6) against TransactionStager.swift new requireDriveMagnitude calls for motor drive and joints
- README.md Produkty table against new BubblePhysicsMetalRenderBenchmark library product in Package.swift
- grep of PublicWorldStressBenchmark in docs/README/Benchmarks/Examples for stale module references (older benchmark reports are historical)
- nativeHitTest kernel comment vs NativePostSolveKernels bounds writes and NativeMetalSolver hit-test dispatch order
- commit trailers Change-spec-directory on last 40 commits (all present except unrelated bf7e911)
- naming of maximumDriveMagnitude/requireDriveMagnitude vs neighbours in TransactionStager.swift
**docs-coherence** checked:
- README.md whole file vs Package.swift products/targets and PublicWorldStressBenchmark gates, scene sizes, capacity levels and heights
- docs/MIGRATION-v2.md vs BubbleWorld/BubblePhysicsMetalRender/WorldConfiguration signatures and TransactionStager.maximumDriveMagnitude call sites
- docs/integration-guide.md vs WorldEvent contact cases, candidateLimitPerObject=128, hitTest and signing xcconfig examples
- docs/benchmarks/*.md and iphone-x-calibration.json vs README quoted numbers; PerfGuard options and commit header parsing
- docs/migration/v1-api-diff.txt header and rows vs the module move of PublicWorldStressBenchmark (git log of the file)
**dependencies** checked:
- Package.swift diff: new targets/products only depend on in-repo targets, no external packages, tools-version unchanged
- No Package.resolved exists and Package.swift declares no .package(url:) so no lockfile can be out of step
- project.yml (Bench and Showcase) products vs both project.pbxproj XCSwiftPackageProductDependency entries (Bench: 4, Showcase: 3) match
- grep XCRemoteSwiftPackage/XCLocalSwiftPackageReference in both xcodeprojs: only local refs to repo root
- Signing.xcconfig / .example / .gitignore: no new third-party or licence-relevant dependency
- NativeMetal dependency on Reference removed and moved to NativeMetalDiagnostics; test target deps cover imports
**tools-verify** checked:
- ran `test obrazu` in the checkout root; exit 0

## What each reviewer was given

Diff: `5d2c9a7...HEAD` (5d2c9a7c..1a7afd7a).

**correctness**:
- `/Users/adamowim/priv/ios/bubble_phisics/.gitignore`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/App/PublicWorldStressView.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj/project.pbxproj`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/Signing.local.xcconfig.example`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/Signing.xcconfig`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsPerfGuard/DevicePrediction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsPerfGuard/PerfGuard.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsPerfGuard/main.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsReferenceBench/main.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/BubbleScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/MetalHostView.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/RigidScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/ShowcaseApp.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/ShowcaseScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/project.pbxproj`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/project.xcworkspace/contents.xcworkspacedata`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/xcshareddata/xcschemes/BubblePhysicsShowcase.xcscheme`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/Signing.local.xcconfig.example`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/Signing.xcconfig`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsAssets/AssetRegistry.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsAssets/GlyphAtlas.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsAssets/SDFAtlasGenerator.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/BubblePhysicsMetalRender.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/DecalRenderer.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/MaterialPipelines.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/PublicWorldStressBenchmark.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/RenderHooks.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/RenderStylePipeline.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRenderBenchmark/PublicWorldStressBenchmark.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeJointState.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBackend.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalChainKernels.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalRenderHandoff.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeRigidPolygonState.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeRenderKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalBenchmarkRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalQualityEnvelope.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalVisualReplay.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalWorldRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/ReferenceSolverInputAdapter.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/VisualSimulationDriver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorldRenderState.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Diagnostics.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/LifecycleEventSource.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Decals.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Identifiers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Joints.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Motion.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Objects.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Queries.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Transitions.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldConfiguration.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldFrame.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsReferenceMetal/ReferenceMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/CompleteStep.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/EventCompactor.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/FixedStepDriver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/MotionControllers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/QueryIndex.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/RegionPolicy.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsAssetsTests/AssetRegistryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsAssetsTests/GlyphRegistryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceSceneTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/BodiesWithoutBubblesRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/BodyInterpolationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/BubbleInterpolationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/CapacityMeasurementTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/CollisionFilterWorldTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/ContactCandidateMarginTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/ContactEventTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/DecalRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/DecalRendererLayoutTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/DecalsSceneTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/HitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/JointWorldTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/KinematicMotionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/LayerRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialColorRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialTextureRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MetalRenderIntegrationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/ObjectStateTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/PublishedStateDeterminismTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/QueryWorldTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RenderArenaTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RenderHookTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RenderMaterialFromVertexTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RigidCCDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RigidShapeContactTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RingGeometryCacheTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/SnapRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/InterpolationHarness.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/OffscreenRenderHarness.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/PhysicsSceneBuilders.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/PublishedStateHash.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/TriangulationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/VelocityLimitTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalBenchmarkTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalBroadPhaseTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContactCacheTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContactPipelineTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContainmentParallelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalParallelCacheProfileTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalPerceptualProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalQualityEnvelopeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalRestDampingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSafetyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSolverLifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalStageDiagnosticsTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalVisualReplayTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalWorldRunnerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/ReferenceSolverInputAdapterTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/VisualSimulationDriverTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeJointStateEmptyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalChainKernelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalContactMemoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalEventCompactionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalHitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalMotionRoleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalPreviousContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalPublicObjectTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalRenderHandoffTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalResourceReuseTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalRigidPolygonTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalStructuralOperationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeSolverInputTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/RigidContactMemoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPerfGuardTests/PerfGuardTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/AssetWorldCreationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/BubbleWorldTimeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/EventInterestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/IntegrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/PackageGraphTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/RenderMaterialModelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/RigidShapeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/TransitionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/BubbleWorldCompletionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CollisionFilterTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/DecalStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/EventCompactorTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/FixedStepDriverTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/InterpolationFractionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/JointStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/KinematicDriveControllerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/KinematicStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/LifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/MotionControllersFeedbackTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/MotionControllersPrepareTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/QueryIndexTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RegionPolicyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RenderMaterialStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RigidInertiaControllerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RigidPolygonRuntimeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**contracts**:
- `/Users/adamowim/priv/ios/bubble_phisics/.gitignore`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/App/PublicWorldStressView.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj/project.pbxproj`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/Signing.local.xcconfig.example`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/Signing.xcconfig`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/project.yml`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsPerfGuard/DevicePrediction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsPerfGuard/PerfGuard.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsPerfGuard/main.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsReferenceBench/main.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/BubbleScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/MetalHostView.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/RigidScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/ShowcaseApp.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/ShowcaseScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/project.pbxproj`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/project.xcworkspace/contents.xcworkspacedata`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/xcshareddata/xcschemes/BubblePhysicsShowcase.xcscheme`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/Signing.local.xcconfig.example`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/Signing.xcconfig`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/project.yml`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsAssets/AssetRegistry.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsAssets/GlyphAtlas.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsAssets/SDFAtlasGenerator.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/BubblePhysicsMetalRender.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/DecalRenderer.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/MaterialPipelines.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/PublicWorldStressBenchmark.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/RenderHooks.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/RenderStylePipeline.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRenderBenchmark/PublicWorldStressBenchmark.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeJointState.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBackend.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalChainKernels.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalRenderHandoff.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeRigidPolygonState.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeRenderKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalBenchmarkRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalQualityEnvelope.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalVisualReplay.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalWorldRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/ReferenceSolverInputAdapter.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/VisualSimulationDriver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorldRenderState.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Diagnostics.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/LifecycleEventSource.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Decals.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Identifiers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Joints.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Motion.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Objects.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Queries.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Transitions.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldConfiguration.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldFrame.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsReferenceMetal/ReferenceMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/CompleteStep.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/EventCompactor.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/FixedStepDriver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/MotionControllers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/QueryIndex.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/RegionPolicy.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsAssetsTests/AssetRegistryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsAssetsTests/GlyphRegistryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceSceneTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/BodiesWithoutBubblesRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/BodyInterpolationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/BubbleInterpolationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/CapacityMeasurementTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/CollisionFilterWorldTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/ContactCandidateMarginTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/ContactEventTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/DecalRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/DecalRendererLayoutTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/DecalsSceneTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/HitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/JointWorldTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/KinematicMotionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/LayerRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialColorRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialTextureRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MetalRenderIntegrationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/ObjectStateTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/PublishedStateDeterminismTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/QueryWorldTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RenderArenaTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RenderHookTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RenderMaterialFromVertexTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RigidCCDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RigidShapeContactTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RingGeometryCacheTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/SnapRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/InterpolationHarness.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/OffscreenRenderHarness.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/PhysicsSceneBuilders.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/PublishedStateHash.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/TriangulationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/VelocityLimitTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalBenchmarkTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalBroadPhaseTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContactCacheTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContactPipelineTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContainmentParallelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalParallelCacheProfileTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalPerceptualProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalQualityEnvelopeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalRestDampingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSafetyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSolverLifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalStageDiagnosticsTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalVisualReplayTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalWorldRunnerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/ReferenceSolverInputAdapterTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/VisualSimulationDriverTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeJointStateEmptyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalChainKernelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalContactMemoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalEventCompactionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalHitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalMotionRoleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalPreviousContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalPublicObjectTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalRenderHandoffTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalResourceReuseTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalRigidPolygonTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalStructuralOperationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeSolverInputTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/RigidContactMemoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPerfGuardTests/PerfGuardTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/AssetWorldCreationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/BubbleWorldTimeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/EventInterestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/IntegrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/PackageGraphTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/RenderMaterialModelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/RigidShapeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/TransitionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/BubbleWorldCompletionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CollisionFilterTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/DecalStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/EventCompactorTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/FixedStepDriverTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/InterpolationFractionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/JointStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/KinematicDriveControllerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/KinematicStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/LifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/MotionControllersFeedbackTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/MotionControllersPrepareTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/QueryIndexTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RegionPolicyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RenderMaterialStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RigidInertiaControllerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RigidPolygonRuntimeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/benchmarks/iphone-x-calibration.json`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/benchmarks/perf-guard.json`

**design**:
- `/Users/adamowim/priv/ios/bubble_phisics/.gitignore`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/App/PublicWorldStressView.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj/project.pbxproj`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/Signing.local.xcconfig.example`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/Signing.xcconfig`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/project.yml`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsPerfGuard/DevicePrediction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsPerfGuard/PerfGuard.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsPerfGuard/main.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsReferenceBench/main.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/BubbleScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/MetalHostView.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/RigidScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/ShowcaseApp.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/ShowcaseScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/project.pbxproj`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/project.xcworkspace/contents.xcworkspacedata`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/xcshareddata/xcschemes/BubblePhysicsShowcase.xcscheme`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/Signing.local.xcconfig.example`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/Signing.xcconfig`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/project.yml`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsAssets/AssetRegistry.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsAssets/GlyphAtlas.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsAssets/SDFAtlasGenerator.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/BubblePhysicsMetalRender.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/DecalRenderer.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/MaterialPipelines.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/PublicWorldStressBenchmark.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/RenderHooks.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/RenderStylePipeline.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRenderBenchmark/PublicWorldStressBenchmark.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeJointState.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBackend.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalChainKernels.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalRenderHandoff.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeRigidPolygonState.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeRenderKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalBenchmarkRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalQualityEnvelope.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalVisualReplay.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalWorldRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/ReferenceSolverInputAdapter.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/VisualSimulationDriver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorldRenderState.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Diagnostics.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/LifecycleEventSource.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Decals.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Identifiers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Joints.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Motion.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Objects.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Queries.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Transitions.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldConfiguration.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldFrame.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsReferenceMetal/ReferenceMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/CompleteStep.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/EventCompactor.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/FixedStepDriver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/MotionControllers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/QueryIndex.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/RegionPolicy.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsAssetsTests/AssetRegistryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsAssetsTests/GlyphRegistryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceSceneTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/BodiesWithoutBubblesRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/BodyInterpolationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/BubbleInterpolationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/CapacityMeasurementTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/CollisionFilterWorldTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/ContactCandidateMarginTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/ContactEventTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/DecalRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/DecalRendererLayoutTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/DecalsSceneTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/HitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/JointWorldTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/KinematicMotionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/LayerRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialColorRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialTextureRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MetalRenderIntegrationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/ObjectStateTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/PublishedStateDeterminismTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/QueryWorldTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RenderArenaTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RenderHookTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RenderMaterialFromVertexTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RigidCCDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RigidShapeContactTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RingGeometryCacheTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/SnapRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/InterpolationHarness.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/OffscreenRenderHarness.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/PhysicsSceneBuilders.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/PublishedStateHash.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/TriangulationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/VelocityLimitTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalBenchmarkTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalBroadPhaseTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContactCacheTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContactPipelineTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContainmentParallelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalParallelCacheProfileTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalPerceptualProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalQualityEnvelopeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalRestDampingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSafetyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSolverLifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalStageDiagnosticsTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalVisualReplayTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalWorldRunnerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/ReferenceSolverInputAdapterTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/VisualSimulationDriverTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeJointStateEmptyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalChainKernelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalContactMemoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalEventCompactionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalHitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalMotionRoleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalPreviousContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalPublicObjectTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalRenderHandoffTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalResourceReuseTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalRigidPolygonTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalStructuralOperationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeSolverInputTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/RigidContactMemoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPerfGuardTests/PerfGuardTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/AssetWorldCreationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/BubbleWorldTimeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/EventInterestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/IntegrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/PackageGraphTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/RenderMaterialModelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/RigidShapeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/TransitionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/BubbleWorldCompletionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CollisionFilterTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/DecalStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/EventCompactorTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/FixedStepDriverTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/InterpolationFractionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/JointStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/KinematicDriveControllerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/KinematicStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/LifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/MotionControllersFeedbackTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/MotionControllersPrepareTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/QueryIndexTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RegionPolicyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RenderMaterialStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RigidInertiaControllerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RigidPolygonRuntimeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/benchmarks/iphone-x-calibration.json`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/benchmarks/perf-guard.json`

**security**:
- `/Users/adamowim/priv/ios/bubble_phisics/.gitignore`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/App/PublicWorldStressView.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj/project.pbxproj`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/Signing.local.xcconfig.example`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/Signing.xcconfig`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/project.yml`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsPerfGuard/DevicePrediction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsPerfGuard/PerfGuard.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsPerfGuard/main.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsReferenceBench/main.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/BubbleScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/MetalHostView.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/RigidScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/ShowcaseApp.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/ShowcaseScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/project.pbxproj`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/project.xcworkspace/contents.xcworkspacedata`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/xcshareddata/xcschemes/BubblePhysicsShowcase.xcscheme`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/Signing.local.xcconfig.example`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/Signing.xcconfig`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/project.yml`
- `/Users/adamowim/priv/ios/bubble_phisics/Package.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsAssets/AssetRegistry.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsAssets/GlyphAtlas.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsAssets/SDFAtlasGenerator.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/BubblePhysicsMetalRender.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/DecalRenderer.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/MaterialPipelines.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/PublicWorldStressBenchmark.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/RenderHooks.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/RenderStylePipeline.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRenderBenchmark/PublicWorldStressBenchmark.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeJointState.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBackend.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalChainKernels.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalRenderHandoff.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeRigidPolygonState.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeRenderKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalBenchmarkRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalQualityEnvelope.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalVisualReplay.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalWorldRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/ReferenceSolverInputAdapter.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/VisualSimulationDriver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorldRenderState.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Diagnostics.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/LifecycleEventSource.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Decals.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Identifiers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Joints.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Motion.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Objects.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Queries.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Transitions.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldConfiguration.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldFrame.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsReferenceMetal/ReferenceMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/CompleteStep.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/EventCompactor.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/FixedStepDriver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/MotionControllers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/QueryIndex.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/RegionPolicy.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsAssetsTests/AssetRegistryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsAssetsTests/GlyphRegistryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceSceneTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/BodiesWithoutBubblesRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/BodyInterpolationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/BubbleInterpolationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/CapacityMeasurementTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/CollisionFilterWorldTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/ContactCandidateMarginTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/ContactEventTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/DecalRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/DecalRendererLayoutTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/DecalsSceneTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/HitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/JointWorldTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/KinematicMotionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/LayerRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialColorRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialTextureRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MetalRenderIntegrationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/ObjectStateTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/PublishedStateDeterminismTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/QueryWorldTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RenderArenaTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RenderHookTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RenderMaterialFromVertexTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RigidCCDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RigidShapeContactTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RingGeometryCacheTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/SnapRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/InterpolationHarness.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/OffscreenRenderHarness.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/PhysicsSceneBuilders.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/PublishedStateHash.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/TriangulationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/VelocityLimitTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalBenchmarkTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalBroadPhaseTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContactCacheTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContactPipelineTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContainmentParallelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalParallelCacheProfileTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalPerceptualProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalQualityEnvelopeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalRestDampingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSafetyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSolverLifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalStageDiagnosticsTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalVisualReplayTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalWorldRunnerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/ReferenceSolverInputAdapterTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/VisualSimulationDriverTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeJointStateEmptyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalChainKernelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalContactMemoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalEventCompactionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalHitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalMotionRoleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalPreviousContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalPublicObjectTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalRenderHandoffTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalResourceReuseTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalRigidPolygonTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalStructuralOperationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeSolverInputTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/RigidContactMemoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPerfGuardTests/PerfGuardTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/AssetWorldCreationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/BubbleWorldTimeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/EventInterestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/IntegrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/PackageGraphTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/RenderMaterialModelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/RigidShapeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/TransitionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/BubbleWorldCompletionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CollisionFilterTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/DecalStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/EventCompactorTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/FixedStepDriverTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/InterpolationFractionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/JointStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/KinematicDriveControllerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/KinematicStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/LifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/MotionControllersFeedbackTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/MotionControllersPrepareTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/QueryIndexTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RegionPolicyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RenderMaterialStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RigidInertiaControllerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RigidPolygonRuntimeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/benchmarks/iphone-x-calibration.json`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/benchmarks/perf-guard.json`

**performance**:
- `/Users/adamowim/priv/ios/bubble_phisics/.gitignore`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/App/PublicWorldStressView.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj/project.pbxproj`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/Signing.local.xcconfig.example`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/Signing.xcconfig`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsPerfGuard/DevicePrediction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsPerfGuard/PerfGuard.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsPerfGuard/main.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsReferenceBench/main.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/BubbleScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/MetalHostView.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/RigidScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/ShowcaseApp.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/ShowcaseScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/project.pbxproj`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/project.xcworkspace/contents.xcworkspacedata`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/xcshareddata/xcschemes/BubblePhysicsShowcase.xcscheme`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/Signing.local.xcconfig.example`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/Signing.xcconfig`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsAssets/AssetRegistry.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsAssets/GlyphAtlas.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsAssets/SDFAtlasGenerator.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/BubblePhysicsMetalRender.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/DecalRenderer.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/MaterialPipelines.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/PublicWorldStressBenchmark.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/RenderHooks.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/RenderStylePipeline.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRenderBenchmark/PublicWorldStressBenchmark.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeJointState.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBackend.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalChainKernels.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalRenderHandoff.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeRigidPolygonState.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeRenderKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalBenchmarkRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalQualityEnvelope.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalVisualReplay.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalWorldRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/ReferenceSolverInputAdapter.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/VisualSimulationDriver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorldRenderState.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Diagnostics.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/LifecycleEventSource.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Decals.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Identifiers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Joints.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Motion.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Objects.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Queries.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Transitions.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldConfiguration.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldFrame.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsReferenceMetal/ReferenceMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/CompleteStep.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/EventCompactor.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/FixedStepDriver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/MotionControllers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/QueryIndex.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/RegionPolicy.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsAssetsTests/AssetRegistryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsAssetsTests/GlyphRegistryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceSceneTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/BodiesWithoutBubblesRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/BodyInterpolationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/BubbleInterpolationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/CapacityMeasurementTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/CollisionFilterWorldTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/ContactCandidateMarginTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/ContactEventTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/DecalRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/DecalRendererLayoutTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/DecalsSceneTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/HitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/JointWorldTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/KinematicMotionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/LayerRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialColorRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialTextureRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MetalRenderIntegrationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/ObjectStateTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/PublishedStateDeterminismTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/QueryWorldTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RenderArenaTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RenderHookTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RenderMaterialFromVertexTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RigidCCDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RigidShapeContactTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RingGeometryCacheTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/SnapRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/InterpolationHarness.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/OffscreenRenderHarness.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/PhysicsSceneBuilders.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/PublishedStateHash.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/TriangulationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/VelocityLimitTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalBenchmarkTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalBroadPhaseTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContactCacheTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContactPipelineTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContainmentParallelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalParallelCacheProfileTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalPerceptualProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalQualityEnvelopeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalRestDampingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSafetyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSolverLifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalStageDiagnosticsTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalVisualReplayTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalWorldRunnerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/ReferenceSolverInputAdapterTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/VisualSimulationDriverTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeJointStateEmptyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalChainKernelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalContactMemoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalEventCompactionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalHitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalMotionRoleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalPreviousContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalPublicObjectTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalRenderHandoffTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalResourceReuseTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalRigidPolygonTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalStructuralOperationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeSolverInputTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/RigidContactMemoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPerfGuardTests/PerfGuardTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/AssetWorldCreationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/BubbleWorldTimeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/EventInterestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/IntegrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/PackageGraphTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/RenderMaterialModelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/RigidShapeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/TransitionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/BubbleWorldCompletionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CollisionFilterTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/DecalStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/EventCompactorTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/FixedStepDriverTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/InterpolationFractionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/JointStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/KinematicDriveControllerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/KinematicStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/LifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/MotionControllersFeedbackTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/MotionControllersPrepareTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/QueryIndexTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RegionPolicyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RenderMaterialStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RigidInertiaControllerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RigidPolygonRuntimeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**testability**:
- `/Users/adamowim/priv/ios/bubble_phisics/.gitignore`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/App/PublicWorldStressView.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj/project.pbxproj`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/Signing.local.xcconfig.example`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/Signing.xcconfig`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsPerfGuard/DevicePrediction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsPerfGuard/PerfGuard.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsPerfGuard/main.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsReferenceBench/main.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/BubbleScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/MetalHostView.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/RigidScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/ShowcaseApp.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/ShowcaseScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/project.pbxproj`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/project.xcworkspace/contents.xcworkspacedata`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/xcshareddata/xcschemes/BubblePhysicsShowcase.xcscheme`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/Signing.local.xcconfig.example`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/Signing.xcconfig`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsAssets/AssetRegistry.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsAssets/GlyphAtlas.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsAssets/SDFAtlasGenerator.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/BubblePhysicsMetalRender.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/DecalRenderer.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/MaterialPipelines.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/PublicWorldStressBenchmark.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/RenderHooks.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/RenderStylePipeline.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRenderBenchmark/PublicWorldStressBenchmark.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeJointState.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBackend.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalChainKernels.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalRenderHandoff.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeRigidPolygonState.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeRenderKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalBenchmarkRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalQualityEnvelope.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalVisualReplay.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalWorldRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/ReferenceSolverInputAdapter.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/VisualSimulationDriver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorldRenderState.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Diagnostics.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/LifecycleEventSource.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Decals.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Identifiers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Joints.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Motion.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Objects.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Queries.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Transitions.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldConfiguration.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldFrame.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsReferenceMetal/ReferenceMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/CompleteStep.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/EventCompactor.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/FixedStepDriver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/MotionControllers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/QueryIndex.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/RegionPolicy.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsAssetsTests/AssetRegistryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsAssetsTests/GlyphRegistryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceSceneTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/BodiesWithoutBubblesRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/BodyInterpolationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/BubbleInterpolationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/CapacityMeasurementTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/CollisionFilterWorldTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/ContactCandidateMarginTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/ContactEventTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/DecalRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/DecalRendererLayoutTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/DecalsSceneTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/HitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/JointWorldTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/KinematicMotionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/LayerRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialColorRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialTextureRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MetalRenderIntegrationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/ObjectStateTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/PublishedStateDeterminismTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/QueryWorldTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RenderArenaTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RenderHookTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RenderMaterialFromVertexTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RigidCCDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RigidShapeContactTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RingGeometryCacheTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/SnapRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/InterpolationHarness.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/OffscreenRenderHarness.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/PhysicsSceneBuilders.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/PublishedStateHash.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/TriangulationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/VelocityLimitTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalBenchmarkTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalBroadPhaseTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContactCacheTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContactPipelineTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContainmentParallelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalParallelCacheProfileTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalPerceptualProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalQualityEnvelopeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalRestDampingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSafetyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSolverLifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalStageDiagnosticsTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalVisualReplayTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalWorldRunnerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/ReferenceSolverInputAdapterTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/VisualSimulationDriverTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeJointStateEmptyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalChainKernelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalContactMemoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalEventCompactionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalHitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalMotionRoleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalPreviousContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalPublicObjectTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalRenderHandoffTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalResourceReuseTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalRigidPolygonTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalStructuralOperationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeSolverInputTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/RigidContactMemoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPerfGuardTests/PerfGuardTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/AssetWorldCreationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/BubbleWorldTimeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/EventInterestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/IntegrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/PackageGraphTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/RenderMaterialModelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/RigidShapeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/TransitionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/BubbleWorldCompletionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CollisionFilterTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/DecalStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/EventCompactorTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/FixedStepDriverTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/InterpolationFractionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/JointStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/KinematicDriveControllerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/KinematicStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/LifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/MotionControllersFeedbackTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/MotionControllersPrepareTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/QueryIndexTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RegionPolicyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RenderMaterialStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RigidInertiaControllerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RigidPolygonRuntimeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`

**conventions**:
- `/Users/adamowim/priv/ios/bubble_phisics/.gitignore`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/App/PublicWorldStressView.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj/project.pbxproj`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/Signing.local.xcconfig.example`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/Signing.xcconfig`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/project.yml`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsPerfGuard/DevicePrediction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsPerfGuard/PerfGuard.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsPerfGuard/main.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/macOS/BubblePhysicsReferenceBench/main.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/BubbleScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/MetalHostView.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/RigidScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/ShowcaseApp.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/App/ShowcaseScene.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/project.pbxproj`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/project.xcworkspace/contents.xcworkspacedata`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/xcshareddata/xcschemes/BubblePhysicsShowcase.xcscheme`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/Signing.local.xcconfig.example`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/Signing.xcconfig`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/project.yml`
- `/Users/adamowim/priv/ios/bubble_phisics/Package.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/README.md`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsAssets/AssetRegistry.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsAssets/GlyphAtlas.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsAssets/SDFAtlasGenerator.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/BubblePhysicsMetalRender.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/DecalRenderer.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/MaterialPipelines.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/PublicWorldStressBenchmark.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/RenderHooks.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRender/RenderStylePipeline.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsMetalRenderBenchmark/PublicWorldStressBenchmark.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeJointState.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBackend.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalBufferLayout.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalChainKernels.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalRenderHandoff.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativePublicWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeRigidPolygonState.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/NativeSolverInput.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeRenderKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalBenchmarkRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalQualityEnvelope.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalVisualReplay.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/NativeMetalWorldRunner.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/ReferenceSolverInputAdapter.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetalDiagnostics/VisualSimulationDriver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorld.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/BubbleWorldRenderState.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Diagnostics.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/LifecycleEventSource.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Decals.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Identifiers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Joints.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Motion.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Objects.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Queries.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Resources.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/Transitions.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldConfiguration.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldFrame.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsPublic/Model/WorldTransaction.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsReferenceMetal/ReferenceMetalSolver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/CompleteStep.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/EventCompactor.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/FixedStepDriver.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/MotionControllers.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/NativeCompleteStepper.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/QueryIndex.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/RegionPolicy.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsRuntime/TransactionStager.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsAssetsTests/AssetRegistryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsAssetsTests/GlyphRegistryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceRenderEquivalenceTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/AcceptanceSceneTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/BodiesWithoutBubblesRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/BodyInterpolationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/BubbleInterpolationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/CapacityMeasurementTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/CollisionFilterWorldTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/ContactCandidateMarginTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/ContactEventTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/DecalRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/DecalRendererLayoutTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/DecalsSceneTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/HitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/JointWorldTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/KinematicMotionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/LayerRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialColorRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MaterialTextureRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/MetalRenderIntegrationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/ObjectStateTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/PublishedStateDeterminismTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/QueryWorldTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RenderArenaTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RenderHookTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RenderMaterialFromVertexTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RigidCCDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RigidShapeContactTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/RingGeometryCacheTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/SnapRenderTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/InterpolationHarness.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/OffscreenRenderHarness.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/PhysicsSceneBuilders.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/Support/PublishedStateHash.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/TriangulationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsMetalRenderTests/VelocityLimitTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalBenchmarkTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalBroadPhaseTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContactCacheTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContactPipelineTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContainmentParallelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalParallelCacheProfileTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalPerceptualProbeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalQualityEnvelopeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalRestDampingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSafetyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalSolverLifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalStageDiagnosticsTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalVisualReplayTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalWorldRunnerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/NativeMetalXPBDTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/ReferenceSolverInputAdapterTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalDiagnosticsTests/VisualSimulationDriverTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeJointStateEmptyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalChainKernelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalContactMemoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalEventCompactionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalHitTestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalMotionRoleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalPreviousContourTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalPublicObjectTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalRenderHandoffTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalResourceReuseTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalRigidPolygonTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalShaderABITests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeMetalStructuralOperationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/NativeSolverInputTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsNativeMetalTests/RigidContactMemoryTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPerfGuardTests/PerfGuardTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/AssetWorldCreationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/BubbleWorldTimeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/EventInterestTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/IntegrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MigrationGuideTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/ModelValidationTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/MotionCommandTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/PackageGraphTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/RenderMaterialModelTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/RigidShapeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsPublicTests/TransitionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/BubbleWorldCompletionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/CollisionFilterTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/DecalStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/EventCompactorTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/FixedStepDriverTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/InterpolationFractionTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/JointStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/KinematicDriveControllerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/KinematicStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/LifecycleTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/MotionControllersFeedbackTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/MotionControllersPrepareTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/QueryIndexTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RegionPolicyTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RenderMaterialStagingTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RigidInertiaControllerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/RigidPolygonRuntimeTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Tests/BubblePhysicsRuntimeTests/TransactionStagerTests.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/MIGRATION-v2.md`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/benchmarks/iphone-x-calibration.json`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/benchmarks/iphone-x-radial-prototype.md`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/benchmarks/perf-guard.json`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/benchmarks/v2-iphone-x-2026-11-10-retest.md`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/benchmarks/v2-iphone-x-2026-11-10.md`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/benchmarks/v2-iphone-x-calibration.md`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/benchmarks/v2-iphone-x-capacity.md`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/benchmarks/v2-iphone-x-checkpoint-8.md`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/benchmarks/v2-iphone-x-checkpoint-9.md`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/integration-guide.md`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/migration/v1-api-diff.txt`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/superpowers/plans/2026-10-01-massless-surface-sensors.md`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/superpowers/plans/2026-10-01-multi-bubble-radial-world.md`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/superpowers/plans/2026-10-03-clean-bubble-physics-core.md`

**docs-coherence**:
- `/Users/adamowim/priv/ios/bubble_phisics/.gitignore`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj/project.pbxproj`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/Signing.local.xcconfig.example`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/Signing.xcconfig`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/project.pbxproj`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/project.xcworkspace/contents.xcworkspacedata`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/xcshareddata/xcschemes/BubblePhysicsShowcase.xcscheme`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/Signing.local.xcconfig.example`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/Signing.xcconfig`
- `/Users/adamowim/priv/ios/bubble_phisics/README.md`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeRenderKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/MIGRATION-v2.md`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/benchmarks/iphone-x-radial-prototype.md`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/benchmarks/v2-iphone-x-2026-11-10-retest.md`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/benchmarks/v2-iphone-x-2026-11-10.md`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/benchmarks/v2-iphone-x-calibration.md`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/benchmarks/v2-iphone-x-capacity.md`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/benchmarks/v2-iphone-x-checkpoint-8.md`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/benchmarks/v2-iphone-x-checkpoint-9.md`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/integration-guide.md`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/migration/v1-api-diff.txt`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/superpowers/plans/2026-10-01-massless-surface-sensors.md`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/superpowers/plans/2026-10-01-multi-bubble-radial-world.md`
- `/Users/adamowim/priv/ios/bubble_phisics/docs/superpowers/plans/2026-10-03-clean-bubble-physics-core.md`

**dependencies**:
- `/Users/adamowim/priv/ios/bubble_phisics/.gitignore`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj/project.pbxproj`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/Signing.local.xcconfig.example`
- `/Users/adamowim/priv/ios/bubble_phisics/Benchmarks/iOS/BubblePhysicsBench/Signing.xcconfig`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/project.pbxproj`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/project.xcworkspace/contents.xcworkspacedata`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/xcshareddata/xcschemes/BubblePhysicsShowcase.xcscheme`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/Signing.local.xcconfig.example`
- `/Users/adamowim/priv/ios/bubble_phisics/Examples/BubblePhysicsShowcase/Signing.xcconfig`
- `/Users/adamowim/priv/ios/bubble_phisics/Package.swift`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeRenderKernels.metal-source`
- `/Users/adamowim/priv/ios/bubble_phisics/Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`

Withheld (under `docs/sdlc/changes/2026-11-08-engine-foundations/`):
- `docs/sdlc/changes/2026-11-08-engine-foundations/change-design.md`
- `docs/sdlc/changes/2026-11-08-engine-foundations/plan.md`

Sent to every dimension (matched no routing rule):
- `.gitignore`
- `Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj/project.pbxproj`
- `Benchmarks/iOS/BubblePhysicsBench/Signing.local.xcconfig.example`
- `Benchmarks/iOS/BubblePhysicsBench/Signing.xcconfig`
- `Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/project.pbxproj`
- `Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/project.xcworkspace/contents.xcworkspacedata`
- `Examples/BubblePhysicsShowcase/BubblePhysicsShowcase.xcodeproj/xcshareddata/xcschemes/BubblePhysicsShowcase.xcscheme`
- `Examples/BubblePhysicsShowcase/Signing.local.xcconfig.example`
- `Examples/BubblePhysicsShowcase/Signing.xcconfig`
- `Sources/BubblePhysicsNativeMetal/Shaders/NativeGeometryKernels.metal-source`
- `Sources/BubblePhysicsNativeMetal/Shaders/NativePostSolveKernels.metal-source`
- `Sources/BubblePhysicsNativeMetal/Shaders/NativeRenderKernels.metal-source`
- `Sources/BubblePhysicsNativeMetal/Shaders/NativeXPBDKernels.metal-source`

## Fixes

### Round 1

- `a9629447` fix: krok bez GPU czyści historię kontaktów NativePublicWorld
- `2423a691` fix: limit 1e6 dla wartości więzów i napędu silnikowego przy wejściu transakcji
- `883eb625` perf: nativeHitTest odrzuca bańki po AABB konturu przed skanem punktów
- `34179920` refactor: harness benchmarku publicznego świata w osobnym module BubblePhysicsMetalRenderBenchmark

# Fix report — review-1, round 1

#### Covering tests

1. Stale `NativePublicWorld.contactHistory` after a step with no GPU work (commit a962944)
   - `Tests/BubblePhysicsMetalRenderTests/ContactEventTests.swift` — `testReAddedPairAfterRemovingEveryMassiveBodyGetsBeganAgain`. Before the fix it failed with `contactBegan` 0 != 1 and `contactEnded` 0 != 1.
2. Benchmark harness inside the `BubblePhysicsMetalRender` product (commit 3417992)
   - `Tests/BubblePhysicsPublicTests/PackageGraphTests.swift` — `testStressBenchmarkHarnessLivesOutsideProductionModules`. Before the fix it failed because the `BubblePhysicsMetalRenderBenchmark` module did not exist and the harness was in a production module.
   - Existing benchmark tests now import `BubblePhysicsMetalRenderBenchmark` and still pass: `Tests/BubblePhysicsMetalRenderTests/{AcceptanceEquivalenceTests, AcceptanceRenderEquivalenceTests, AcceptanceSceneTests, CapacityMeasurementTests, ContactCandidateMarginTests, DecalsSceneTests, MetalRenderIntegrationTests, ObjectStateTests, PublishedStateDeterminismTests}.swift` and `Tests/BubblePhysicsPerfGuardTests/PerfGuardTests.swift`.
   - The iOS host app was built with `xcodebuild -scheme BubblePhysicsBench -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`, which ended in `** BUILD SUCCEEDED **`.
   - README.md and docs/MIGRATION-v2.md now name the new module. `docs/migration/v1-api-diff.txt` (the swift-api-digester output) was not regenerated.
3. Joint and motor values that are finite but huge (commit 2423a69)
   - `Tests/BubblePhysicsRuntimeTests/JointStagingTests.swift` — `testHugeFiniteJointValuesAreRejectedAtStaging` (anchorA, anchorB, referenceAngle, length, softness, damping at 3e38; 1e6 is still accepted). Before the fix: 6 × "did not throw".
   - `Tests/BubblePhysicsRuntimeTests/KinematicStagingTests.swift` — `testHugeFiniteMotorDriveIsRejectedAtStaging` (force.x, force.y, torque at 3e38; 1e6 is still accepted). Before the fix: 3 × "did not throw".
4. `nativeHitTest` scanned every bubble contour with no AABB reject (commit 883eb62)
   - `Tests/BubblePhysicsNativeMetalTests/NativeMetalChainKernelTests.swift` — `testHitTestRejectsBubbleOutsideItsContourBoundsBeforeScanningTheContour`. It dispatches the kernel directly; a bubble whose contour contains the point but whose bounds do not must lose. Before the fix it failed with 9 != 7. Existing hit-test suites (`NativeMetalHitTestTests`, `HitTestTests`, `QueryWorldTests`) still pass.

#### Command

`swift test` (the recorded verify string `test obrazu` is not a runnable shell command)

#### Output

```
Building for debugging...
[0/6] Write swift-version--58304C5D6DBC2206.txt
Build complete! (0.17s)
exit=0
...
Test Suite 'All tests' passed at 2026-11-11 22:50:46.464.
	 Executed 1311 tests, with 1 test skipped and 0 failures (0 unexpected) in 459.663 (459.782) seconds
◇ Test run started.
↳ Testing Library Version: 1902
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
```

### Round 2

- `1a7afd7a` fix: limit 1e6 dla zakresu i docelowej prędkości zawiasu przy wejściu transakcji

# Fix report — review-1 round 2

Commit: `1a7afd7` fix: limit 1e6 dla zakresu i docelowej prędkości zawiasu przy wejściu transakcji

Note: the finding's torque-only sub-claim (`HingeMotor.maximumTorque` huge) did not reproduce, as the finding itself records. No bound was added for it; only `hinge.lower`, `hinge.upper` and `hinge.motor.targetAngularVelocity` are now bounded to 1e6 in `TransactionStager.add(_ joint:)`.

#### Covering tests

- `Tests/BubblePhysicsRuntimeTests/JointStagingTests.swift`
  - `testHugeFiniteHingeLimitsAndMotorTargetAreRejectedAtStaging` — covers HingeLimits lower=-3e38 and lower/upper=1e30 (`hinge.lower`), upper=3e38 (`hinge.upper`), HingeMotor targetAngularVelocity=3e38 (`hinge.motor.targetAngularVelocity`). Each is rejected with `.invalidValue(.valueOutOfRange(name))` at staging; the 1e6 boundary stays accepted. Before the fix it failed with 4 errors ("XCTAssertThrowsError failed: did not throw an error").

#### Command

```
swift test
```

(The recorded verify command `test obrazu` is not a runnable shell command, so the repository's `swift test` was used.)

#### Output

```
Test Case '-[BubblePhysicsRuntimeTests.JointStagingTests testHugeFiniteHingeLimitsAndMotorTargetAreRejectedAtStaging]' started.
Test Case '-[BubblePhysicsRuntimeTests.JointStagingTests testHugeFiniteHingeLimitsAndMotorTargetAreRejectedAtStaging]' passed (0.000 seconds).
Test Suite 'JointStagingTests' passed at 2026-11-11 23:10:00.405.
...
Test Case '-[BubblePhysicsReferenceTests.ReferenceBenchmarkTests testPrintLocalBaselineWhenRequested]' skipped (0.001 seconds).
...
Test Suite 'All tests' passed at 2026-11-11 23:14:14.643.
	 Executed 1312 tests, with 1 test skipped and 0 failures (0 unexpected) in 457.274 (457.392) seconds
visual_replay iterations=16 density=24 center_p95=0.7538074039233228 contour_p95=0.026110555045306683 cpu_contour_step_max=0.4410352110862732 gpu_contour_step_max=0.1774665117263794 contact_count_difference_mean=9.5
◇ Test run started.
↳ Testing Library Version: 1902
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
exit=0
```

## Gaps

- Withheld from every read set: `docs/sdlc/changes/2026-11-08-engine-foundations/change-design.md`, `docs/sdlc/changes/2026-11-08-engine-foundations/plan.md` — they are part of the change, so they remain visible in the diff every reviewer reads.
