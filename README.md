# BubblePhysics

`BubblePhysics` is a Swift package for deformable 2D bubbles, polygon obstacles, compliant grabs and structural bubble operations.

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

## Benchmark scenario

`BenchmarkScenario.iPhoneX` creates a deterministic board of 300 bubbles for the 375 × 812 point iPhone X canvas. The number of boundary points is derived only from `WorldConfiguration.maxBoundarySegmentLength`; the package does not impose a maximum node count.

Use `MetalBenchmarkReport.measure(scenario: .iPhoneX, steps: 300)` in an iOS host to collect GPU step-time p50/p95 and separate shape, contact and interaction timings. The report also includes particle, candidate-pair and contact counts plus overflow and non-finite-state flags. `BenchmarkReport` remains available as the CPU reference measurement.

Acceptance on a physical iPhone X remains p95 ≤ 16.67 ms for the complete interactive frame, with zero buffer overflows and zero non-finite coordinates. The visual prototype keeps simulation buffers persistent and encodes physics, interaction and rendering into one caller-owned command buffer per frame.

The committed XCTest scenario verifies construction and determinism. It is not a device-performance verdict: that requires a signed iOS host installed on the phone.

The host is in `Benchmarks/iOS/BubblePhysicsBench`. Open `BubblePhysicsBench.xcodeproj` specifically in Xcode 26.6, choose the connected iPhone X and run. The app provides live 40/300-bubble scenes, pause/reset, diagnostic points, triangle pause, touch grabbing and throttled p50/p95 telemetry. See `docs/benchmarks/iphone-x-visual-prototype.md` for the device checklist.
