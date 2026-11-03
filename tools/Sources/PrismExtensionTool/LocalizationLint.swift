import Foundation
import PrismExtensionProtocol

/// Checks a manifest's `localizations`. Prism shows untranslated text for
/// anything it cannot read, so these are the mistakes that would otherwise
/// fail silently: misspelled keys, wrong types, IDs the manifest does not
/// declare, and empty text. Translations are optional; gaps only warn.
enum LocalizationLint {
    /// The languages Prism ships in. Others are kept but not shown yet.
    static let prismLanguages: Set<String> = ["en", "zh-Hans", "zh-Hant"]

    struct Report {
        var errors: [String] = []
        var warnings: [String] = []
    }

    static func check(manifestData: Data, manifest: ExtensionManifest) -> Report {
        var report = Report()
        guard let object = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let raw = object["localizations"] else { return report }
        guard let languages = raw as? [String: Any] else {
            report.errors.append("localizations must be an object keyed by language, such as \"zh-Hans\".")
            return report
        }
        for (language, entry) in languages.sorted(by: { $0.key < $1.key }) {
            let path = "localizations.\(language)"
            if let problem = languageProblem(language) {
                report.errors.append("\(path): \(problem)")
            } else if !prismLanguages.contains(language) {
                report.warnings.append("\(path): Prism does not show \(language) yet (it ships \(prismLanguages.sorted().joined(separator: ", "))).")
            }
            guard let entry = entry as? [String: Any] else {
                report.errors.append("\(path) must be an object.")
                continue
            }
            report.errors += shapeProblems(entry, path: path)
        }
        report.errors += manifest.unknownLocalizationReferences()
        for (language, entry) in manifest.localizations.sorted(by: { $0.key < $1.key }) {
            for (field, text) in entry.allText where text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                report.errors.append("localizations.\(language).\(field) is empty; leave it out to show the untranslated text.")
            }
            let missing = missingFields(entry, of: manifest)
            if !missing.isEmpty {
                report.warnings.append("localizations.\(language) leaves untranslated: \(missing.joined(separator: ", ")).")
            }
        }
        return report
    }

    /// Why a key is not a language Prism can match, or nil when it is.
    /// Chinese needs its script, because Prism never shows one script for
    /// the other.
    static func languageProblem(_ key: String) -> String? {
        let pattern = #"^[a-z]{2,3}(-[A-Z][a-z]{3})?(-([A-Z]{2}|[0-9]{3}))?$"#
        guard key.range(of: pattern, options: .regularExpression) != nil else {
            return "“\(key)” is not a language identifier such as en, ja, zh-Hans, or zh-Hant."
        }
        let parts = key.split(separator: "-")
        if parts[0] == "zh", !parts.contains("Hans"), !parts.contains("Hant") {
            return "write zh-Hans or zh-Hant instead of “\(key)”."
        }
        return nil
    }

    private indirect enum Kind: Sendable {
        case string, strings, table([String: Kind]), map(Kind)
    }

    private static let entryShape: [String: Kind] = [
        "name": .string,
        "description": .string,
        "commands": .map(.table(["title": .string, "subtitle": .string, "keywords": .strings])),
        "preferences": .map(.table(["title": .string, "caption": .string])),
        "sections": .map(.string),
        "widgets": .map(.table(["title": .string, "subtitle": .string])),
        "folders": .map(.table(["reason": .string])),
    ]

    private static func shapeProblems(_ entry: [String: Any], path: String) -> [String] {
        check(entry, as: .table(entryShape), path: path)
    }

    private static func check(_ value: Any, as kind: Kind, path: String) -> [String] {
        switch kind {
        case .string:
            return value is String ? [] : ["\(path) must be a string."]
        case .strings:
            return value is [String] ? [] : ["\(path) must be a list of strings."]
        case let .table(fields):
            guard let object = value as? [String: Any] else { return ["\(path) must be an object."] }
            return object.sorted(by: { $0.key < $1.key }).flatMap { key, value in
                guard let field = fields[key] else {
                    return ["\(path).\(key) is not translatable; use \(fields.keys.sorted().joined(separator: ", "))."]
                }
                return check(value, as: field, path: "\(path).\(key)")
            }
        case let .map(element):
            guard let object = value as? [String: Any] else { return ["\(path) must be an object keyed by ID."] }
            return object.sorted(by: { $0.key < $1.key }).flatMap { key, value in
                check(value, as: element, path: "\(path).\(key)")
            }
        }
    }

    /// Display text the manifest has that `entry` does not translate.
    static func missingFields(_ entry: ExtensionManifestLocalization, of manifest: ExtensionManifest) -> [String] {
        var missing = [String]()
        func need(_ translated: String?, _ base: String?, _ field: String) {
            guard base != nil, translated == nil else { return }
            missing.append(field)
        }
        need(entry.name, manifest.name, "name")
        need(entry.summary, manifest.summary, "description")
        for command in manifest.commands {
            need(entry.commands[command.id]?.title, command.title, "commands.\(command.id).title")
            need(entry.commands[command.id]?.subtitle, command.subtitle, "commands.\(command.id).subtitle")
        }
        for preference in manifest.preferences {
            need(entry.preferences[preference.id]?.title, preference.title, "preferences.\(preference.id).title")
            need(entry.preferences[preference.id]?.caption, preference.caption, "preferences.\(preference.id).caption")
        }
        for section in Set(manifest.preferences.compactMap(\.section)).sorted() where !section.isEmpty {
            need(entry.sections[section], section, "sections.\(section)")
        }
        for widget in manifest.widgets {
            need(entry.widgets[widget.id]?.title, widget.title, "widgets.\(widget.id).title")
            need(entry.widgets[widget.id]?.subtitle, widget.subtitle, "widgets.\(widget.id).subtitle")
        }
        for folder in manifest.folders {
            need(entry.folders[folder.id]?.reason, folder.reason, "folders.\(folder.id).reason")
        }
        return missing
    }
}
