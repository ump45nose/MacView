// swift-tools-version: 6.0
// MacView 的 Core 包。模块划分与依赖见 docs/architecture.md §2。
import PackageDescription

let modules: [(name: String, dependencies: [String])] = [
    ("MVFoundation", []),
    ("MVIO", ["MVFoundation"]),
    ("MVArchive", ["MVFoundation", "MVIO"]),
    ("MVMedia", ["MVFoundation"]),
    ("MVCache", ["MVFoundation"]),
    ("MVPipeline", ["MVFoundation", "MVIO", "MVMedia", "MVCache"]),
    ("MVSettings", ["MVFoundation"]),
    ("MVCommands", ["MVFoundation"]),
    ("MVReading", ["MVFoundation", "MVIO", "MVMedia", "MVPipeline", "MVSettings"]),
    ("MVServices", ["MVFoundation", "MVIO", "MVArchive", "MVMedia", "MVCache", "MVPipeline", "MVSettings", "MVCommands", "MVReading"]),
    ("MVTestSupport", ["MVFoundation", "MVIO", "MVMedia", "MVPipeline", "MVSettings", "MVCommands", "MVReading", "MVServices"]),
]

/// 测试另外需要的目标：MVIO 的测试要启动辅助进程。
let testExtras: [String: [Target.Dependency]] = [
    "MVIO": ["mvio-helper"],
]

let package = Package(
    name: "MacViewKit",
    platforms: [.macOS("27.0")],
    products: modules.map { Product.library(name: $0.name, targets: [$0.name]) }
        + [.executable(name: "mvbench", targets: ["mvbench"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: modules.flatMap { module -> [Target] in
        [
            .target(name: module.name, dependencies: module.dependencies.map { .target(name: $0) }),
            .testTarget(name: "\(module.name)Tests", dependencies: [.target(name: module.name)] + (testExtras[module.name] ?? [])),
        ]
    } + [
        .executableTarget(name: "mvio-helper", dependencies: ["MVIO"]),
        .executableTarget(
            name: "mvbench",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "MVFoundation",
                "MVIO",
                "MVTestSupport",
            ]
        ),
        .testTarget(name: "mvbenchTests", dependencies: ["mvbench", "MVTestSupport"]),
    ]
)
