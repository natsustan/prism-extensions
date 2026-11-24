import AppKit
import Foundation

/// Opens local or remote workspaces in Zed and reveals local items in Finder.
protocol ZedLaunching: Sendable {
    func openLocalWorkspace(paths: [String], zedAppPath: String?) async throws
    func openRemoteWorkspace(urls: [URL], zedAppPath: String?) async throws
    func revealInFinder(path: String) async throws
}

enum ZedLaunchError: Error, Equatable {
    case projectNotFound(String)
    case zedNotFound(String?)
    case openFailed(String)
}

/// Production launcher backed by `NSWorkspace`.
struct WorkspaceZedLauncher: ZedLaunching {
    func openLocalWorkspace(paths: [String], zedAppPath: String?) async throws {
        guard !paths.isEmpty else {
            throw ZedLaunchError.projectNotFound("")
        }
        for path in paths where !FileManager.default.fileExists(atPath: path) {
            throw ZedLaunchError.projectNotFound(path)
        }
        let appURL = try resolveZedURL(preferredPath: zedAppPath)
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            _ = try await NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: config)
        } catch {
            throw ZedLaunchError.openFailed(error.localizedDescription)
        }
    }

    func openRemoteWorkspace(urls: [URL], zedAppPath: String?) async throws {
        guard !urls.isEmpty else {
            throw ZedLaunchError.projectNotFound("")
        }
        let appURL = try resolveZedURL(preferredPath: zedAppPath)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            _ = try await NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: config)
        } catch {
            throw ZedLaunchError.openFailed(error.localizedDescription)
        }
    }

    func revealInFinder(path: String) async throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ZedLaunchError.projectNotFound(path)
        }
        let url = URL(fileURLWithPath: path)
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func resolveZedURL(preferredPath: String?) throws -> URL {
        if let raw = preferredPath?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                throw ZedLaunchError.zedNotFound(raw)
            }
            return URL(fileURLWithPath: expanded)
        }
        for channel in ZedChannel.allCases {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: channel.bundleIdentifier) {
                return url
            }
        }
        for channel in ZedChannel.allCases {
            if FileManager.default.fileExists(atPath: channel.defaultAppPath) {
                return URL(fileURLWithPath: channel.defaultAppPath)
            }
        }
        throw ZedLaunchError.zedNotFound(nil)
    }
}
