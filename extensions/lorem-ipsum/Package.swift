// swift-tools-version: 6.1

import Foundation
import PackageDescription

// PrismExtensionKit from its published repository, or from a Prism checkout
// while developing against an unreleased protocol:
//   PRISM_KIT_PATH=~/projects/prism/Packages/PrismExtensionKit swift build
let kitPath = Context.environment["PRISM_KIT_PATH"]
let kit: Package.Dependency = kitPath.map { .package(path: $0) }
    ?? .package(url: "https://github.com/natsustan/prism-extension-kit.git", from: "0.10.0")
let kitPackage = kitPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "prism-extension-kit"

let package = Package(
    name: "LoremIpsum",
    platforms: [.macOS(.v15)],
    dependencies: [kit],
    targets: [
        .executableTarget(
            name: "LoremIpsum",
            dependencies: [.product(name: "PrismExtensionKit", package: kitPackage)]
        ),
        // Tests drive the extension through PrismTestHost, Prism played in memory.
        .testTarget(
            name: "LoremIpsumTests",
            dependencies: ["LoremIpsum", .product(name: "PrismExtensionTesting", package: kitPackage)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
