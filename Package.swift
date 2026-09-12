// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "X5INSVPlayer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "X5INSVPlayer", targets: ["X5PlayerApp"])],
    targets: [
        .executableTarget(
            name: "X5PlayerApp",
            resources: [.process("Shaders")]
        )
    ]
)
