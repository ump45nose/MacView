// swift-tools-version: 6.0
// MacView 的 Core 包。模块划分与依赖见 docs/architecture.md §2。
import PackageDescription

let modules: [(name: String, dependencies: [String])] = [
    ("MVFoundation", []),
    ("MVIO", ["MVFoundation"]),
    ("MVArchive", ["MVFoundation", "MVIO"]),
    ("MVMedia", ["MVFoundation"]),
    ("MVCache", ["MVFoundation", "GRDB"]),
    ("MVPipeline", ["MVFoundation", "MVIO", "MVMedia", "MVCache"]),
    ("MVSettings", ["MVFoundation", "GRDB"]),
    ("MVCommands", ["MVFoundation"]),
    ("MVLayout", ["MVFoundation", "MVSettings"]),
    ("MVReading", ["MVFoundation", "MVIO", "MVMedia", "MVCache", "MVPipeline", "MVSettings"]),
    ("MVServices", ["MVFoundation", "MVIO", "MVArchive", "MVMedia", "MVCache", "MVPipeline", "MVSettings", "MVCommands", "MVReading"]),
    ("MVTestSupport", ["MVFoundation", "MVIO", "MVMedia", "MVPipeline", "MVSettings", "MVCommands", "MVReading", "MVServices"]),
]

/// 测试另外需要的目标：MVIO 的测试要启动辅助进程，MVMedia 的测试要读夹具。
let testExtras: [String: [Target.Dependency]] = [
    "MVIO": ["mvio-helper"],
    "MVMedia": ["MVTestSupport"],
    "MVCache": ["mvtest-writer"],
    "MVSettings": ["mvtest-writer"],
    "MVArchive": ["MVTestSupport"],
    "MVPipeline": ["MVTestSupport"],
    "MVReading": ["MVTestSupport"],
]

let package = Package(
    name: "MacViewKit",
    platforms: [.macOS("27.0")],
    products: modules.map { Product.library(name: $0.name, targets: [$0.name]) }
        + [.executable(name: "mvbench", targets: ["mvbench"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    ],
    targets: modules.flatMap { module -> [Target] in
        [
            .target(name: module.name, dependencies: module.dependencies.map {
                $0 == "GRDB" ? .product(name: "GRDB", package: "GRDB.swift") : .target(name: $0)
            }),
            .testTarget(name: "\(module.name)Tests", dependencies: [.target(name: module.name)] + (testExtras[module.name] ?? [])),
        ]
    } + [
        .executableTarget(name: "mvio-helper", dependencies: ["MVIO"]),
        .executableTarget(name: "mvtest-writer", dependencies: ["MVCache", "MVSettings"]),
        .executableTarget(
            name: "mvbench",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "MVFoundation",
                "MVIO",
                "MVMedia",
                "MVCache",
                "MVPipeline",
                "MVArchive",
                "MVTestSupport",
            ]
        ),
        .testTarget(name: "mvbenchTests", dependencies: ["mvbench", "MVTestSupport"]),
    ]
)
