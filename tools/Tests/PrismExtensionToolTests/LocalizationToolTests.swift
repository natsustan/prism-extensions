import Darwin
import Foundation
import PrismExtensionProtocol
import Testing
@testable import PrismExtensionTool

/// A temporary extension folder with an sh executable.
struct TemporaryExtension {
    let folder: URL

    init(manifest: String, executable: String = "bin/run") throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism-tool-\(UUID().uuidString)", isDirectory: true)
        let script = folder.appendingPathComponent(executable)
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
        chmod(script.path, 0o755)
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("manifest.json"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }

    static func manifest(id: String = "octocat.coffee", executable: String = "bin/run", localizations: String) -> String {
        """
        {
          "protocol": 1, "id": "\(id)", "name": "Coffee", "version": "1.0.0", "author": "Octocat",
          "description": "Keep your Mac awake.",
          "icon": { "symbol": "cup.and.saucer.fill", "tint": "brown" },
          "executable": "\(executable)",
          "commands": [{ "id": "brew", "title": "Brew", "subtitle": "Coffee", "mode": "no-view" }],
          "preferences": [{ "id": "disk", "type": "bool", "title": "Disks", "section": "Power" }],
          "localizations": \(localizations)
        }
        """
    }
}

@Suite("Localization lint")
struct LocalizationLintTests {
    func report(_ localizations: String, id: String = "octocat.coffee") throws -> LocalizationLint.Report {
        let json = TemporaryExtension.manifest(id: id, localizations: localizations)
        let data = Data(json.utf8)
        return LocalizationLint.check(manifestData: data, manifest: try JSONDecoder().decode(ExtensionManifest.self, from: data))
    }

    @Test("A complete translation passes without warnings")
    func complete() throws {
        let report = try report("""
        { "zh-Hans": { "name": "咖啡", "description": "让 Mac 保持唤醒。",
            "commands": { "brew": { "title": "冲咖啡", "subtitle": "咖啡", "keywords": ["唤醒"] } },
            "preferences": { "disk": { "title": "磁盘" } }, "sections": { "Power": "电源" } } }
        """)
        #expect(report.errors.isEmpty)
        #expect(report.warnings.isEmpty)
    }

    @Test("Gaps and languages Prism does not show only warn")
    func warnings() throws {
        let report = try report(#"{ "zh-Hant": { "name": "咖啡" }, "ja": { "name": "コーヒー" } }"#)
        #expect(report.errors.isEmpty)
        #expect(report.warnings.contains { $0.hasPrefix("localizations.ja: Prism does not show ja yet") })
        #expect(report.warnings.contains {
            $0 == "localizations.zh-Hant leaves untranslated: description, commands.brew.title, commands.brew.subtitle, preferences.disk.title, sections.Power."
        })
    }

    @Test("Prism's own extensions must translate everything into both Chinese scripts")
    func firstParty() throws {
        let complete = """
            { "name": "咖啡", "description": "让 Mac 保持唤醒。",
              "commands": { "brew": { "title": "冲咖啡", "subtitle": "咖啡" } },
              "preferences": { "disk": { "title": "磁盘" } }, "sections": { "Power": "电源" } }
            """
        #expect(try report("{ \"zh-Hans\": \(complete), \"zh-Hant\": \(complete) }", id: "prism.coffee").errors.isEmpty)

        let untranslated = try report("{}", id: "prism.coffee")
        #expect(untranslated.errors == [
            "localizations.zh-Hans is missing; Prism's own extensions translate everything they show.",
            "localizations.zh-Hant is missing; Prism's own extensions translate everything they show.",
        ])
        let partial = try report(#"{ "zh-Hans": { "name": "咖啡" } }"#, id: "prism.coffee")
        #expect(partial.errors.contains { $0.hasPrefix("localizations.zh-Hans leaves untranslated: description,") })
        #expect(partial.errors.contains { $0.hasPrefix("localizations.zh-Hant is missing") })
        #expect(partial.warnings.isEmpty)

        // A manifest without the key at all is held to the same rule.
        var object = try #require(JSONSerialization.jsonObject(
            with: Data(TemporaryExtension.manifest(id: "prism.coffee", localizations: "{}").utf8)
        ) as? [String: Any])
        object["localizations"] = nil
        let bare = try JSONSerialization.data(withJSONObject: object)
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: bare)
        #expect(LocalizationLint.check(manifestData: bare, manifest: manifest).errors == untranslated.errors)
    }

    @Test("Mistakes Prism would silently ignore are errors", arguments: [
        (#"[]"#, "localizations must be an object keyed by language"),
        (#"{ "zh-CN": { "name": "咖啡" } }"#, "write zh-Hans or zh-Hant instead of “zh-CN”"),
        (#"{ "zh_Hans": { "name": "咖啡" } }"#, "is not a language identifier"),
        (#"{ "zh-Hans": { "title": "咖啡" } }"#, "localizations.zh-Hans.title is not translatable"),
        (#"{ "zh-Hans": { "commands": { "brew": { "title": 1 } } } }"#, "localizations.zh-Hans.commands.brew.title must be a string"),
        (#"{ "zh-Hans": { "commands": { "pour": { "title": "倒" } } } }"#, "localizations.zh-Hans.commands.pour names no command"),
        (#"{ "zh-Hans": { "sections": { "Energy": "能源" } } }"#, "localizations.zh-Hans.sections.Energy names no section"),
        (#"{ "zh-Hans": { "name": " " } }"#, "localizations.zh-Hans.name is empty"),
        (#"{ "zh-Hans": "咖啡" }"#, "localizations.zh-Hans must be an object"),
    ])
    func errors(localizations: String, expected: String) throws {
        let report = try report(localizations)
        #expect(report.errors.contains { $0.contains(expected) }, "\(report.errors)")
    }

    @Test("lint fails a folder whose translations Prism cannot use")
    func lintFails() throws {
        let fixture = try TemporaryExtension(manifest: TemporaryExtension.manifest(
            localizations: #"{ "zh-Hans": { "commands": { "pour": { "title": "倒" } } } }"#
        ))
        defer { fixture.remove() }
        #expect(throws: ToolFailure.self) { try Lint.check(fixture.folder) }
    }
}

@Suite("Packaging translations")
struct PackagingTests {
    @Test("The Gallery index keeps a manifest's translations")
    func indexKeepsLocalizations() throws {
        let fixture = try TemporaryExtension(manifest: TemporaryExtension.manifest(
            localizations: #"{ "zh-Hans": { "name": "咖啡", "commands": { "brew": { "title": "冲咖啡" } } } }"#
        ))
        defer { fixture.remove() }
        let output = fixture.folder.appendingPathComponent("out", isDirectory: true)
        let packed = try Pack.run(fixture.folder, output: output)
        let index = output.appendingPathComponent("index.json")
        try GalleryIndexTool.add(
            package: URL(fileURLWithPath: packed.path), url: URL(string: "https://example.com/coffee.prismextension")!,
            source: nil, notes: nil, to: index
        )

        let decoded = try ExtensionWire.decode(ExtensionGalleryIndex.self, from: Data(contentsOf: index))
        let manifest = try #require(decoded.entry(for: "octocat.coffee")?.manifest)
        #expect(manifest.displayText(for: "zh-Hans").name == "咖啡")
        #expect(manifest.localizations["zh-Hans"]?.commands["brew"]?.title == "冲咖啡")
    }

    @Test("A Swift extension's resource bundles travel with its executable")
    func resourceBundles() throws {
        let fixture = try TemporaryExtension(
            manifest: TemporaryExtension.manifest(executable: ".build/release/Coffee", localizations: "{}"),
            executable: ".build/release/Coffee"
        )
        defer { fixture.remove() }
        let lproj = fixture.folder.appendingPathComponent(".build/release/Coffee_Coffee.bundle/zh-Hans.lproj")
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        try Data(#""Brew" = "冲咖啡";"#.utf8).write(to: lproj.appendingPathComponent("Localizable.strings"))
        // A plain file that only looks like a bundle stays behind.
        try Data().write(to: fixture.folder.appendingPathComponent(".build/release/notes.bundle"))

        let output = fixture.folder.appendingPathComponent("out", isDirectory: true)
        let packed = try Pack.run(fixture.folder, output: output)
        let package = URL(fileURLWithPath: packed.path)
        #expect(try GalleryIndexTool.packagedFile("bin/Coffee", in: package) != nil)
        #expect(try GalleryIndexTool.packagedFile("bin/Coffee_Coffee.bundle/zh-Hans.lproj/Localizable.strings", in: package) != nil)
        #expect(try GalleryIndexTool.packagedFile("bin/notes.bundle", in: package) == nil)
    }

    @Test("A string catalog the build copied instead of compiling is refused")
    func uncompiledCatalog() throws {
        let fixture = try TemporaryExtension(
            manifest: TemporaryExtension.manifest(executable: ".build/release/Coffee", localizations: "{}"),
            executable: ".build/release/Coffee"
        )
        defer { fixture.remove() }
        let bundle = fixture.folder.appendingPathComponent(".build/release/Coffee_Coffee.bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundle.appendingPathComponent("Localizable.xcstrings"))
        let output = fixture.folder.appendingPathComponent("out", isDirectory: true)
        #expect(throws: ToolFailure.self) { try Pack.run(fixture.folder, output: output) }
    }

    @Test("A resource bundle holding a link is refused, as Prism would refuse the package")
    func linkedResourceBundle() throws {
        let fixture = try TemporaryExtension(
            manifest: TemporaryExtension.manifest(executable: ".build/release/Coffee", localizations: "{}"),
            executable: ".build/release/Coffee"
        )
        defer { fixture.remove() }
        let bundle = fixture.folder.appendingPathComponent(".build/release/Coffee_Coffee.bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: bundle.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts")
        )
        let output = fixture.folder.appendingPathComponent("out", isDirectory: true)
        #expect(throws: ToolFailure.self) { try Pack.run(fixture.folder, output: output) }
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("octocat.coffee-1.0.0.prismextension").path))
    }
}
