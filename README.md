# BubblePhysics

`BubblePhysics` is a Swift package for deformable 2D bubbles, polygon obstacles, compliant grabs and structural bubble operations.

## Benchmark scenario

`BenchmarkScenario.iPhoneX` creates a deterministic board of 300 bubbles for the 375 × 812 point iPhone X canvas. The number of boundary points is derived only from `WorldConfiguration.maxBoundarySegmentLength`; the package does not impose a maximum node count.

Use `MetalBenchmarkReport.measure(scenario: .iPhoneX, steps: 300)` in an iOS host to collect GPU step-time p50/p95 and separate shape, contact and interaction timings. The report also includes particle, candidate-pair and contact counts plus overflow and non-finite-state flags. `BenchmarkReport` remains available as the CPU reference measurement.

Acceptance on a physical iPhone X remains p95 ≤ 16.67 ms for the complete interactive frame, with zero buffer overflows and zero non-finite coordinates. The visual prototype keeps simulation buffers persistent and encodes physics, interaction and rendering into one caller-owned command buffer per frame.

The committed XCTest scenario verifies construction and determinism. It is not a device-performance verdict: that requires a signed iOS host installed on the phone.

The host is in `Benchmarks/iOS/BubblePhysicsBench`. Open `BubblePhysicsBench.xcodeproj` specifically in Xcode 26.6, choose the connected iPhone X and run. The app provides live 40/300-bubble scenes, pause/reset, diagnostic points, triangle pause, touch grabbing and throttled p50/p95 telemetry. See `docs/benchmarks/iphone-x-visual-prototype.md` for the device checklist.
