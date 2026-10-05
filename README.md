# BubblePhysics

`BubblePhysics` is a Swift package for experiments with deformable 2D bubbles. The original point/spring CPU and Metal implementations remain in the repository as experimental history; they are not the current correctness model.

## Reference solver

`BubblePhysicsReference` is the correctness-oriented CPU implementation of the new contact-envelope model. A bubble has one massive centre, an expected radius and directional indentations produced by persistent contacts. Broad phase, CCD and equilibrium use centres and directional support radii; the adaptive visual contour is generated only after a solved step.

The deterministic benchmark runner supports named geometry cases plus filled boards of 40, 300 and 1000 bubbles. For example:

```swift
let report = try ReferenceBenchmarkRunner.measure(
    scenario: .filled(count: 300, broadPhase: .sweepAndPrune),
    warmupSteps: 30,
    measuredSteps: 300
)
```

`ReferenceBenchmarkReport` contains p50/p95 for the complete step and its prediction, broad-phase, contact and solver phases, together with candidate/contact/TOI counts, maximum penetration, iteration-limit events, side corrections and non-finite-state detection. Use `.aabbTree` with the same seed to compare spatial indices on identical input. CPU timings are a diagnostic correctness baseline, not the iPhone acceptance threshold.

Nowy `BubblePhysicsReferenceMetal` implementuje referencyjny backend GPU na iOS 16+. CPU pozostaje domyślnym backendem, wyrocznią jakości i fallbackiem całej klatki. Testy pipeline'ów na macOS służą wyłącznie diagnostyce; publiczny wybór Metal poza iOS raportuje `unsupportedRuntime` i wykonuje CPU.

## Benchmark scenario

The legacy `BenchmarkScenario.iPhoneX` creates a deterministic board of 300 bubbles for the 375 × 812 point iPhone X canvas. The number of boundary points is derived only from `WorldConfiguration.maxBoundarySegmentLength`; the package does not impose a maximum node count.

Use `MetalBenchmarkReport.measure(scenario: .iPhoneX, steps: 300)` in an iOS host to collect GPU step-time p50/p95 and separate shape, contact and interaction timings. The report also includes particle, candidate-pair and contact counts plus overflow and non-finite-state flags. `BenchmarkReport` remains available as the CPU reference measurement.

Acceptance on a physical iPhone X remains p95 ≤ 16.67 ms for the complete interactive frame, with zero buffer overflows and zero non-finite coordinates. The visual prototype keeps simulation buffers persistent and encodes physics, interaction and rendering into one caller-owned command buffer per frame.

The committed XCTest scenario verifies construction and determinism. It is not a device-performance verdict: that requires a signed iOS host installed on the phone.

Host jest w `Benchmarks/iOS/BubblePhysicsBench`. Otwórz `BubblePhysicsBench.xcodeproj` w Xcode 26.6 i wybierz podłączony iPhone. Zakładka `CPU` zawiera benchmark zbieżności z wyborem `CPU reference` / `GPU reference`; pozostałe zakładki udostępniają historyczne eksperymenty. Checklistę CPU opisuje `docs/benchmarks/iphone-x-reference-solver.md`.

### Benchmark zbieżności na urządzeniu

Przed instalacją sprawdź niepodpisany build hosta w Release:

```bash
DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer \
xcodebuild -project Benchmarks/iOS/BubblePhysicsBench/BubblePhysicsBench.xcodeproj \
  -scheme BubblePhysicsBench -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Uruchom aplikację w Release na fizycznym iPhonie. W zakładce `CPU` wybierz `GPU reference`, scenę `24 bańki`, macierz `4/8/12/16` i domyślne 30 klatek rozgrzewki oraz 300 mierzonych. Skopiuj cały raport; powtórz dla `300 baniek`. Oba backendy używają identycznego seeda, ruchu wielokąta, kroków i limitów. CPU nadal uruchamia dotychczasową ścieżkę benchmarku.

Raport zachowuje dotychczasowe kolumny czasu i jakości oraz dopisuje `backend cpu_frames metal_frames fallbacks warmup_fallbacks gpu_measurement`. Liczniki CPU/GPU i fallbacków obejmują także rozgrzewkę. Każdy fallback, również tylko podczas rozgrzewki, daje `gpu_measurement=ineligible`; powody są wypisane pod tabelą. `eligible` oznacza wyłącznie kompletny przebieg GPU bez fallbacku i bez `non-finite`, przygotowany do porównania urządzeniowego — nie zatwierdzenie bramki. Pusty przebieg nie jest kwalifikowany.

`full_p95_ms` obejmuje aktualizację sceny, upload, oczekiwanie CPU+GPU, retry, readback, walidację i przygotowanie klatki. Dla GPU `solver_p95_ms` pochodzi z czasu całego command buffera (obejmuje również geometrię i generowanie konturów); `contour_p95_ms` mierzy pobranie gotowych konturów, a `render_p95_ms` pakowanie danych na CPU. Backend nie udostępnia osobnych znaczników GPU dla tych faz, więc te kolumny nie dowodzą kosztu samego Newton/PCG ani konturów na GPU. Pełna klatka pozostaje porównywalną miarą bramki.

Zapisz rzeczywiste raporty obu scen w `docs/benchmarks/reference-gpu-iphone-YYYY-MM-DD.txt` oraz analizę w `docs/benchmarks/reference-gpu-YYYY-MM-DD.md`. Porównaj każdy limit z niezmienionym baseline'em `reference-convergence-iphone-2026-10-04.txt`: penetrację p95/max, resztę p95/max, niezbieżne komponenty, zawarcia i `non-finite`. Pierwsza bramka dla limitu 4 wymaga `stress-300 full_p95_ms <= 10 ms`, jakości nie gorszej od CPU oraz stabilnego `interactive-24` w budżecie. Limity 8/12/16 pozostają porównaniem, bez adaptacji iteracji. CEO podejmuje decyzję na podstawie rzeczywistych danych; build iOS, symulator i testy hostowe nie zastępują pomiaru fizycznego urządzenia.
