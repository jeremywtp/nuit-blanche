// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NuitBlanche",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "NuitBlanche",
            path: "Sources/NuitBlanche",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "NuitBlancheTests",
            dependencies: ["NuitBlanche"],
            path: "Tests/NuitBlancheTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
