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
        .library(name: "BubblePhysicsMetal", targets: ["BubblePhysicsMetal"])
    ],
    targets: [
        .target(name: "BubblePhysics"),
        .target(
            name: "BubblePhysicsMetal",
            dependencies: ["BubblePhysics"],
            resources: [.copy("Shaders/BubblePhysicsKernels.metal"), .copy("Shaders/LBVHKernels.metal"), .copy("Shaders/ContactKernels.metal"), .copy("Shaders/ContourContactKernels.metal"), .copy("Shaders/RemeshKernels.metal"), .copy("Shaders/PolygonKernels.metal"), .copy("Shaders/InteractionKernels.metal"), .copy("Shaders/RenderKernels.metal"), .copy("Shaders/RadialBubbleKernels.metal"), .copy("Shaders/RadialContactKernels.metal")]
        ),
        .testTarget(name: "BubblePhysicsTests", dependencies: ["BubblePhysics"]),
        .testTarget(name: "BubblePhysicsMetalTests", dependencies: ["BubblePhysics", "BubblePhysicsMetal"])
    ]
)
