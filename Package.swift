// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "X5INSVPlayer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "X5INSVPlayer", targets: ["X5PlayerApp"])],
    targets: [
        .executableTarget(
            name: "X5PlayerApp",
            // Copied rather than processed: the renderer builds the shader at
            // launch when the toolchain has not produced a default.metallib.
            resources: [.copy("Shaders")]
        )
    ]
)
