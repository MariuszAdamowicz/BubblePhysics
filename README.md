# BubblePhysics

`BubblePhysics` is a Swift package for deformable 2D bubbles, polygon obstacles, compliant grabs and structural bubble operations.

## Benchmark scenario

`BenchmarkScenario.iPhoneX` creates a deterministic board of 300 bubbles for the 375 × 812 point iPhone X canvas. The number of boundary points is derived only from `WorldConfiguration.maxBoundarySegmentLength`; the package does not impose a maximum node count.

Use `BenchmarkReport.measure(scenario: .iPhoneX, steps: 300)` in an iOS host to collect step-time p50/p95. Acceptance on a physical iPhone X remains: 60 simulation steps and 60 rendered frames per second for five minutes, with no non-finite coordinates or growing penetration.

The committed XCTest scenario verifies construction and determinism. It is not a device-performance verdict: that requires a signed iOS host installed on the phone.

The host is in `Benchmarks/iOS/BubblePhysicsBench`. Generate it with `xcodegen generate` in that directory, then open `BubblePhysicsBench.xcodeproj`, choose a signed team and run it on the connected iPhone X. The button executes 300 simulation steps and displays p50/p95 step time.
