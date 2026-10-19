import Foundation
import PrismExtensionProtocol

/// Maintains the Gallery's `index.json`: `add` puts a released package's
/// entry in (one entry per extension, the newest version), `source` points an
/// entry at its folder after that moves, and `sign` writes `index.json.sig`. The release workflow runs both; the private key never
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
        case "source":
            guard let id = option("--id", in: arguments),
                  let urlString = option("--url", in: arguments), let url = URL(string: urlString) else {
                throw ToolFailure("source needs --id and --url.")
            }
            try setSource(url, of: ExtensionID(id), in: indexURL)
        case "sign":
            guard let keyID = option("--key-id", in: arguments) else { throw ToolFailure("sign needs --key-id.") }
            guard let key = ProcessInfo.processInfo.environment["PRISM_GALLERY_SIGNING_KEY"], !key.isEmpty else {
                throw ToolFailure("PRISM_GALLERY_SIGNING_KEY is not set.")
            }
            let signature = try ExtensionGallerySigning.sign(Data(contentsOf: indexURL), privateKey: key, keyID: keyID)
            try encoder.encode(signature).write(to: indexURL.appendingPathExtension("sig"))
            print("Signed \(indexURL.lastPathComponent) with \(keyID).")
        default:
            throw ToolFailure("index needs add, source, or sign.")
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
            publishedAt: Date(), sourceURL: source, releaseNotes: notes
        )
        index.extensions.removeAll { $0.id == manifest.id }
        index.extensions.append(entry)
        index.extensions.sort { $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending }
        index.generatedAt = Date()
        try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(index).write(to: indexURL)
        print("Indexed \(manifest.id.rawValue) \(manifest.version).")
    }

    /// Points an existing entry's source link at `url`, printing “Moved” when
    /// that changed the index. A missing entry is left for `add`.
    static func setSource(_ url: URL, of id: ExtensionID, in indexURL: URL) throws {
        var index = try ExtensionWire.decode(ExtensionGalleryIndex.self, from: Data(contentsOf: indexURL))
        guard let position = index.extensions.firstIndex(where: { $0.id == id }),
              index.extensions[position].sourceURL != url else { return }
        index.extensions[position].sourceURL = url
        index.generatedAt = Date()
        try encoder.encode(index).write(to: indexURL)
        print("Moved \(id.rawValue)'s source to \(url.absoluteString).")
    }

    /// The manifest inside a package, read without unpacking it to disk.
    static func packagedManifest(_ package: URL) throws -> ExtensionManifest {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", package.path, "manifest.json"]
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ToolFailure("\(package.lastPathComponent) has no manifest.json.") }
        return try JSONDecoder().decode(ExtensionManifest.self, from: data)
    }
}
