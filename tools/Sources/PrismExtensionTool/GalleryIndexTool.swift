import Foundation
import PrismExtensionProtocol

/// Maintains the Gallery's `index.json`: `add` puts a released package's
/// entry in (one entry per extension, the newest version), `sign` writes
/// `index.json.sig`. The release workflow runs both; the private key never
/// leaves its secret.
enum GalleryIndexTool {
    static func run(_ arguments: [String]) throws {
        guard let indexPath = option("--index", in: arguments) else { throw ToolFailure("--index is required.") }
        let indexURL = URL(fileURLWithPath: indexPath)
        switch arguments.first {
        case "add":
            guard let packagePath = option("--package", in: arguments),
                  let urlString = option("--url", in: arguments), let url = URL(string: urlString) else {
                throw ToolFailure("add needs --package and --url.")
            }
            let notes = try option("--notes", in: arguments).map { try String(contentsOfFile: $0, encoding: .utf8) }
            try add(
                package: URL(fileURLWithPath: packagePath), url: url,
                source: option("--source", in: arguments).flatMap(URL.init(string:)),
                notes: notes?.trimmingCharacters(in: .whitespacesAndNewlines), to: indexURL
            )
        case "sign":
            guard let keyID = option("--key-id", in: arguments) else { throw ToolFailure("sign needs --key-id.") }
            guard let key = ProcessInfo.processInfo.environment["PRISM_GALLERY_SIGNING_KEY"], !key.isEmpty else {
                throw ToolFailure("PRISM_GALLERY_SIGNING_KEY is not set.")
            }
            let signature = try ExtensionGallerySigning.sign(Data(contentsOf: indexURL), privateKey: key, keyID: keyID)
            try encoder.encode(signature).write(to: indexURL.appendingPathExtension("sig"))
            print("Signed \(indexURL.lastPathComponent) with \(keyID).")
        default:
            throw ToolFailure("index needs add or sign.")
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func add(package: URL, url: URL, source: URL?, notes: String?, to indexURL: URL) throws {
        let data = try Data(contentsOf: package)
        let manifest = try packagedManifest(package)
        let iconImage = try manifest.icon.image.map { try packagedIcon($0, in: package) }
        var index = (try? ExtensionWire.decode(ExtensionGalleryIndex.self, from: Data(contentsOf: indexURL)))
            ?? ExtensionGalleryIndex(generatedAt: Date(), extensions: [])
        if let existing = index.entry(for: manifest.id),
           ExtensionVersion(existing.manifest.version) >= ExtensionVersion(manifest.version),
           existing.package.sha256 != ExtensionGallerySigning.sha256(data) {
            throw ToolFailure("\(manifest.id.rawValue) \(existing.manifest.version) is already published; bump the version.")
        }
        let entry = ExtensionGalleryEntry(
            manifest: manifest,
            package: ExtensionGalleryPackage(url: url, sha256: ExtensionGallerySigning.sha256(data), size: data.count),
            publishedAt: Date(), sourceURL: source, releaseNotes: notes, iconImage: iconImage
        )
        index.extensions.removeAll { $0.id == manifest.id }
        index.extensions.append(entry)
        index.extensions.sort { $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending }
        index.generatedAt = Date()
        try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(index).write(to: indexURL)
        print("Indexed \(manifest.id.rawValue) \(manifest.version).")
    }

    /// The manifest inside a package, read without unpacking it to disk.
    static func packagedManifest(_ package: URL) throws -> ExtensionManifest {
        guard let data = try packagedFile("manifest.json", in: package) else {
            throw ToolFailure("\(package.lastPathComponent) has no manifest.json.")
        }
        return try JSONDecoder().decode(ExtensionManifest.self, from: data)
    }

    /// Prism draws images up to this size; a larger one falls back to the symbol.
    static let maximumIconSize = 512 * 1024

    /// The icon image the manifest names, carried in the index so Prism can
    /// draw the extension's mark before it is installed. The package is
    /// unpacked so the path is read literally, never as an unzip pattern.
    static func packagedIcon(_ path: String, in package: URL) throws -> Data {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("prism-icon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", package.path, folder.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw ToolFailure("\(package.lastPathComponent) could not be unpacked.") }
        let file = folder.appendingPathComponent(path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ToolFailure("\(package.lastPathComponent) has no \(path), which its icon names.")
        }
        let data = try Data(contentsOf: file)
        guard data.count <= maximumIconSize else {
            throw ToolFailure("\(path) is larger than 512 KB, so Prism would not draw it.")
        }
        return data
    }

    /// One file inside a package, or nil when it holds none at that path.
    static func packagedFile(_ path: String, in package: URL) throws -> Data? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", package.path, path]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
