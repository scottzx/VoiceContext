// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TranscribeKit",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        // 统一顶层模块，开箱即用
        .library(name: "TranscribeKit", targets: ["TranscribeKit"]),
        // 命令行可执行工具
        .executable(name: "transcribe-cli", targets: ["transcribe-cli"]),
        // 细分子模块，供轻量或按需场景按需依赖
        .library(name: "TranscribeNative", targets: ["TranscribeNative"]),
        .library(name: "CTranscribeRuntime", targets: ["CTranscribe"]),
        .library(name: "TranscribeCore", targets: ["TranscribeCore"]),
        .library(name: "TranscribePipeline", targets: ["TranscribePipeline"]),
        .library(name: "TranscribeStreaming", targets: ["TranscribeStreaming"]),
    ],
    targets: [
        // 1. 底层 C++ / Metal 二进制库 (支持 macOS arm64, iOS arm64, iOS Simulator)
        .binaryTarget(
            name: "CTranscribe",
            path: "Vendor/TranscribeCpp.xcframework"
        ),

        // 2. 原生 Swift C-API 绑定层 (Model, Session, Stream, Family 等)
        .target(
            name: "TranscribeNative",
            dependencies: ["CTranscribe"],
            path: "Sources/TranscribeNative",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),

        // 3. 核心基础设施层 (模型管理、音频重采样、文本规整、统一引擎接口)
        .target(
            name: "TranscribeCore",
            dependencies: ["TranscribeNative"],
            path: "Sources/TranscribeCore",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
            ]
        ),

        // 4. 离线长媒体与字幕管线 (音视频解封装、时间轴 VAD、SRT/VTT 导出)
        .target(
            name: "TranscribePipeline",
            dependencies: ["TranscribeCore"],
            path: "Sources/TranscribePipeline",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
            ]
        ),

        // 5. 实时音频与流式输入管线 (麦克风实时重采样、流式 VAD、实时听写状态机)
        .target(
            name: "TranscribeStreaming",
            dependencies: ["TranscribeCore"],
            path: "Sources/TranscribeStreaming",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Foundation"),
            ]
        ),

        // 6. 统一顶层模块 (聚合 Core + Pipeline + Streaming)
        .target(
            name: "TranscribeKit",
            dependencies: [
                "TranscribeNative",
                "TranscribeCore",
                "TranscribePipeline",
                "TranscribeStreaming",
            ],
            path: "Sources/TranscribeKit"
        ),

        // 7. 测试套件
        .testTarget(
            name: "TranscribeKitTests",
            dependencies: ["TranscribeKit"],
            path: "Tests/TranscribeKitTests"
        ),

        // 8. 命令行 CLI 工具
        .executableTarget(
            name: "transcribe-cli",
            dependencies: [
                "TranscribeKit",
            ],
            path: "Sources/transcribe-cli"
        ),
    ]
)
