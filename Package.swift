// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TrollMCP2",
    // v2.9.250: 部署目标 16→15 治本——按16编译会引用 iOS16+ 符号(URLRequest.httpMethod/timeoutInterval 等 availability 标注错误的 Swift setter),iOS15.6 dyld 启动崩;15 避开 iOS16+ API 且保留全部 iOS15 API(safeAreaInset 等),降14过度会报 iOS15 API 编译错误
    platforms: [.iOS(.v15)],
    dependencies: [
        // v2.9.370：RSKGrowingTextView——成熟开源聊天输入框，自动高度+占位符，替代手写 UIViewRepresentable
        .package(url: "https://github.com/ruslanskorb/RSKGrowingTextView.git", from: "7.0.0"),
        // v3.0.37：ZIPFoundation——iSH rootfs 首次启动解压（OpenMinis 同款）
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19")
    ],
    targets: [
        // v3.0.37：iSH-ARM64 C 包装层。头文件由 CI 的 build_ish.sh 生成到 ish-stage/include，
        // 静态库在 ish-stage/libs（CI 产物；本地构建需先跑 scripts/ish-build/*.sh 生成）
        .target(
            name: "CISH",
            path: "CISH",
            cSettings: [
                // 头文件由 CI 复制到 CISH/include/（build_ish.sh 产物 ish-stage/include/ish）
                // 双根：wrapper.c 用 "ish/..."，iSH 源码内部用 "fs/.../kernel/.../misc.h" 等
                .headerSearchPath("include"),
                .headerSearchPath("include/ish"),
                .define("GUEST_ARM64", to: "1"),
                .define("ISH_INTERNAL", to: "1")
            ],
            linkerSettings: [
                .unsafeFlags(["-L", "ish-stage/libs"]),
                .linkedLibrary("ish"),
                .linkedLibrary("ish_emu"),
                .linkedLibrary("fakefs"),
                .linkedLibrary("sqlite3"),
                .linkedLibrary("z")
            ]
        ),
        .executableTarget(
            name: "TrollMCP2",
            dependencies: [
                .product(name: "RSKGrowingTextView", package: "RSKGrowingTextView"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                "CISH"
            ],
            path: "Sources/TrollMCP2",
            exclude: ["Resources"],
            linkerSettings: [.linkedLibrary("z")]
        ),
    ]
)
