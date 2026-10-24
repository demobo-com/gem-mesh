// swift-tools-version: 5.9
// The iPhone app's platform-free logic: policy, router, classifier, pairing, tool definitions and tool-call repair.
// No UIKit, no LiteRT-LM, so `swift test` runs the golden cases on any machine with a Swift toolchain (Linux too).

import PackageDescription

let package = Package(
    name: "GemmaMeshKit",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "GemmaMeshKit", targets: ["GemmaMeshKit"]),
    ],
    dependencies: [
        // policy/*.yaml is read as YAML at run time, so the app ships the repo's files unchanged.
        .package(url: "https://github.com/jpsim/Yams.git", exact: "5.1.3"),
    ],
    targets: [
        .target(name: "GemmaMeshKit", dependencies: ["Yams"]),
        .testTarget(name: "GemmaMeshKitTests", dependencies: ["GemmaMeshKit"]),
    ]
)
