// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SmartLayout",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SmartLayout",
            path: "Sources/SmartLayout",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices")
            ]
        ),
        .testTarget(
            name: "SmartLayoutTests",
            dependencies: ["SmartLayout"],
            path: "Tests/SmartLayoutTests"
        )
    ]
)
