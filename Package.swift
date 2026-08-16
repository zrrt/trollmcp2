// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TrollMCP2",
    platforms: [.iOS(.v14)],
    targets: [
        .executableTarget(
            name: "TrollMCP2",
            path: "Sources/TrollMCP2",
            exclude: ["Resources"]
        )
    ]
)
