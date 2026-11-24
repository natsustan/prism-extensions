import Foundation

/// The kind of Xcode project a row represents.
enum XcodeProjectKind: String, CaseIterable, Sendable, Equatable {
    case project
    case workspace
    case package
    case playground

    var symbol: String {
        switch self {
        case .project: "hammer.fill"
        case .workspace: "square.stack.3d.up.fill"
        case .package: "shippingbox.fill"
        case .playground: "play.rectangle.fill"
        }
    }

    var tint: String {
        switch self {
        case .project: "blue"
        case .workspace: "indigo"
        case .package: "orange"
        case .playground: "teal"
        }
    }

    var badge: String {
        switch self {
        case .project: localized("Project")
        case .workspace: localized("Workspace")
        case .package: localized("Package")
        case .playground: localized("Playground")
        }
    }

    var searchKeywords: [String] {
        switch self {
        case .project: ["project", "xcodeproj"]
        case .workspace: ["workspace", "xcworkspace"]
        case .package: ["package", "swift package", "spm", "package.swift"]
        case .playground: ["playground", "playgroundbook"]
        }
    }
}

/// A recently opened Xcode project, workspace, Swift package, or playground.
struct XcodeProject: Sendable, Equatable {
    /// Canonical path on disk (for Swift packages, the package directory).
    let path: String
    /// Path passed to Xcode when opening (for Swift packages, `Package.swift`).
    let openPath: String
    /// Display name without `.xcodeproj` / `.xcworkspace` / `.playground` suffix.
    let name: String
    let kind: XcodeProjectKind
    /// Most recent open or access time known across Xcode's local records.
    let lastOpened: Date?
    /// Order from Xcode's Shared File List, used when no timestamp is known.
    let sflRank: Int?

    /// The directory containing the project, or the package directory itself.
    var directoryPath: String {
        switch kind {
        case .package:
            path
        case .project, .workspace, .playground:
            URL(fileURLWithPath: path).deletingLastPathComponent().path
        }
    }

    /// Shortened path shown beneath the title, with `~` for the home folder.
    /// Projects and workspaces show their containing folder so git worktrees
    /// with the same `.xcodeproj` name are immediately distinguishable.
    func compactLocation(homeDirectory: String) -> String {
        let displayPath = switch kind {
        case .package:
            URL(fileURLWithPath: path).deletingLastPathComponent().path
        case .project, .workspace, .playground:
            directoryPath
        }
        return Self.abbreviatingHome(displayPath, homeDirectory: homeDirectory)
    }

    static func abbreviatingHome(_ path: String, homeDirectory: String) -> String {
        let home = homeDirectory.hasSuffix("/") && homeDirectory.count > 1
            ? String(homeDirectory.dropLast())
            : homeDirectory
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

/// Classifies and normalizes candidate file paths discovered from Xcode's records.
enum XcodeProjectClassifier {
    struct Classified: Sendable, Equatable {
        let canonicalPath: String
        let openPath: String
        let name: String
        let kind: XcodeProjectKind
    }

    /// Returns a normalized project description when `rawPath` points to an
    /// existing Xcode project, workspace, Swift package, or playground, and
    /// ignores internal, temporary, or dependency-checkout paths.
    static func classify(
        rawPath: String,
        fileExists: (String) -> Bool,
        isDirectory: (String) -> Bool
    ) -> Classified? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else { return nil }

        var url = URL(fileURLWithPath: trimmed).standardizedFileURL
        // Xcode sometimes records the internal `project.xcworkspace` inside an `.xcodeproj`.
        if url.lastPathComponent == "project.xcworkspace",
           url.deletingLastPathComponent().pathExtension.lowercased() == "xcodeproj" {
            url = url.deletingLastPathComponent()
        }

        let path = url.path
        guard !isIgnoredPath(path) else { return nil }

        let filename = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "xcodeproj":
            guard fileExists(path) else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            guard !name.isEmpty else { return nil }
            return Classified(canonicalPath: path, openPath: path, name: name, kind: .project)

        case "xcworkspace":
            guard fileExists(path) else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            guard !name.isEmpty else { return nil }
            return Classified(canonicalPath: path, openPath: path, name: name, kind: .workspace)

        case "playground", "playgroundbook":
            guard fileExists(path) else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            guard !name.isEmpty else { return nil }
            return Classified(canonicalPath: path, openPath: path, name: name, kind: .playground)

        default:
            if filename == "Package.swift" {
                guard fileExists(path) else { return nil }
                let dirURL = url.deletingLastPathComponent()
                let dirPath = dirURL.path
                guard !isIgnoredPath(dirPath) else { return nil }
                let name = dirURL.lastPathComponent
                guard !name.isEmpty else { return nil }
                return Classified(canonicalPath: dirPath, openPath: path, name: name, kind: .package)
            }
            // DerivedData records a Swift package by its root directory.
            if isDirectory(path) {
                let manifestPath = url.appendingPathComponent("Package.swift").path
                if fileExists(manifestPath) {
                    let name = url.lastPathComponent
                    guard !name.isEmpty else { return nil }
                    return Classified(canonicalPath: path, openPath: manifestPath, name: name, kind: .package)
                }
            }
            return nil
        }
    }

    /// Skips Xcode's own temporary containers, DerivedData checkouts, and SPM build checkouts.
    static func isIgnoredPath(_ path: String) -> Bool {
        let ignoredPrefixes = [
            "/var/folders/",
            "/private/var/folders/",
            "/tmp/",
            "/private/tmp/",
            "/System/",
        ]
        if ignoredPrefixes.contains(where: { path.hasPrefix($0) }) {
            return true
        }
        let lower = path.lowercased()
        let ignoredSubstrings = [
            "/deriveddata/",
            "/sourcepackages/checkouts/",
            "/.build/checkouts/",
            ".xcfilescontainer",
            "/.trash/",
        ]
        return ignoredSubstrings.contains(where: { lower.contains($0) })
    }
}
