// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MiPopup",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MiPopupCore", targets: ["MiPopupCore"]),
        .library(name: "MiPopupLAN", targets: ["MiPopupLAN"]),
        .executable(name: "MiPopup", targets: ["MiPopup"])
    ],
    targets: [
        .target(name: "MiPopupCore"),
        .target(
            name: "MiPopupLAN",
            dependencies: ["MiPopupCore"]
        ),
        .executableTarget(
            name: "MiPopup",
            dependencies: ["MiPopupCore", "MiPopupLAN"]
        ),
        .testTarget(
            name: "MiPopupCoreTests",
            dependencies: ["MiPopupCore", "MiPopupLAN"]
        )
    ]
)
