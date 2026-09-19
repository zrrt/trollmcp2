// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TrollMCP2",
    // v2.9.250: 部署目标 16→15 治本——按16编译会引用 iOS16+ 符号(URLRequest.httpMethod/timeoutInterval 等 availability 标注错误的 Swift setter),iOS15.6 dyld 启动崩;15 避开 iOS16+ API 且保留全部 iOS15 API(safeAreaInset 等),降14过度会报 iOS15 API 编译错误
    platforms: [.iOS(.v15)],
    dependencies: [
        // v2.9.370：RSKGrowingTextView——成熟开源聊天输入框，自动高度+占位符，替代手写 UIViewRepresentable
        .package(url: "https://github.com/ruslanskorb/RSKGrowingTextView.git", from: "7.0.0")
    ],
    targets: [
        .executableTarget(
            name: "TrollMCP2",
            path: "Sources/TrollMCP2",
            exclude: ["Resources"],
            linkerSettings: [.linkedLibrary("z")],
            dependencies: [
                .product(name: "RSKGrowingTextView", package: "RSKGrowingTextView")
            ]
        )
    ]
)
