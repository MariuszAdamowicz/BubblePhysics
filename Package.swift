// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BubblePhysics",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "BubblePhysics", targets: ["BubblePhysics"]),
        .library(name: "BubblePhysicsMetalRender", targets: ["BubblePhysicsMetalRender"]),
        .library(name: "BubblePhysicsAssets", targets: ["BubblePhysicsAssets"]),
        // Wyłącznie narzędzia diagnostyczne; te moduły nie są API gry.
        .library(name: "BubblePhysicsBenchmarkSupport", targets: [
            "BubblePhysicsLegacy", "BubblePhysicsCore", "BubblePhysicsMetal",
            "BubblePhysicsReference", "BubblePhysicsReferenceMetal", "BubblePhysicsNativeMetal",
            "BubblePhysicsNativeMetalDiagnostics"
        ]),
        .executable(name: "BubblePhysicsReferenceBench", targets: ["BubblePhysicsReferenceBench"]),
        .executable(name: "BubblePhysicsPerfGuard", targets: ["BubblePhysicsPerfGuard"])
    ],
    targets: [
        .executableTarget(name: "BubblePhysicsReferenceBench",
                          dependencies: ["BubblePhysicsReference", "BubblePhysicsReferenceMetal", "BubblePhysicsNativeMetal",
                                         "BubblePhysicsNativeMetalDiagnostics"],
                          path: "Benchmarks/macOS/BubblePhysicsReferenceBench"),
        // Strażnik wydajności na Macu; uruchamiany `swift run -c release BubblePhysicsPerfGuard`, nie przez `swift test`.
        .executableTarget(name: "BubblePhysicsPerfGuard",
                          dependencies: ["BubblePhysics", "BubblePhysicsMetalRender"],
                          path: "Benchmarks/macOS/BubblePhysicsPerfGuard"),
        .target(name: "BubblePhysics", dependencies: ["BubblePhysicsRuntime", "BubblePhysicsModel", "BubblePhysicsNativeMetal", "BubblePhysicsAssets"],
                path: "Sources/BubblePhysicsPublic", exclude: ["Model"]),
        .target(name: "BubblePhysicsMetalRender", dependencies: ["BubblePhysics", "BubblePhysicsNativeMetal", "BubblePhysicsModel"]),
        .target(name: "BubblePhysicsModel", path: "Sources/BubblePhysicsPublic/Model"),
        // Rejestr tekstur gry per urządzenie Metal; nie zależy od świata ani od Runtime.
        .target(name: "BubblePhysicsAssets", dependencies: ["BubblePhysicsModel"]),
        .target(name: "BubblePhysicsRuntime", dependencies: ["BubblePhysicsNativeMetal", "BubblePhysicsModel"]),
        .target(name: "BubblePhysicsLegacy", path: "Sources/BubblePhysics"),
        .target(name: "BubblePhysicsCore"),
        .target(name: "BubblePhysicsReference"),
        .target(name: "BubblePhysicsNativeMetal", dependencies: ["BubblePhysicsModel"],
                resources: [.copy("Shaders/NativeGeometryKernels.metal-source"), .copy("Shaders/NativeXPBDKernels.metal-source"), .copy("Shaders/NativePostSolveKernels.metal-source"), .copy("Shaders/NativeRenderKernels.metal-source")]),
        // Narzędzia pomiarowe i adapter `ReferenceWorld` → `NativeSolverInput`; poza modułami produkcyjnymi.
        .target(name: "BubblePhysicsNativeMetalDiagnostics",
                dependencies: ["BubblePhysicsNativeMetal", "BubblePhysicsReference", "BubblePhysicsModel"]),
        .target(name: "BubblePhysicsReferenceMetal", dependencies: ["BubblePhysicsReference"],
                // Xcode processes .metal even with .copy; preserve text for runtime compilation.
                resources: [.copy("Shaders/ReferenceNewtonPCGKernels.metal-source"), .copy("Shaders/ReferenceGeometryKernels.metal-source"), .copy("Shaders/ReferencePostSolveKernels.metal-source")]),
        .target(
            name: "BubblePhysicsMetal",
            dependencies: ["BubblePhysicsLegacy"],
            resources: [.copy("Shaders/BubblePhysicsKernels.metal"), .copy("Shaders/LBVHKernels.metal"), .copy("Shaders/ContactKernels.metal"), .copy("Shaders/ContourContactKernels.metal"), .copy("Shaders/RemeshKernels.metal"), .copy("Shaders/PolygonKernels.metal"), .copy("Shaders/InteractionKernels.metal"), .copy("Shaders/RenderKernels.metal"), .copy("Shaders/RadialBubbleKernels.metal"), .copy("Shaders/RadialContactKernels.metal"), .copy("Shaders/RadialWorldKernels.metal"), .copy("Shaders/RadialWorldPairKernels.metal")]
        ),
        .testTarget(name: "BubblePhysicsPublicTests", dependencies: ["BubblePhysics", "BubblePhysicsAssets"]),
        .testTarget(name: "BubblePhysicsAssetsTests", dependencies: ["BubblePhysicsAssets"]),
        .testTarget(name: "BubblePhysicsPerfGuardTests", dependencies: ["BubblePhysicsPerfGuard"]),
        .testTarget(name: "BubblePhysicsMetalRenderTests", dependencies: ["BubblePhysics", "BubblePhysicsMetalRender"]),
        .testTarget(name: "BubblePhysicsRuntimeTests", dependencies: ["BubblePhysics", "BubblePhysicsRuntime"]),
        .testTarget(name: "BubblePhysicsTests", dependencies: ["BubblePhysicsLegacy"]),
        .testTarget(name: "BubblePhysicsCoreTests", dependencies: ["BubblePhysicsCore"]),
        .testTarget(name: "BubblePhysicsReferenceTests", dependencies: ["BubblePhysicsReference"]),
        .testTarget(name: "BubblePhysicsReferenceMetalTests", dependencies: ["BubblePhysicsReferenceMetal"]),
        .testTarget(name: "BubblePhysicsNativeMetalTests", dependencies: ["BubblePhysicsNativeMetal", "BubblePhysicsRuntime"]),
        .testTarget(name: "BubblePhysicsNativeMetalDiagnosticsTests",
                    dependencies: ["BubblePhysicsNativeMetalDiagnostics", "BubblePhysicsNativeMetal", "BubblePhysicsReference",
                                   "BubblePhysicsModel"]),
        .testTarget(name: "BubblePhysicsMetalTests", dependencies: ["BubblePhysicsLegacy", "BubblePhysicsMetal"])
    ]
)
