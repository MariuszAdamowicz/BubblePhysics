# BubblePhysics

`BubblePhysics` is a Swift package for deformable 2D bubbles, polygon obstacles, compliant grabs and structural bubble operations.

## Benchmark scenario

`BenchmarkScenario.iPhoneX` creates a deterministic board of 300 bubbles for the 375 × 812 point iPhone X canvas. The number of boundary points is derived only from `WorldConfiguration.maxBoundarySegmentLength`; the package does not impose a maximum node count.

Use `MetalBenchmarkReport.measure(scenario: .iPhoneX, steps: 300)` in an iOS host to collect GPU step-time p50/p95 and separate shape, contact and interaction timings. The report also includes particle, candidate-pair and contact counts plus overflow and non-finite-state flags. `BenchmarkReport` remains available as the CPU reference measurement.

Acceptance on a physical iPhone X remains p95 ≤ 8 ms for physics, with zero buffer overflows and zero non-finite coordinates. The current Metal implementation is a correctness-first baseline: the stages run on the GPU, but the Swift facade still performs readback and creates buffers between stages. The device result therefore measures the present implementation honestly; persistent buffers and a single command buffer remain the principal optimization if the target is missed.

The committed XCTest scenario verifies construction and determinism. It is not a device-performance verdict: that requires a signed iOS host installed on the phone.

The host is in `Benchmarks/iOS/BubblePhysicsBench`. Its project is committed and can also be regenerated with `xcodegen generate` in that directory. Open `BubblePhysicsBench.xcodeproj`, choose the signed team and run it on the connected iPhone X. The quick button executes 3 Metal steps; the full button executes 300 and displays all acceptance counters.
