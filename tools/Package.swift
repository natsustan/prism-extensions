// swift-tools-version: 6.1

import Foundation
import PackageDescription

// PrismExtensionKit from its published repository, or from a Prism checkout
// while developing against an unreleased protocol:
//   PRISM_KIT_PATH=~/projects/prism/Packages/PrismExtensionKit swift build
let kitPath = Context.environment["PRISM_KIT_PATH"]
let kit: Package.Dependency = kitPath.map { .package(path: $0) }
    ?? .package(url: "https://github.com/natsustan/prism-extension-kit.git", from: "0.1.1")
let kitPackage = kitPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "prism-extension-kit"

let package = Package(
    name: "PrismExtensionTool",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "prism-extension", targets: ["PrismExtensionTool"]),
    ],
    dependencies: [kit],
    targets: [
        .executableTarget(
            name: "PrismExtensionTool",
            dependencies: [.product(name: "PrismExtensionProtocol", package: kitPackage)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
