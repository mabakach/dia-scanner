// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DiaScanner",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiaScannerLib", targets: ["DiaScannerLib"]),
        .library(name: "DiaScannerUSBBridge", targets: ["DiaScannerUSBBridge"]),
        .executable(name: "DiaScanner", targets: ["DiaScanner"]),
        .executable(name: "DiaScannerCLI", targets: ["DiaScannerCLI"]),
    ],
    targets: [
        // Low-level IOKit USB bridge (Objective-C)
        .target(
            name: "DiaScannerUSBBridge",
            path: "Sources/DiaScannerUSBBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOUSBHost"),
            ]
        ),
        // Core scanner library (Swift, testable)
        .target(
            name: "DiaScannerLib",
            dependencies: ["DiaScannerUSBBridge"],
            path: "Sources/DiaScannerLib",
            swiftSettings: [
                .unsafeFlags(["-enable-testing"]),
            ]
        ),
        // SwiftUI app
        .executableTarget(
            name: "DiaScanner",
            dependencies: ["DiaScannerLib"],
            path: "Sources/DiaScanner"
        ),
        // CLI runner (for automated testing without GUI)
        .executableTarget(
            name: "DiaScannerCLI",
            dependencies: ["DiaScannerLib"],
            path: "Sources/DiaScannerCLI"
        ),
        // Unit tests
        .testTarget(
            name: "DiaScannerTests",
            dependencies: ["DiaScannerLib"],
            path: "Tests/DiaScannerTests"
        ),
    ]
)
