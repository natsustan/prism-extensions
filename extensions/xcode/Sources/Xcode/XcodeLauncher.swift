import AppKit
import Foundation

/// Opens projects in Xcode and reveals them in Finder.
protocol XcodeLaunching: Sendable {
    func openProject(at path: String, xcodeAppPath: String?) async throws
    func revealInFinder(path: String) async throws
}

enum XcodeLaunchError: Error, Equatable {
    case projectNotFound(String)
    case xcodeNotFound(String?)
    case openFailed(String)
}

/// Production launcher backed by `NSWorkspace`.
struct WorkspaceXcodeLauncher: XcodeLaunching {
    static let bundleIdentifier = "com.apple.dt.Xcode"
    static let defaultAppPath = "/Applications/Xcode.app"

    func openProject(at path: String, xcodeAppPath: String?) async throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw XcodeLaunchError.projectNotFound(path)
        }
        let appURL = try resolveXcodeURL(preferredPath: xcodeAppPath)
        let projectURL = URL(fileURLWithPath: path)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            _ = try await NSWorkspace.shared.open([projectURL], withApplicationAt: appURL, configuration: config)
        } catch {
            throw XcodeLaunchError.openFailed(error.localizedDescription)
        }
    }

    func revealInFinder(path: String) async throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw XcodeLaunchError.projectNotFound(path)
        }
        let url = URL(fileURLWithPath: path)
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func resolveXcodeURL(preferredPath: String?) throws -> URL {
        if let raw = preferredPath?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                throw XcodeLaunchError.xcodeNotFound(raw)
            }
            return URL(fileURLWithPath: expanded)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) {
            return url
        }
        if FileManager.default.fileExists(atPath: Self.defaultAppPath) {
            return URL(fileURLWithPath: Self.defaultAppPath)
        }
        throw XcodeLaunchError.xcodeNotFound(nil)
    }
}
