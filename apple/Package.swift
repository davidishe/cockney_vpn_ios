// swift-tools-version: 5.9

import PackageDescription
import Foundation

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let mobileFrameworkPath = "\(packageDirectory)/Frameworks/Mobile.xcframework"
let hasMobileFramework = FileManager.default.fileExists(atPath: mobileFrameworkPath)
let kitDependencies: [Target.Dependency] = hasMobileFramework
    ? [.target(name: "Mobile", condition: .when(platforms: [.iOS]))]
    : []
let mobileTargets: [Target] = hasMobileFramework
    ? [.binaryTarget(name: "Mobile", path: "Frameworks/Mobile.xcframework")]
    : []

let package = Package(
    name: "OlcRTCApple",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    // macOS app lives in Godwit.xcodeproj (scheme "OlcRTCClient macOS"), not in this
    // package product list — otherwise scheme "OlcRTCApple-Package" + iPhone tries to
    // compile AppKit sources and fails with "No such module 'AppKit'".
    products: [
        .library(
            name: "OlcRTCClientKit",
            targets: ["OlcRTCClientKit"]
        ),
    ],
    targets: [
        .target(
            name: "OlcRTCClientKit",
            dependencies: kitDependencies,
            resources: [
                .process("Resources"),
            ],
            linkerSettings: hasMobileFramework
                ? [.linkedLibrary("resolv", .when(platforms: [.iOS]))]
                : []
        ),
        .testTarget(
            name: "OlcRTCClientKitTests",
            dependencies: ["OlcRTCClientKit"]
        ),
    ] + mobileTargets
)
