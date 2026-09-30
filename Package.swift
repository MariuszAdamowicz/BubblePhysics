// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BubblePhysics",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "BubblePhysics", targets: ["BubblePhysics"])
    ],
    targets: [
        .target(name: "BubblePhysics"),
        .testTarget(name: "BubblePhysicsTests", dependencies: ["BubblePhysics"])
    ]
)
