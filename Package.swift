// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UtilizationAnalyzer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "UtilizationAnalyzer",
            targets: ["UtilizationAnalyzer"]
        )
    ],
    targets: [
        .executableTarget(
            name: "UtilizationAnalyzer",
            path: "Sources/UtilizationAnalyzer",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Charts"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
