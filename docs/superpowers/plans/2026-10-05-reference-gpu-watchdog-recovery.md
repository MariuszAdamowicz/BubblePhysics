# Reference GPU Watchdog Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Usunąć niekwalifikowalny monolityczny przebieg GPU, diagnozować błędy command bufferów i wykonać równoległy krok referencyjnego świata bez naruszenia atomowości klatki.

**Architecture:** Najpierw runner otrzyma trwały latch błędu GPU oraz szczegółową telemetrię command bufferów. Następnie istniejące operatory i PCG będą sterować etapami scratch GPU zamiast seryjnego `referenceAdvanceWorld`; publikacja świata pozostanie pojedyncza po walidacji finalnego readbacku. Benchmark rozdzieli ukończone klatki Metal od fallbacków.

**Tech Stack:** Swift 6, Metal iOS 16.0 / MSL 2.4, Swift Package Manager, XCTest, Xcode 26.6.

**Spec:** `docs/superpowers/specs/2026-10-05-reference-gpu-watchdog-recovery-design.md`

## Global Constraints

- iOS 16.0 jest dolnym progiem runtime GPU; macOS pozostaje tylko wewnętrznym hostem testowym.
- Nie zmieniaj limitów Newtona/PCG, parametrów fizyki, scen ani legacy `BubblePhysicsMetal`.
- Każdy error/hang GPU wykonuje fallback całej klatki od wejściowego snapshotu; częściowy stan nigdy nie jest publikowany.
- Każdy fallback w warmup lub pomiarze pozostawia `gpu_measurement=ineligible`.
- Zachowaj stable IDs, last-writer collision, prefiks event groups, CCD, containment i non-finite CPU.
- Nie wytwarzaj ani nie zapisuj wyników urządzeniowych bez rzeczywistego raportu iPhone’a.

## Review Focus

- Hang po ukończonej klatce Metal: Task 1 — latch odcina kolejne submissiony, ale nie zmienia poprzedniego opublikowanego świata.
- Błąd encodera bez NSError: Task 1 — telemetryczny fallback zawiera etap, krok i bezpieczny tekst błędu.
- Błąd środkowego etapu: Task 2 — finalny `ReferenceWorld` pozostaje bitowo stanem CPU fallbacku, bez scratch leak.
- Kolizja kluczy poza prefiksem grup: Task 2 — test świata zachowuje ostatniego kandydata CPU.
- Raport mieszający CPU i Metal: Task 3 — fallback dyskwalifikuje GPU, a czas ukończonego Metal nie obejmuje CPU fallbacku.

---

### Task 1: Telemetria błędów GPU i latch sesji

**Files:**
- Modify: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalWorldRunner.swift`
- Modify: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalSolver.swift`
- Modify: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalBackend.swift`
- Create: `Tests/BubblePhysicsReferenceMetalTests/ReferenceMetalWatchdogTests.swift`

**Interfaces:** Produces `ReferenceMetalGPUFailure` (stage, scenarioStep, reason, command-buffer error code) and runner state that rejects later Metal attempts after fatal GPU failure.

- [ ] Write failing tests where an injected executor returns a hang-like error: current world retries once on CPU, later frames use CPU without calling executor, and telemetry records the initial failure.
- [ ] Run `swift test --filter ReferenceMetalWatchdogTests`; expect RED.
- [ ] Add labelled command buffer/encoder stages and map completed Metal errors, including encoder execution status when supplied, to `ReferenceMetalGPUFailure`.
- [ ] Add a session-scoped fatal latch for hang, timeout, access-revoked and submissions-ignored errors; preserve ordinary per-frame fallback for nonfatal failures.
- [ ] Run `swift test --filter ReferenceMetalWatchdogTests && swift test`; expect pass.
- [ ] Commit: `git add Sources/BubblePhysicsReferenceMetal Tests/BubblePhysicsReferenceMetalTests && git commit -m "feat: diagnose and latch reference GPU failures"`.

### Task 2: Etapowy równoległy world solve

**Files:**
- Modify: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalSolver.swift`
- Modify: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalBufferLayout.swift`
- Modify: `Sources/BubblePhysicsReferenceMetal/Shaders/ReferencePostSolveKernels.metal-source`
- Modify: `Sources/BubblePhysicsReferenceMetal/Shaders/ReferenceNewtonPCGKernels.metal-source`
- Modify: `Sources/BubblePhysicsReferenceMetal/Shaders/ReferenceGeometryKernels.metal-source`
- Create: `Tests/BubblePhysicsReferenceMetalTests/ReferenceMetalStagedWorldTests.swift`

**Interfaces:** Consumes Task 1 stage labels/failure contract. Produces a staged `executeFrame(snapshot:scenarioStep:)` that keeps private GPU scratch until one final validated output.

- [ ] Write failing comparisons for `interactive-24` short run against CPU quality tolerance, an injected failure after geometry with whole-frame CPU result, and the known stable-key collision outside `maximumEventGroups` prefix.
- [ ] Run `swift test --filter ReferenceMetalStagedWorldTests`; expect RED.
- [ ] Encode geometry/CCD into scratch, then dispatch existing residual/Jacobian/inverse-diagonal/PCG operators with fixed configured bounds; retain Newton and line-search state in GPU buffers.
- [ ] Split post-solve, guards, contours and render preparation into bounded follow-on encoders/command buffers, with no Swift readback between solver iterations.
- [ ] Keep final buffers unpublished until all stages complete and `ReferenceMetalWorldRunner.validate` succeeds; propagate stage failures to Task 1 error contract.
- [ ] Run `swift test --filter ReferenceMetalStagedWorldTests && swift test`; expect pass.
- [ ] Commit: `git add Sources/BubblePhysicsReferenceMetal Tests/BubblePhysicsReferenceMetalTests && git commit -m "feat: stage reference Metal world solve"`.

### Task 3: Kwalifikowalny benchmark i bramka iPhone

**Files:**
- Modify: `Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkReport.swift`
- Modify: `Sources/BubblePhysicsReference/Benchmark/ReferenceBenchmarkRunner.swift`
- Modify: `Sources/BubblePhysicsReferenceMetal/ReferenceMetalBenchmarkRunner.swift`
- Modify: `Benchmarks/iOS/BubblePhysicsBench/App/ReferenceBenchmarkView.swift`
- Modify: `Tests/BubblePhysicsReferenceMetalTests/ReferenceMetalBenchmarkTests.swift`
- Create: `docs/benchmarks/reference-gpu-iphone-2026-10-05.txt` (only after actual data)
- Create: `docs/benchmarks/reference-gpu-2026-10-05.md` (only after actual data)

**Interfaces:** Consumes Task 1 failure telemetry and Task 2 completed-stage timing. Produces explicit completed-Metal timing and a device acceptance report.

- [ ] Write failing report tests proving fatal-latched CPU frames are counted as fallbacks, GPU timing contains only completed Metal command buffers, and eligibility remains false.
- [ ] Run `swift test --filter ReferenceMetalBenchmarkTests`; expect RED.
- [ ] Extend plaintext/UI reporting with stage/fatal-failure summary while preserving CPU columns and existing GPU fallback rules.
- [ ] Run full `swift test`, unsigned iOS Release build, and `git diff --check`; expect pass.
- [ ] On actual iPhone X Release, run one `interactive-24` / limit 4 smoke. Continue to both `4/8/12/16` matrices only if smoke has zero fallback/hang; save unmodified copied reports and analysis.
- [ ] Accept only `stress-300 p95 <= 10 ms`, no fallback and no quality regression; otherwise document exact gap for CEO without changing limits.
- [ ] Commit code and genuine documentation separately: `git add Sources Benchmarks Tests README.md docs/benchmarks && git commit -m "feat: report reference GPU watchdog recovery"`.

## Self-Review

- Spec coverage: Tasks 1–3 cover diagnostics/latch, staged parallel work with atomic publication, and truthful device acceptance.
- Type consistency: Task 1 owns `ReferenceMetalGPUFailure`; Tasks 2–3 consume it without introducing a CPU-to-Metal dependency.
- Review focus: each listed failure mode is pinned to its owning task.
- Scope: no task changes a physical parameter, dynamic limit, legacy backend or macOS runtime support.
