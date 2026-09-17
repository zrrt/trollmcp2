// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TrollMCP2",
    platforms: [.iOS(.v15)   // v2.9.250: 部署目标16→15治本——按16编译会引用iOS16+符号(URLRequest.httpMethod/timeoutInterval等availability标注错误的Swift setter)导致iOS15.6 dyld崩;15避开iOS16+ API且保留全部iOS15 API(safeAreaInset等),降14过度会报一堆iOS15 API错误],
    targets: [
        .executableTarget(
            name: "TrollMCP2",
            path: "Sources/TrollMCP2",
            exclude: ["Resources"],
            linkerSettings: [.linkedLibrary("z")]
        )
    ]
)
