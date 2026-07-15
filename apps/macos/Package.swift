// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MiPopup",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MiPopupCore", targets: ["MiPopupCore"]),
        .executable(name: "MiPopup", targets: ["MiPopup"])
    ],
    targets: [
        .target(name: "MiPopupCore"),
        .executableTarget(
            name: "MiPopup",
            dependencies: ["MiPopupCore"]
        ),
        .testTarget(
            name: "MiPopupCoreTests",
            dependencies: ["MiPopupCore"]
        )
    ]
)
