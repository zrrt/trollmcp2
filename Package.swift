// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TrollMCP2",
    platforms: [.iOS(.v14)   // v2.9.249: 部署目标16→14治本——Swift编译器按16编译会合法引用iOS16+符号(URLRequest.httpMethod/timeoutInterval等availability标注错误的overlay符号),在iOS15.6 dyld崩;降到14编译器自动避免iOS16+ API,只保留需手工处理的标注bug符号],
    targets: [
        .executableTarget(
            name: "TrollMCP2",
            path: "Sources/TrollMCP2",
            exclude: ["Resources"],
            linkerSettings: [.linkedLibrary("z")]
        )
    ]
)
