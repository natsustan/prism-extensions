import Foundation

/// Reads the current Git branch for a local workspace directly from `.git/HEAD`
/// without spawning a `git` subprocess. Supports normal repositories, nested
/// subdirectories, worktrees, and submodules (`gitdir:` files).
enum GitBranchReader {
    static let maxParentTraversalDepth = 12

    static func branch(forDirectory directory: String, stopAt homeDirectory: String? = nil) -> String? {
        let stopPath = homeDirectory.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        var current = URL(fileURLWithPath: directory).standardizedFileURL
        let fileManager = FileManager.default

        for _ in 0..<maxParentTraversalDepth {
            let dotGit = current.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                let headURL: URL?
                if isDir.boolValue {
                    headURL = dotGit.appendingPathComponent("HEAD")
                } else {
                    headURL = resolveGitDirHead(fromDotGitFile: dotGit, relativeTo: current)
                }
                if let headURL,
                   let contents = try? String(contentsOf: headURL, encoding: .utf8) {
                    return parseHead(contents)
                }
                return nil
            }

            let path = current.path
            if path == "/" || path.isEmpty || path == stopPath {
                break
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == path {
                break
            }
            current = parent
        }
        return nil
    }

    /// Parses the contents of a Git `HEAD` file into a branch name, tag name,
    /// or abbreviated detached commit hash.
    static func parseHead(_ contents: String) -> String? {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("ref:") {
            let ref = trimmed.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
            if ref.hasPrefix("refs/heads/") {
                let branch = String(ref.dropFirst("refs/heads/".count))
                return branch.isEmpty ? nil : branch
            }
            if ref.hasPrefix("refs/tags/") {
                let tag = String(ref.dropFirst("refs/tags/".count))
                return tag.isEmpty ? nil : tag
            }
            return ref.isEmpty ? nil : ref
        }

        // Detached HEAD: 40-character (SHA-1) or 64-character (SHA-256) hex hash.
        if trimmed.count >= 7, trimmed.allSatisfy(\.isHexDigit) {
            return String(trimmed.prefix(7))
        }
        return nil
    }

    private static func resolveGitDirHead(fromDotGitFile fileURL: URL, relativeTo directory: URL) -> URL? {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("gitdir:") else { continue }
            let rawTarget = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawTarget.isEmpty else { return nil }
            let gitDir: URL
            if rawTarget.hasPrefix("/") {
                gitDir = URL(fileURLWithPath: rawTarget)
            } else {
                gitDir = directory.appendingPathComponent(rawTarget).standardizedFileURL
            }
            return gitDir.appendingPathComponent("HEAD")
        }
        return nil
    }
}
