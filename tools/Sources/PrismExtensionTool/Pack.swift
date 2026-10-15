import Foundation
import PrismExtensionProtocol

/// Builds the `.prismextension` the Gallery publishes: a zip of what the
/// extension needs at run time. Sources, tests, and build output stay out; a
/// Swift extension's built executable moves to `bin/` and the packaged
/// manifest points there.
enum Pack {
    /// Top-level names that never ship.
    static let excluded: Set<String> = [
        ".build", ".swiftpm", ".git", ".gitignore", ".DS_Store",
        "Sources", "Tests", "tests", "Package.swift", "Package.resolved",
    ]

    struct Result: Encodable, CustomStringConvertible {
        let id: String
        let version: String
        let path: String
        let sha256: String
        let size: Int

        var description: String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "\(id) \(version)"
        }
    }

    static func run(_ folder: URL, output: URL) throws -> Result {
        let manifest = try manifest(of: folder)
        let executable = try ExtensionFolderValidator.executableURL(of: manifest, in: folder)
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appendingPathComponent("prism-pack-\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        for name in try fileManager.contentsOfDirectory(atPath: folder.path) where !excluded.contains(name) {
            try fileManager.copyItem(at: folder.appendingPathComponent(name), to: staging.appendingPathComponent(name))
        }
        try rejectLinks(in: staging)

        // A built executable leaves the build folder for bin/.
        var packagedExecutable = manifest.executable ?? ""
        if packagedExecutable.hasPrefix(".build/") {
            packagedExecutable = "bin/\(executable.lastPathComponent)"
            let destination = staging.appendingPathComponent(packagedExecutable)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: executable, to: destination)
            try rewriteExecutable(packagedExecutable, in: staging.appendingPathComponent("manifest.json"))
        }
        // What Prism will see after unpacking must pass the same checks.
        _ = try ExtensionFolderValidator.manifest(in: staging, allowsReservedNamespace: isFirstParty(folder))

        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        let package = output.appendingPathComponent("\(manifest.id.rawValue)-\(manifest.version).prismextension")
        try? fileManager.removeItem(at: package)
        try runTool("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", staging.path, package.path])

        let data = try Data(contentsOf: package)
        return Result(
            id: manifest.id.rawValue, version: manifest.version, path: package.path,
            sha256: ExtensionGallerySigning.sha256(data), size: data.count
        )
    }

    /// Packages hold regular files and folders only.
    private static func rejectLinks(in folder: URL) throws {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: Set(keys)))?.isSymbolicLink == true {
            throw ToolFailure("\(url.lastPathComponent) is a symbolic link; packages hold regular files only.")
        }
    }

    private static func rewriteExecutable(_ executable: String, in manifestURL: URL) throws {
        guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any] else {
            throw ToolFailure("manifest.json is not an object.")
        }
        object["executable"] = executable
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: manifestURL)
    }
}

func runTool(_ path: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ToolFailure("\(URL(fileURLWithPath: path).lastPathComponent) failed with status \(process.terminationStatus).")
    }
}
