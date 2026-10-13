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
        .library(name: "BubblePhysicsCore", targets: ["BubblePhysicsCore"]),
        .library(name: "BubblePhysicsMetal", targets: ["BubblePhysicsMetal"]),
        .library(name: "BubblePhysicsReference", targets: ["BubblePhysicsReference"]),
        .library(name: "BubblePhysicsReferenceMetal", targets: ["BubblePhysicsReferenceMetal"]),
        .library(name: "BubblePhysicsNativeMetal", targets: ["BubblePhysicsNativeMetal"]),
        .executable(name: "BubblePhysicsReferenceBench", targets: ["BubblePhysicsReferenceBench"])
    ],
    targets: [
        .executableTarget(name: "BubblePhysicsReferenceBench",
                          dependencies: ["BubblePhysicsReference", "BubblePhysicsReferenceMetal", "BubblePhysicsNativeMetal"],
                          path: "Benchmarks/macOS/BubblePhysicsReferenceBench"),
        .target(name: "BubblePhysics"),
        .target(name: "BubblePhysicsCore"),
        .target(name: "BubblePhysicsReference"),
        .target(name: "BubblePhysicsNativeMetal", dependencies: ["BubblePhysicsReference"],
                resources: [.copy("Shaders/NativeGeometryKernels.metal-source"), .copy("Shaders/NativeXPBDKernels.metal-source"), .copy("Shaders/NativePostSolveKernels.metal-source")]),
        .target(name: "BubblePhysicsReferenceMetal", dependencies: ["BubblePhysicsReference"],
                // Xcode processes .metal even with .copy; preserve text for runtime compilation.
                resources: [.copy("Shaders/ReferenceNewtonPCGKernels.metal-source"), .copy("Shaders/ReferenceGeometryKernels.metal-source"), .copy("Shaders/ReferencePostSolveKernels.metal-source")]),
        .target(
            name: "BubblePhysicsMetal",
            dependencies: ["BubblePhysics"],
            resources: [.copy("Shaders/BubblePhysicsKernels.metal"), .copy("Shaders/LBVHKernels.metal"), .copy("Shaders/ContactKernels.metal"), .copy("Shaders/ContourContactKernels.metal"), .copy("Shaders/RemeshKernels.metal"), .copy("Shaders/PolygonKernels.metal"), .copy("Shaders/InteractionKernels.metal"), .copy("Shaders/RenderKernels.metal"), .copy("Shaders/RadialBubbleKernels.metal"), .copy("Shaders/RadialContactKernels.metal"), .copy("Shaders/RadialWorldKernels.metal"), .copy("Shaders/RadialWorldPairKernels.metal")]
        ),
        .testTarget(name: "BubblePhysicsTests", dependencies: ["BubblePhysics"]),
        .testTarget(name: "BubblePhysicsCoreTests", dependencies: ["BubblePhysicsCore"]),
        .testTarget(name: "BubblePhysicsReferenceTests", dependencies: ["BubblePhysicsReference"]),
        .testTarget(name: "BubblePhysicsReferenceMetalTests", dependencies: ["BubblePhysicsReferenceMetal"]),
        .testTarget(name: "BubblePhysicsNativeMetalTests", dependencies: ["BubblePhysicsNativeMetal"]),
        .testTarget(name: "BubblePhysicsMetalTests", dependencies: ["BubblePhysics", "BubblePhysicsMetal"])
    ]
)
