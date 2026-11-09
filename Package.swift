// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JingXing",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "JingXing", targets: ["JingXing"])
    ],
    targets: [
        // 可測試的核心邏輯：計時、電源 assertion、上鎖、合蓋看守程序。
        .target(
            name: "JingXingCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        // 選單列 App（AppKit + SwiftUI）。
        .executableTarget(
            name: "JingXing",
            dependencies: ["JingXingCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(
            name: "JingXingCoreTests",
            dependencies: ["JingXingCore"]
        ),
    ]
)
